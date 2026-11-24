//! scripts/panel.sh's gather and the helpers it calls for each pane: the process table read
//! into PCHILD/PARGS/..., tmux's pane list, each pane's process tree with its first agent, its
//! CPU (ticks between two looks) and memory, what a shell runs in front (shell_job), an ssh it
//! runs (ssh_dest), and whose it is (user_of, user_inst). Ported line for line; the bash names
//! are kept in the comments.

use super::sh::{self, Bytes};
use super::{in_shells, m, n, procs, strip_dash, G, HOST_RE, USER_RE, VER_RE};
use std::collections::HashMap;

/// The pane list's -F, as gather passes it
pub const PANES_FMT: &[u8] = b"#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{@agent}";

/// agent_kind ARGS -> AKIND: claude/codex/cursor/crush/gemini or nothing (as agent-say does)
pub fn agent_kind(args: &[u8]) -> &'static [u8] {
    // case " $1 " in
    let s = sh::path(&[b" ", args, b" "]);
    let has = |n: &str| sh::contains(&s, n.as_bytes());
    let starts = |n: &str| s.starts_with(n.as_bytes());
    if has("app-server") {
        b""
    } else if has("/claude ") || starts(" claude ") || has(" claude --") {
        b"claude"
    } else if has("/codex ") || starts(" codex ") {
        b"codex"
    } else if has("cursor-agent") {
        b"cursor"
    } else if has("/crush ") || starts(" crush ") {
        b"crush"
    } else if has("/gemini ") || has(" gemini ") {
        b"gemini"
    } else {
        b""
    }
}

/// `read -ra a <<<"$s"`: its words (default IFS)
pub fn words(s: &[u8]) -> Vec<Bytes> {
    let line = s.split(|&c| c == b'\n').next().unwrap_or(b"");
    line.split(|&c| c == b' ' || c == b'\t').filter(|w| !w.is_empty()).map(|w| w.to_vec()).collect()
}

/// shell_job PANE_PID -> SJOB: what a pane tmux calls a shell is running in front, or nothing
pub fn shell_job(g: &G, pid: &[u8]) -> Bytes {
    let fg = procs::tpgid(pid);
    // [[ $fg =~ ^[0-9]+$ && $fg != "$1" && -n ${PARGS[$fg]:-} ]] || return 0
    if !(m("^[0-9]+$", &fg) && fg != pid && !g.t.args_of(&fg).is_empty()) {
        return Vec::new();
    }
    let a = words(g.t.args_of(&fg));
    let Some(a0) = a.first() else { return Vec::new() };
    let w = sh::basename(a0);
    if !in_shells(strip_dash(w)) {
        return Vec::new();
    }
    for w in &a[1..] {
        if w == b"-c" {
            return sh::path(&[strip_dash(sh::basename(a0)), b" -c"]);
        }
        if w.starts_with(b"-") {
            continue;
        }
        return sh::basename(w).to_vec();
    }
    Vec::new()
}

/// ssh_dest ARGS -> SSHD: the host an `ssh ...` command line connects to, as agent-say link
/// takes it (no user@, no port), or nothing
pub fn ssh_dest(args: &[u8]) -> Bytes {
    if !sh::has(args, "ssh") {
        return Vec::new();
    }
    let a = words(args);
    if a.is_empty() || sh::basename(&a[0]) != b"ssh" {
        return Vec::new();
    }
    let mut i = 1;
    while i < a.len() {
        let w = &a[i];
        // -[BbcDEeFIiJLlmOoPpQRSWw]) ((i++))
        if w.len() == 2 && w[0] == b'-' && b"BbcDEeFIiJLlmOoPpQRSWw".contains(&w[1]) {
            i += 2;
            continue;
        }
        if w.starts_with(b"-") {
            i += 1;
            continue;
        }
        // d=${a[i]#ssh://} d=${d##*@} d=${d%%:*}
        let mut d: &[u8] = w.strip_prefix(b"ssh://").unwrap_or(w);
        if let Some(p) = d.iter().rposition(|&c| c == b'@') {
            d = &d[p + 1..];
        }
        if let Some(p) = d.iter().position(|&c| c == b':') {
            d = &d[..p];
        }
        return if m(HOST_RE, d) { d.to_vec() } else { Vec::new() };
    }
    Vec::new()
}

/// getent passwd UID's name and home
fn passwd(uid: &[u8]) -> Option<(Bytes, Bytes)> {
    let u: libc::uid_t = std::str::from_utf8(uid).ok()?.parse().ok()?;
    let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buf = vec![0 as libc::c_char; 16384];
    let mut res: *mut libc::passwd = std::ptr::null_mut();
    let r = unsafe { libc::getpwuid_r(u, &mut pw, buf.as_mut_ptr(), buf.len(), &mut res) };
    if r != 0 || res.is_null() {
        return None;
    }
    let name = unsafe { std::ffi::CStr::from_ptr(pw.pw_name) }.to_bytes().to_vec();
    let home = unsafe { std::ffi::CStr::from_ptr(pw.pw_dir) }.to_bytes().to_vec();
    Some((name, home))
}

impl G {
    /// user_of UID -> UNAME: its user name (the number if it has none)
    pub fn user_of(&mut self, uid: &[u8]) -> Bytes {
        if !self.unames.contains_key(uid) {
            // IFS=: read -r n _ _ _ _ h _ < <(getent passwd "$1"); [[ -n $n ]] || n=$(id -un "$1")
            let (mut nm, h) = passwd(uid).unwrap_or_default();
            if !m(USER_RE, &nm) {
                nm = uid.to_vec();
            }
            self.unames.insert(uid.to_vec(), nm);
            self.uhomes.insert(uid.to_vec(), h);
        }
        self.unames[uid].clone()
    }

    /// user_inst NAME UID PID -> INST: "owner", that user's tmux-revive version, or nothing
    pub fn user_inst(&mut self, name: &[u8], uid: &[u8], pid: &[u8]) -> Bytes {
        if name == self.me.as_slice() {
            return b"owner".to_vec();
        }
        if !uid.is_empty() && !self.uapps.contains_key(uid) {
            let mut d: Bytes = Vec::new();
            let h = self.uhomes.get(uid).cloned().unwrap_or_default();
            if h.starts_with(b"/") {
                d = sh::path(&[&h, b"/.local/share"]);
            }
            let pp = sh::path(&[b"/proc/", pid]);
            if m("^[0-9]+$", pid) && sh::readable(&sh::path(&[&pp, b"/environ"])) && sh::owner(&pp).map(|o| o.to_string().into_bytes()).as_deref() == Some(uid) {
                for e in super::environ(pid).unwrap_or_default() {
                    if let Some(v) = e.strip_prefix(b"XDG_DATA_HOME=") {
                        if v.starts_with(b"/") {
                            d = v.to_vec();
                        }
                    }
                }
            }
            let a = if d.is_empty() { Vec::new() } else { sh::path(&[&d, b"/tmux-revive/app"]) };
            self.uapps.insert(uid.to_vec(), a);
        }
        let a = if uid.is_empty() { Vec::new() } else { self.uapps[uid].clone() };
        let first = |f: &[u8]| -> Bytes {
            // read -r v <FILE (default IFS: its spaces at either end go)
            sh::read_line(f).map(|l| sh::read_ws(&l, 1, b" \t\n").remove(0)).unwrap_or_default()
        };
        let vf = sh::path(&[&a, b"/VERSION"]);
        if !a.is_empty() && sh::is_file(&vf) && !sh::is_link(&vf) {
            let v = first(&vf);
            if m(VER_RE, &v) {
                return v;
            }
        }
        let uf = sh::path(&[&self.astate, b"/users/", name]);
        if m(USER_RE, name) && sh::is_file(&uf) {
            let v = first(&uf);
            if m(VER_RE, &v) {
                return v;
            }
        }
        Vec::new()
    }

    /// gather: every pane, its state, CPU, memory and folder, then the agents' (agents_look),
    /// the ssh sessions outside tmux, the linked computers' rows and how long each has waited
    pub fn gather(&mut self) {
        // all=$(ps -ww -eo pid=,ppid=,uid=,rss=,pcpu=,args=); while read -r pid ppid uid rss pcpu args
        self.t = procs::Table::from_rows(&procs::rows());
        self.inpane.clear();
        // now=${EPOCHREALTIME:-$SECONDS}
        let now = sh::now_us();
        self.gather_n += 1;
        self.p = super::Panes::default();
        self.a_at.clear();
        self.a_kind.clear();
        self.a_pid.clear();
        self.a_tree.clear();
        self.a_load.clear();
        let mut tnow: HashMap<Bytes, i64> = HashMap::new();
        let panes = sh::cmdsub(&sh::tm(&[b"list-panes", b"-a", b"-F", PANES_FMT]).out);
        let tmux_pane = sh::env("TMUX_PANE").unwrap_or_default();
        for line in sh::here(&panes) {
            // IFS=$'\t' read -r id loc ppid0 cmd path name: tab is IFS whitespace, so an empty
            // field between two others is lost and the ones after it move left, as in bash
            let f = sh::read_ws(&line, 6, b"\t");
            let id = f[0].clone();
            if id.is_empty() {
                continue;
            }
            let ppid0 = f[2].clone();
            let (loc, cmd, path, name) = (crate::compat::clean(&f[1]), crate::compat::clean(&f[3]), crate::compat::clean(&f[4]), crate::compat::clean(&f[5]));
            // The pane's process tree, breadth-first, and the first agent in it.
            let mut tree: Vec<Bytes> = Vec::new();
            let mut q: std::collections::VecDeque<Bytes> = std::collections::VecDeque::from([ppid0.clone()]);
            let (mut kind, mut apid): (&[u8], Bytes) = (b"", Vec::new());
            while let Some(p) = q.pop_front() {
                tree.push(p.clone());
                self.inpane.insert(p.clone());
                if kind.is_empty() {
                    kind = agent_kind(self.t.args_of(&p));
                    if !kind.is_empty() {
                        apid = p.clone();
                    }
                }
                q.extend(self.t.children(&p).iter().cloned());
            }
            let mut mem: i64 = 0;
            for p in &tree {
                // $((mem + ${PRSS[$p]:-0}))
                let r = self.t.rss.get(p).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| b"0".to_vec());
                mem = mem.wrapping_add(n(&r));
            }
            let mut cpu: i64 = 0;
            if sh::readable(&sh::path(&[b"/proc/", &ppid0, b"/stat"])) {
                let t = procs::tree_ticks(&tree);
                // Kept by pane and its process: a pane id tmux gives out again is another pane.
                let key = sh::path(&[&id, b":", &ppid0]);
                if let (Some(tp), Some(prev)) = (self.t_prev, self.ticks_prev.get(&key)) {
                    let dt = (now - tp + 500) / 1000;
                    let k = t - prev;
                    if dt > 0 && k > 0 {
                        cpu = (2 * k * 100000 + self.clk * dt) / (2 * self.clk * dt);
                    }
                }
                tnow.insert(key, t);
            } else {
                // ps's own figure (macOS): a percent with decimals, summed and rounded at each step.
                for p in &tree {
                    let pc = self.t.pcpu.get(p).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| b"0".to_vec());
                    let mm = crate::compat::re(r"^([0-9]*)(\.([0-9]*))?").matches(&pc).unwrap_or_else(|| vec![Vec::new(); 4]);
                    let mut dt = mm[3].clone();
                    dt.extend_from_slice(b"000");
                    cpu = ((cpu + n(&sh::path(&[b"10#0", &mm[1]]))) * 1000 + n(&sh::path(&[b"10#", &dt[..3]])) + 500) / 1000;
                }
            }
            let st: &[u8];
            let app: Bytes;
            let agent: &[u8];
            let c = strip_dash(&cmd).to_vec();
            if id == tmux_pane {
                st = b"self";
                app = b"panel".to_vec();
                agent = b"0";
            } else if !kind.is_empty() {
                // Its state and context left are looked at once every pane is listed (agents_look).
                st = b"agent";
                self.a_at.push(self.p.id.len() as i64);
                self.a_kind.push(kind.to_vec());
                self.a_pid.push(apid.clone());
                self.a_tree.push(tree.clone());
                app = kind.to_vec();
                agent = b"1";
            } else if in_shells(&c) {
                let sj = shell_job(self, &ppid0);
                if sj.is_empty() {
                    st = b"shell";
                    app = c;
                } else {
                    st = b"program";
                    app = sj;
                }
                agent = b"0";
            } else {
                st = b"program";
                app = cmd.clone();
                agent = b"0";
            }
            // An ssh connection in a pane without an agent: a host its agents could be linked to.
            let mut ssh: Bytes = Vec::new();
            if st == b"program" {
                for p in &tree {
                    ssh = ssh_dest(self.t.args_of(p));
                    if !ssh.is_empty() {
                        break;
                    }
                }
            }
            // Whose it is: its agent's user, else the deepest process in it.
            let p = if apid.is_empty() { tree.last().cloned().unwrap_or_default() } else { apid.clone() };
            let puid = self.t.uid.get(&p).cloned().unwrap_or_default();
            let uname = if puid.is_empty() { Vec::new() } else { self.user_of(&puid) };
            let inst = self.user_inst(&uname, &puid, &p);
            // ${loc##*:}
            let wp = match loc.iter().rposition(|&c| c == b':') {
                Some(i) => loc[i + 1..].to_vec(),
                None => loc.clone(),
            };
            let giti = self.git_info(&path);
            let pp = &mut self.p;
            pp.app.push(app);
            pp.agent.push(agent.to_vec());
            pp.ssh.push(ssh);
            pp.host.push(Vec::new());
            pp.rid.push(Vec::new());
            pp.wp.push(wp);
            pp.user.push(uname);
            pp.inst.push(inst);
            pp.acct.push(Vec::new());
            pp.id.push(id);
            pp.loc.push(loc);
            pp.name.push(name);
            pp.state.push(st.to_vec());
            pp.dir.push(path);
            pp.git.push(giti);
            pp.cpu.push(cpu.to_string().into_bytes());
            pp.mem.push(mem.to_string().into_bytes());
            pp.ctx.push(Vec::new());
        }
        self.agents_look();
        // Only the panes there now: a closed pane's count goes with it.
        self.ticks_prev = tnow;
        self.t_prev = Some(now);
        self.outside_ssh();
        self.remote_panes();
        self.wait_watch();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compat::tests::bash;

    /// The bash function NAME's body, as scripts/panel.sh has it (sed, as test/panel.sh does)
    pub fn bash_fn(name: &str) -> String {
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        let start = format!("{}() {{", name);
        let mut out = String::new();
        let mut on = false;
        for l in src.lines() {
            if l.starts_with(&start) {
                on = true;
            }
            if on {
                out.push_str(l);
                out.push('\n');
                if l == "}" {
                    break;
                }
            }
        }
        assert!(!out.is_empty(), "no {} in panel.sh", name);
        out
    }

    #[test]
    fn agent_kind_as_bash() {
        let f = bash_fn("agent_kind");
        let cases: &[&[u8]] = &[
            b"claude", b"/usr/bin/claude --resume x", b"node /x/claude", b"claude --x", b"bash -c claude", b"codex", b"/a/codex exec",
            b"codex app-server", b"x cursor-agent", b"crush", b"/b/crush", b"gemini", b"node /g/gemini y", b"run gemini now", b"", b"claudex",
            b"sh -c claude --dangerously", b"x/codex",
        ];
        for c in cases {
            let theirs = bash(&format!("{}\nagent_kind \"$1\"; printf %s \"$AKIND\"", f), &[c]);
            assert_eq!(agent_kind(c), theirs.as_slice(), "{:?}", String::from_utf8_lossy(c));
        }
    }

    #[test]
    fn ssh_dest_as_bash() {
        let f = bash_fn("ssh_dest");
        let cases: &[&[u8]] = &[
            b"ssh host", b"ssh -p 22 me@host.example", b"/usr/bin/ssh -o X=y ssh://u@h:22", b"ssh -t -l me box", b"sshd: me", b"ssh", b"ssh -v",
            b"ssh -J jump target", b"ssh bad!host", b"autossh -M 0 h", b"ssh  -i  key  h2  cmd", b"ssh -46 x.y",
        ];
        for c in cases {
            let theirs = bash(&format!("{}\nssh_dest \"$1\"; printf %s \"$SSHD\"", f), &[c]);
            assert_eq!(ssh_dest(c), theirs, "{:?}", String::from_utf8_lossy(c));
        }
    }
}

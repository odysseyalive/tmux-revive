//! scripts/panel.sh's pgit and git_info: a pane's branch, starred when it has uncommitted
//! changes, cached 15 s a folder. git runs as bash runs it: from PATH, with the same flags
//! (its config may not run a command, and it takes no lock from you).

use super::sh::{self, Bytes};
use super::G;

/// pgit DIR ARGS...: GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor= -c core.hooksPath=/dev/null --no-optional-locks -C DIR ARGS...
fn pgit_argv<'a>(d: &'a [u8], args: &[&'a [u8]]) -> Vec<&'a [u8]> {
    let mut a: Vec<&[u8]> = vec![b"git", b"-c", b"core.fsmonitor=", b"-c", b"core.hooksPath=/dev/null", b"--no-optional-locks", b"-C", d];
    a.extend_from_slice(args);
    a
}
fn pgit(d: &[u8], args: &[&[u8]]) -> sh::Out {
    sh::run_env(&pgit_argv(d, args), &[("GIT_OPTIONAL_LOCKS", b"0")], None)
}

impl G {
    /// git_info DIR -> GITI: "branch" or "branch*" (uncommitted changes), cached 15 s
    pub fn git_info(&mut self, d: &[u8]) -> Bytes {
        if d.is_empty() {
            return Vec::new();
        }
        if let Some(t) = self.git_t.get(d) {
            if sh::seconds() - t < 15 {
                return self.git.get(d).cloned().unwrap_or_default();
            }
        }
        // b=$(pgit "$d" symbolic-ref --short -q HEAD || pgit "$d" rev-parse --short HEAD)
        let o = pgit(d, &[b"symbolic-ref", b"--short", b"-q", b"HEAD"]);
        let mut out = o.out;
        if !o.ok {
            out.extend(pgit(d, &[b"rev-parse", b"--short", b"HEAD"]).out);
        }
        let mut b = sh::cmdsub(&out);
        if !b.is_empty() {
            // A clean/process filter the repo sets itself means no dirty check there.
            let c = pgit(d, &[b"config", b"--show-scope", b"--get-regexp", b"^filter\\..*\\.(clean|process)$"]);
            let mut kept = Vec::new();
            for l in sh::split_lines(&c.out) {
                if l.starts_with(b"global\t") || l.starts_with(b"system\t") {
                    continue;
                }
                kept.extend_from_slice(l);
                kept.push(b'\n');
            }
            if sh::cmdsub(&kept).is_empty() {
                // A submodule's own config isn't in that check, and status would rehash its files
                // with that config's filters: never inside one (a submodule whose commit moved
                // still shows). pgit status --porcelain -uno --ignore-submodules=dirty | head -c1
                let argv = pgit_argv(d, &[b"status", b"--porcelain", b"-uno", b"--ignore-submodules=dirty"]);
                let (_, dirty) = sh::run_capped_env(&argv, 1, &[("GIT_OPTIONAL_LOCKS", b"0")]);
                if !sh::cmdsub(&dirty).is_empty() {
                    b.push(b'*');
                }
            }
        }
        let b = crate::compat::clean(&b);
        self.git.insert(d.to_vec(), b.clone());
        self.git_t.insert(d.to_vec(), sh::seconds());
        b
    }
}

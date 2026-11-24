//! What draw reads beside the panes: scripts/panel.sh's intros_look, messages and links_saves,
//! ported line for line (bash names in the comments). Their awk, find, wc, grep, paste and jq
//! are reads of the same files; tmux's @revive-interval is asked as bash asks it, and a link's
//! poller is looked for in the process table as `ps -o args= -p PID` gives it.

use super::sh::{self, Bytes};
use super::{m, n, procs, G};
use crate::compat::{clean, re, substr};
use crate::render::{cat, B, BBLU, BCYN, BGRN, BLINK, BMAG, BRED, BWHT, BYEL, GRY, R};
use std::collections::{HashMap, HashSet};

/// `read -r v <FILE`, and whether it succeeded: a first line with no newline still sets v, but
/// read fails (so `read ... && X` skips X)
fn read_ok(f: &[u8]) -> Option<Bytes> {
    let d = std::fs::read(sh::os(f)).ok()?;
    let nl = d.iter().position(|&c| c == b'\n')?;
    Some(sh::read_ws(&d[..nl], 1, b" \t\n").remove(0))
}

/// `$(ps -ww -o args= -p PID)`: from /proc as ps prints it (ps itself where /proc can't answer)
fn ps_args(pid: &[u8]) -> Bytes {
    if !procs::use_ps() && m("^[0-9]+$", pid) {
        let up = std::fs::read("/proc/uptime").ok().and_then(|u| String::from_utf8_lossy(&u).split(' ').next().and_then(|x| x.parse().ok())).unwrap_or(0.0);
        return procs::proc_row(pid, up, procs::clk()).map(|r| r.args).unwrap_or_default();
    }
    sh::cmdsub(&sh::run(&[b"ps", b"-ww", b"-o", b"args=", b"-p", pid]).out)
}

impl G {
    /// intros_look -> INTROS: who waits for access (G), each introduction's sender
    pub fn intros_look(&mut self) -> Vec<Bytes> {
        let mut v = Vec::new();
        for d in crate::compat::glob_dirs(&sh::path(&[&self.astate, b"/intros"])) {
            let f = sh::path(&[&d, b"from"]);
            if sh::is_file(&f) {
                if let Some(x) = read_ok(&f) {
                    v.push(x);
                }
            }
        }
        v
    }

    /// messages -> MSG, MOLD, MWAIT, INTRO_ON: the message center's lines
    pub fn messages(&mut self) -> (Vec<Bytes>, i64, i64, Bytes) {
        let mut msg: Vec<Bytes> = Vec::new();
        let mut wait: Vec<Bytes> = Vec::new();
        let mut oldm: Vec<Bytes> = Vec::new();
        let mut asks_d: Vec<Bytes> = Vec::new();
        let mut asks: HashSet<Bytes> = HashSet::new();
        let mut shown: HashSet<Bytes> = HashSet::new();
        let mut intro_on = b"0".to_vec();
        for d in crate::compat::glob_dirs(&sh::path(&[&self.astate, b"/intros"])) {
            if !sh::is_file(&sh::path(&[&d, b"from"])) {
                continue;
            }
            intro_on = b"1".to_vec();
            asks_d.push(d.clone());
            let c = sh::head1(&sh::path(&[&d, b"created"]));
            if m("^[0-9]{1,12}$", &c) {
                asks.insert(c);
            }
        }
        const HRE: &str = "^## \\[([^ ]+) -> ([^ ]+) ([^]]+)\\] #([^ ]+)(.*)$";
        if sh::is_file(&self.amail) {
            let data = std::fs::read(sh::os(&self.amail)).unwrap_or_default();
            // tail -n 600 | awk '/^## \[/{h=$0; getline b; print h "\t" b}' | tail -n 40
            let ls = sh::split_lines(sh::tail_n(&data, 600));
            let mut pairs: Vec<Bytes> = Vec::new();
            let mut b: &[u8] = b"";
            let mut i = 0;
            while i < ls.len() {
                if ls[i].starts_with(b"## [") {
                    let h = ls[i];
                    if i + 1 < ls.len() {
                        b = ls[i + 1];
                        i += 1;
                    }
                    pairs.push(cat(&[h, b"\t", b]));
                }
                i += 1;
            }
            let start = pairs.len().saturating_sub(40);
            let (mut hh, mut bs): (Vec<Bytes>, Vec<Bytes>) = (Vec::new(), Vec::new());
            let mut last: HashMap<Bytes, usize> = HashMap::new();
            for p in &pairs[start..] {
                // IFS=$'\t' read -r h b
                let f = sh::read_ws(p, 2, b"\t");
                let (h, b) = (clean(&f[0]), clean(&f[1]));
                let Some(mm) = re(HRE).matches(&h) else { continue };
                let k = cat(&[&mm[1], b" ", &mm[2], b" ", &mm[4]]);
                if let Some(&j) = last.get(&k) {
                    hh[j] = Vec::new(); // superseded
                }
                last.insert(k, hh.len());
                hh.push(h);
                bs.push(b);
            }
            for i in 0..hh.len() {
                if hh[i].is_empty() {
                    continue;
                }
                let Some(mm) = re(HRE).matches(&hh[i]) else { continue };
                let (from, to, when, id, rest, b) = (&mm[1], &mm[2], &mm[3], &mm[4], &mm[5], &bs[i]);
                let when = substr(when, 11, Some(5)).unwrap_or_default();
                // c=${id#h} c=${c%%.*} c=${c:-x}
                let c = id.strip_prefix(b"h").unwrap_or(id);
                let c = match c.iter().position(|&x| x == b'.') {
                    Some(p) => &c[..p],
                    None => c,
                };
                let c: Bytes = if c.is_empty() { b"x".to_vec() } else { c.to_vec() };
                let arrow = "→".as_bytes();
                if rest.as_slice() == b" (held: waiting for access)" && asks.contains(&c) {
                    shown.insert(c);
                    wait.push(cat(&[GRY, &when, R, b" ", B, BYEL, BLINK, "⚑".as_bytes(), R, b" ", B, BMAG, b"waiting for [G]rant access", R, b" ", BWHT, from, R, GRY, arrow, R, BWHT, to, R, b" ", GRY, "· ".as_bytes(), b, R]));
                } else if sh::contains(rest, b"NOT DELIVERED") {
                    // why=${rest#*NOT DELIVERED: } why=${why%)}
                    let p = rest.windows(15).position(|w| w == b"NOT DELIVERED: ");
                    let mut why: Bytes = match p {
                        Some(i) => rest[i + 15..].to_vec(),
                        None => rest.to_vec(),
                    };
                    if why.ends_with(b")") {
                        why.pop();
                    }
                    if sh::contains(&why, b"has changed since it was given permission") {
                        let t = match to.iter().rposition(|&x| x == b'@') {
                            Some(i) => &to[..i],
                            None => &to[..],
                        };
                        why = cat(&[t, b" restarted"]);
                    }
                    let why = substr(&why, 0, Some(60)).unwrap_or_default();
                    msg.push(cat(&[GRY, &when, R, b" ", BRED, "✗".as_bytes(), R, b" ", BWHT, from, R, GRY, arrow, R, BWHT, to, R, b" ", BRED, b"not delivered: ", &why, R, b" ", GRY, "· ".as_bytes(), b, R]));
                } else if rest.starts_with(b" (held") {
                    msg.push(cat(&[GRY, &when, R, b" ", BYEL, "⏸".as_bytes(), R, b" ", BWHT, from, R, GRY, arrow, R, BWHT, to, R, b" ", BYEL, "held ·".as_bytes(), R, b" ", GRY, b, R]));
                } else {
                    msg.push(cat(&[GRY, &when, R, b" ", BGRN, "✉".as_bytes(), R, b" ", BWHT, from, R, GRY, arrow, R, BWHT, to, R, b" ", GRY, b, R]));
                }
            }
            if msg.len() > 4 {
                let k = msg.len() - 4;
                oldm = msg[..k].to_vec();
                msg = msg[k..].to_vec();
            }
        }
        // One waiting whose held rows are older than the ones read: from its introduction instead.
        for d in &asks_d {
            let c = sh::head1(&sh::path(&[d, b"created"]));
            if !c.is_empty() && shown.contains(&c) {
                continue;
            }
            let f = clean(&sh::head1(&sh::path(&[d, b"from"])));
            let t = clean(&sh::head1(&sh::path(&[d, b"to"])));
            let b = clean(&sh::cmdsub(&sh::head_c(&sh::path(&[d, b"intro"]), 200)));
            let when = if m("^[0-9]{1,12}$", &c) {
                // TZ=UTC printf -v when '%(%H:%M)T' "$c": UTC by arithmetic, no change of zone
                // (an epoch of 1 to 12 digits is never negative)
                let t = n(&c).rem_euclid(86400);
                format!("{:02}:{:02}", t / 3600, t / 60 % 60).into_bytes()
            } else {
                b"--:--".to_vec()
            };
            let tail = if b.is_empty() { Vec::new() } else { cat(&[b" ", GRY, "· ".as_bytes(), &b, R]) };
            wait.push(cat(&[GRY, &when, R, b" ", B, BYEL, BLINK, "⚑".as_bytes(), R, b" ", B, BMAG, b"waiting for [G]rant access", R, b" ", BWHT, &f, R, GRY, "→".as_bytes(), R, BWHT, &t, R, &tail]));
        }
        if wait.len() > 3 {
            let more = wait.len() - 2;
            wait.truncate(2);
            wait.push(cat(&[B, BYEL, BLINK, "⚑".as_bytes(), R, b" ", B, BMAG, more.to_string().as_bytes(), b" more waiting for [G]rant access", R]));
        }
        if wait.is_empty() && msg.is_empty() {
            msg.push(cat(&[GRY, b" no messages yet \xc2\xb7 ask an agent to use agent-say", R]));
        }
        let mold = oldm.len() as i64;
        let mwait = if wait.is_empty() { -1 } else { mold };
        let mut all = oldm;
        all.extend(wait);
        all.extend(msg);
        // Approved: allow lines within their day.
        let mut ttl = sh::env("AGENT_SAY_SESSION_TTL").filter(|v| !v.is_empty()).unwrap_or_else(|| b"86400".to_vec());
        if !m("^[1-9][0-9]{0,9}$", &ttl) {
            ttl = b"86400".to_vec();
        }
        let c = self.now() - n(&ttl);
        // awk '$1 == "allow" && $6 ~ /^[0-9]+$/ && $6 > c {n++} END {print n + 0}' grants
        let mut gn = 0i64;
        if let Ok(d) = std::fs::read(sh::os(&sh::path(&[&self.astate, b"/grants"]))) {
            for l in sh::split_lines(&d) {
                let f: Vec<&[u8]> = l.split(|x| *x == b' ' || *x == b'\t').filter(|x| !x.is_empty()).collect();
                if f.first() == Some(&&b"allow"[..]) {
                    if let Some(s6) = f.get(5) {
                        if m("^[0-9]+$", s6) && std::str::from_utf8(s6).ok().and_then(|x| x.parse::<f64>().ok()).is_some_and(|v| v > c as f64) {
                            gn += 1;
                        }
                    }
                }
            }
        }
        if gn != 0 {
            intro_on = b"1".to_vec();
            all.push(cat(&[BGRN, "✓".as_bytes(), R, b" ", GRY, gn.to_string().as_bytes(), " approved · ".as_bytes(), R, BBLU, b"[", B, BYEL, b"G", R, BBLU, b"]", R, GRY, b" to see", R]));
        }
        // find "$ASTATE/queue" -maxdepth 1 -name 'msg.*' ! -name '*.err' | wc -l
        let mut qn = 0;
        if let Ok(rd) = std::fs::read_dir(sh::os(&sh::path(&[&self.astate, b"/queue"]))) {
            for e in rd.flatten() {
                let nm = e.file_name().into_encoded_bytes();
                if nm.starts_with(b"msg.") && !nm.ends_with(b".err") {
                    qn += 1;
                }
            }
        }
        if qn != 0 {
            all.push(cat(&[BYEL, "⧗ ".as_bytes(), qn.to_string().as_bytes(), b" queued, waiting for a busy pane", R]));
        }
        (all, mold, mwait, intro_on)
    }

    /// links_saves -> SIDE: saves, then links
    pub fn links_saves(&mut self) -> Vec<Bytes> {
        let mut side: Vec<Bytes> = Vec::new();
        // last=$(cd -P "$DIR/last" && pwd)
        let lp = sh::path(&[&self.dir, b"/last"]);
        let last: Bytes = if sh::is_dir(&lp) { std::fs::canonicalize(sh::os(&lp)).map(|p| p.into_os_string().into_encoded_bytes()).unwrap_or_default() } else { Vec::new() };
        // The folders in snapshots/ (dot ones too, no links)
        let mut cnt = 0;
        if let Ok(rd) = std::fs::read_dir(sh::os(&sh::path(&[&self.dir, b"/snapshots"]))) {
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() && !p.is_symlink() {
                    cnt += 1;
                }
            }
        }
        let iv = sh::opt(b"@revive-interval", b"60");
        let sj = sh::path(&[&last, b"/state.json"]);
        if !last.is_empty() && sh::is_file(&sj) {
            let d = std::fs::read(sh::os(&sj)).unwrap_or_default();
            let l = super::jq::saved(&d).unwrap_or_default();
            let first = l.split('\n').next().unwrap_or("").as_bytes().to_vec();
            let f = sh::read_ws(&first, 2, b"\t");
            let (at, reason) = (clean(&f[0]), clean(&f[1]));
            side.push(cat(&[BCYN, "▓ SAVED".as_bytes(), R, b" ", BWHT, &substr(&at, 11, Some(8)).unwrap_or_default(), R, b" ", GRY, b"(", &reason, b")", R]));
        } else {
            side.push(cat(&[BCYN, "▓ SAVED".as_bytes(), R, b" ", GRY, b" never", R]));
        }
        side.push(cat(&[GRY, b"  ", cnt.to_string().as_bytes(), " kept · every ".as_bytes(), &iv, "s · on detach".as_bytes(), R]));
        for d in crate::compat::glob_dirs(&sh::path(&[&self.astate, b"/links"])) {
            if !sh::is_file(&sh::path(&[&d, b"on"])) {
                continue;
            }
            let h = clean(&sh::basename_dir(&d));
            let err = clean(&sh::cmdsub(&sh::head_c(&sh::path(&[&d, b"error"]), 60)));
            let pid = sh::cmdsub(&std::fs::read(sh::os(&sh::path(&[&d, b"pid"]))).unwrap_or_default());
            // names=$(grep -c . "$d/names")
            let names: Bytes = match std::fs::read(sh::os(&sh::path(&[&d, b"names"]))) {
                Ok(x) => sh::split_lines(&x).iter().filter(|l| !l.is_empty()).count().to_string().into_bytes(),
                Err(_) => Vec::new(),
            };
            let mut mode: Bytes = Vec::new();
            if sh::is_file(&sh::path(&[&d, b"read-only"])) {
                mode.extend(cat(&[b" ", BYEL, "· read-only".as_bytes(), R]));
            }
            let al_f = sh::path(&[&d, b"allow"]);
            if sh::is_file(&al_f) {
                // al=$(head -c 200 allow | paste -sd, -)
                let raw = sh::head_c(&al_f, 200);
                let al = clean(&sh::split_lines(&raw).join(&b','));
                mode.extend(cat(&[b" ", BYEL, "· only ".as_bytes(), &substr(&al, 0, Some(40)).unwrap_or_default(), R]));
            }
            let ef = sh::path(&[&d, b"error"]);
            let poll = sh::path(&[b"_poll ", &h]);
            if !pid.is_empty() && sh::contains(&ps_args(&pid), &poll) && !sh::nonempty(&ef) {
                let nm = if names.is_empty() { b"0".to_vec() } else { names };
                side.push(cat(&[BGRN, "●".as_bytes(), R, b" ", BWHT, &h, R, &mode, b" ", GRY, "· linked · ".as_bytes(), &nm, b" names", R]));
            } else if sh::is_file(&sh::path(&[&d, b"login"])) {
                side.push(cat(&[BYEL, "●".as_bytes(), R, b" ", BWHT, &h, R, &mode, b" ", BYEL, "· needs login ·".as_bytes(), R, b" ", BBLU, b"[", B, BYEL, b"B", R, BBLU, b"]", R, BWHT, b" log in", R]));
            } else if sh::nonempty(&ef) {
                side.push(cat(&[BRED, "●".as_bytes(), R, b" ", BWHT, &h, R, &mode, b" ", BRED, &err, R]));
            } else {
                side.push(cat(&[BRED, "●".as_bytes(), R, b" ", BWHT, &h, R, &mode, b" ", GRY, "· not running".as_bytes(), R]));
            }
        }
        for d in crate::compat::glob_dirs(&sh::path(&[&self.astate, b"/peers"])) {
            if !sh::is_dir(&d) {
                continue;
            }
            let h = clean(&sh::basename_dir(&d));
            if self.young(&sh::path(&[&d, b"alive"])) {
                side.push(cat(&[BGRN, "◌".as_bytes(), R, b" ", BWHT, &h, R, b" ", GRY, "· checks in here".as_bytes(), R]));
            }
        }
        // ssh connections in panes that aren't linked yet: offered for linking with B.
        let mut seen: Vec<Bytes> = Vec::new();
        let ridge = |h: &[u8], w: &[u8]| cat(&[BYEL, "◇".as_bytes(), R, b" ", BWHT, h, R, b" ", GRY, "· ssh in ".as_bytes(), w, " ·".as_bytes(), R, b" ", BBLU, b"[", B, BYEL, b"B", R, BBLU, b"]", R, BWHT, b"ridge?", R]);
        let linked = |g: &G, h: &[u8]| sh::is_file(&sh::path(&[&g.astate, b"/links/", h, b"/on"]));
        for i in 0..self.p.ssh.len() {
            let h = self.p.ssh[i].clone();
            if h.is_empty() || seen.contains(&h) {
                continue;
            }
            seen.push(h.clone());
            if linked(self, &h) {
                continue;
            }
            let w = if self.p.name[i].is_empty() { self.p.loc[i].clone() } else { self.p.name[i].clone() };
            side.push(ridge(&h, &w));
        }
        for i in 0..self.x_ssh.len() {
            let h = self.x_ssh[i].clone();
            if seen.contains(&h) {
                continue;
            }
            seen.push(h.clone());
            if linked(self, &h) {
                continue;
            }
            side.push(ridge(&h, &self.x_where[i]));
        }
        if side.len() <= 2 {
            side.push(cat(&[GRY, "  no links · ssh to a host and press B".as_bytes(), R]));
        }
        side
    }
}

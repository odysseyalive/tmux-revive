//! B and G: scripts/panel.sh act()'s b|B and g|G|i|I branches, ported line for line as
//! straight-line code with its boxes (pick, ask, code_popup, login_window) waiting in modal.rs
//! and popups.rs, the panel going on under them. Each step's flash is drawn before a command
//! that can take a while, which runs in wait_job so the panel keeps drawing.

use super::boxes::BoxHost;
use super::modal::{PickOpts, NOTE};
use super::popups::{last_line, run_all, scan_env, unsay};
use super::Ui;
use crate::collect::sh::{self, Bytes};
use crate::collect::{m, HOST_RE};
use crate::compat::{blen, clean, glob_dirs, itoa, substr};
use crate::render::{cat, num, State};

/// `${s:0:n}`
fn cut(s: &[u8], n: i64) -> Bytes {
    substr(s, 0, Some(n)).unwrap_or_default()
}

/// `$(head -n 1 FILE)` (nothing when there's no file)
fn head1(f: &[u8]) -> Bytes {
    match std::fs::read(sh::os(f)) {
        Ok(d) => sh::cmdsub(sh::head_n(&d, 1)),
        Err(_) => Vec::new(),
    }
}

/// `[[ -f $ASTATE/links/$1/on ]]`
fn linked(astate: &[u8], h: &[u8]) -> bool {
    sh::is_file(&sh::path(&[astate, b"/links/", h, b"/on"]))
}

/// Every link there is (links/*/on, by a name a host can have): what B's "Unlink all" unlinks
fn all_links(astate: &[u8]) -> Vec<Bytes> {
    glob_dirs(&sh::path(&[astate, b"/links"]))
        .into_iter()
        .filter(|d| sh::is_file(&sh::path(&[d, b"/on"])))
        .map(|d| sh::basename_dir(&d))
        .filter(|h| m(HOST_RE, h))
        .collect()
}

/// What B lists: links waiting for their login first, then every ssh host not linked yet (the
/// selected pane's first), then the links there are to link again (one that fails first), then
/// "other host...", with "Unlink all" ("*") above it when two or more are linked. -> (hosts,
/// labels, kr: the lines U unlinks (" 0 3 "), the hint)
pub fn link_hosts(astate: &[u8], p: &State) -> (Vec<Bytes>, Vec<Bytes>, Bytes, Bytes) {
    let mut hosts: Vec<Bytes> = Vec::new();
    let mut labels: Vec<Bytes> = Vec::new();
    let mut seen: Bytes = b" ".to_vec();
    let mut kr: Bytes = b" ".to_vec();
    let has = |seen: &Bytes, h: &[u8]| sh::contains(seen, &cat(&[b" ", h, b" "]));
    let links = sh::path(&[astate, b"/links"]);
    for d in glob_dirs(&links) {
        if !(sh::is_file(&sh::path(&[&d, b"/on"])) && sh::is_file(&sh::path(&[&d, b"/login"]))) {
            continue;
        }
        let h = sh::basename_dir(&d);
        if !m(HOST_RE, &h) {
            continue;
        }
        kr.extend(cat(&[&itoa(hosts.len() as i64), b" "]));
        seen.extend(cat(&[&h, b" "]));
        labels.push(cat(&[&h, "  · needs login: type its password".as_bytes()]));
        hosts.push(h);
    }
    let mut js: Vec<i64> = vec![-1];
    js.extend(p.snap.arrays.get("P_SSH").map(|a| a.keys().copied().collect::<Vec<_>>()).unwrap_or_default());
    for j in js {
        let i = if j < 0 { p.sel } else { j };
        let h = p.a("P_SSH", i).to_vec();
        if !(!h.is_empty() && !has(&seen, &h) && !linked(astate, &h)) {
            continue;
        }
        let w = if !p.a("P_NAME", i).is_empty() { p.a("P_NAME", i) } else { p.a("P_LOC", i) };
        seen.extend(cat(&[&h, b" "]));
        labels.push(cat(&[&h, "  · ssh in ".as_bytes(), w]));
        hosts.push(h);
    }
    let xs: Vec<i64> = p.snap.arrays.get("X_SSH").map(|a| a.keys().copied().collect()).unwrap_or_default();
    for i in xs {
        let h = p.a("X_SSH", i).to_vec();
        if !(!has(&seen, &h) && !linked(astate, &h)) {
            continue;
        }
        seen.extend(cat(&[&h, b" "]));
        labels.push(cat(&[&h, "  · ssh in ".as_bytes(), p.a("X_WHERE", i)]));
        hosts.push(h);
    }
    for pass in [&b"error"[..], b"ok"] {
        for d in glob_dirs(&links) {
            let h = sh::basename_dir(&d);
            if !(sh::is_file(&sh::path(&[&d, b"/on"])) && !has(&seen, &h) && m(HOST_RE, &h)) {
                continue;
            }
            let mut why = head1(&sh::path(&[&d, b"/error"]));
            // L: what agent-say wrote before B
            for s in [" · L to try again", " · B to try again"] {
                if let Some(w) = why.strip_suffix(s.as_bytes()) {
                    why = w.to_vec();
                    break;
                }
            }
            let why = clean(&why);
            let l: Bytes = if pass == b"error" && sh::is_file(&sh::path(&[&d, b"/paused"])) {
                cat(&[&h, "  · ".as_bytes(), &cut(&why, 40), " · try again".as_bytes()])
            } else if pass == b"error" && !why.is_empty() {
                cat(&[&h, "  · ".as_bytes(), &cut(&why, 40), " · link again".as_bytes()])
            } else if pass == b"ok" && why.is_empty() {
                cat(&[&h, "  · linked · link again".as_bytes()])
            } else {
                Vec::new()
            };
            if !l.is_empty() {
                kr.extend(cat(&[&itoa(hosts.len() as i64), b" "]));
                seen.extend(cat(&[&h, b" "]));
                hosts.push(h);
                labels.push(l);
            }
        }
    }
    if all_links(astate).len() > 1 {
        hosts.push(b"*".to_vec()); // no host is named that
        labels.push(b"Unlink all".to_vec());
    }
    hosts.push(Vec::new());
    labels.push("other host… (type its name)".as_bytes().to_vec());
    let hint = if kr != b" " { "↑↓ choose · Enter picks · U unlinks · Esc closes".as_bytes().to_vec() } else { Vec::new() };
    (hosts, labels, kr, hint)
}

/// G's list: agents on two linked computers asking to talk through this one (waiting), and
/// those you let (approved), with the time each has left of TTL by NOW. -> (ids, labels)
pub fn access_list(astate: &[u8], ttl: i64, now: i64) -> (Vec<Bytes>, Vec<Bytes>) {
    let mut ids: Vec<Bytes> = Vec::new();
    let mut labels: Vec<Bytes> = Vec::new();
    for d in glob_dirs(&sh::path(&[astate, b"/intros"])) {
        if !sh::is_file(&sh::path(&[&d, b"/from"])) {
            continue;
        }
        let f = clean(&head1(&sh::path(&[&d, b"/from"])));
        let t = clean(&head1(&sh::path(&[&d, b"/to"])));
        if ids.is_empty() {
            ids.push(Vec::new());
            labels.push(cat(&[&[NOTE], b"WAITING"]));
        }
        ids.push(cat(&[b"i ", &sh::basename_dir(&d)]));
        labels.push(cat(&[&cut(&f, 30), " → ".as_bytes(), &cut(&t, 30)]));
    }
    let nw = ids.len();
    let grants = std::fs::read(sh::os(&sh::path(&[astate, b"/grants"]))).unwrap_or_default();
    for l in sh::lines(&grants) {
        // while read -r g a b f t w _
        let r = sh::read_ws(&l, 7, b" \t\n");
        let (g, a, b, w) = (&r[0], &r[1], &r[2], &r[5]);
        if !(g == b"allow" && m("^[0-9]{1,12}$", w) && num(w) + ttl > now) {
            continue;
        }
        let (f, t) = (clean(&r[3]), clean(&r[4]));
        let w = num(w) + ttl - now;
        if ids.len() <= nw {
            ids.push(Vec::new());
            labels.push(cat(&[&[NOTE], b"APPROVED"]));
        }
        ids.push(cat(&[b"g ", a, b" ", b]));
        labels.push(cat(&[&cut(&f, 30), " → ".as_bytes(), &cut(&t, 30), " · ".as_bytes(), &itoa(w / 3600), b"h ", &itoa(w % 3600 / 60), b"m left"]));
    }
    // the approvals; two or more, a last line removes them all
    if ids.len() as i64 - nw as i64 - 1 > 1 {
        ids.push(b"all".to_vec());
        labels.push(b"Remove all grants".to_vec());
    }
    (ids, labels)
}

/// `{ read -r v <FILE; } 2>/dev/null`: (whether it read a whole line, what it read)
fn read_r(f: &[u8]) -> (bool, Bytes) {
    super::upd::read_r(f)
}

/// The box for one waiting intro (D its folder, F and T cleaned): first, why it asks: one short
/// line agent-say kept (its --why, or how its message opens). When both wrote first, the other
/// way's too (by its names, as agent-say's intros_between finds it), the earlier one first. Then
/// its words (three lines at most), and a line if its agent restarted since asking.
pub fn intro_lines(astate: &[u8], d: &[u8], f: &[u8], t: &[u8], txt: &[u8]) -> Vec<Bytes> {
    let mut labels: Vec<Bytes> = Vec::new();
    let mut wl: Vec<Bytes> = Vec::new();
    let mut wds: Vec<Bytes> = vec![d.to_vec()];
    wds.extend(glob_dirs(&sh::path(&[astate, b"/intros"])));
    for wd in wds {
        if wl.len() >= 2 {
            break;
        }
        let (_, wf) = read_r(&sh::path(&[&wd, b"/from"]));
        let (_, wt) = read_r(&sh::path(&[&wd, b"/to"]));
        let (_, wc) = read_r(&sh::path(&[&wd, b"/created"]));
        let (wf, wt) = (clean(&wf), clean(&wt));
        if !(wd == d || (wf == t && wt == f)) {
            continue;
        }
        let wy = match read_r(&sh::path(&[&wd, b"/why"])) {
            (true, v) => v,
            _ => {
                let i = std::fs::read(sh::os(&sh::path(&[&wd, b"/intro"]))).unwrap_or_default();
                sh::cmdsub(&i[..i.len().min(60)])
            }
        };
        let mut wy = clean(&wy);
        if blen(&wy) > 80 {
            wy = cat(&[&cut(&wy, 79), "…".as_bytes()]);
        }
        let wc = if m("^[0-9]+$", &wc) { wc } else { b"0".to_vec() };
        let name = match wf.iter().rposition(|&c| c == b'@') {
            Some(i) => wf[..i].to_vec(),
            None => wf.clone(),
        };
        wl.push(cat(&[&wc, &[NOTE], &name, &[NOTE], &wy]));
    }
    // ${x%%"$NOTE"*}, ${x#*"$NOTE"}, ${x##*"$NOTE"}
    let head = |x: &[u8]| x.split(|&c| c == NOTE).next().unwrap_or(b"").to_vec();
    let after = |x: &[u8]| match x.iter().position(|&c| c == NOTE) {
        Some(i) => x[i + 1..].to_vec(),
        None => x.to_vec(),
    };
    let last = |x: &[u8]| match x.iter().rposition(|&c| c == NOTE) {
        Some(i) => x[i + 1..].to_vec(),
        None => x.to_vec(),
    };
    if wl.len() == 1 {
        labels.push(cat(&[&[NOTE], b"why: ", &last(&wl[0])]));
    } else if wl.len() == 2 {
        if num(&head(&wl[1])) < num(&head(&wl[0])) {
            wl.swap(0, 1);
        }
        for wd in &wl {
            let wd = after(wd);
            labels.push(cat(&[&[NOTE], b"why (", &head(&wd), b"): ", &after(&wd)]));
        }
    }
    let wc = labels.len();
    let mut txt = txt.to_vec();
    while !txt.is_empty() && labels.len() < wc + 3 {
        labels.push(cat(&[&[NOTE], &cut(&txt, 60)]));
        txt = substr(&txt, 60, None).unwrap_or_default();
    }
    // Its agent restarted since asking (its computer reports another session in that pane, or
    // none): what it sent is from a conversation that's over.
    let (_, fs) = read_r(&sh::path(&[d, b"/from-session"]));
    // ${f%@*} and ${f#*@}
    let fu = match f.iter().rposition(|&c| c == b'@') {
        Some(i) => f[..i].to_vec(),
        None => f.to_vec(),
    };
    let fh_ = match f.iter().position(|&c| c == b'@') {
        Some(i) => f[i + 1..].to_vec(),
        None => f.to_vec(),
    };
    if fs.starts_with(b"s:") && m(HOST_RE, &fh_) {
        // awk -v n="${f%@*}" '$1 == n {print $2; exit}' "$ASTATE/links/${f#*@}/sessions"
        let s = std::fs::read(sh::os(&sh::path(&[astate, b"/links/", &fh_, b"/sessions"]))).unwrap_or_default();
        let mut cur: Bytes = Vec::new();
        for l in s.split(|&c| c == b'\n') {
            let w: Vec<&[u8]> = l.split(|c| *c == b' ' || *c == b'\t').filter(|x| !x.is_empty()).collect();
            if w.first().is_some_and(|x| *x == fu.as_slice()) {
                cur = w.get(1).map(|x| x.to_vec()).unwrap_or_default();
                break;
            }
        }
        if cat(&[b"s:", &cur, b"@", &fh_]) != fs {
            labels.push(cat(&[&[NOTE], &fu, b" has restarted since asking"]));
        }
    }
    labels
}

impl Ui {
    /// act's G (and I, the key it had before): access. Agents on two linked computers asking to
    /// talk through this one (waiting), and those you let (approved). Only here, by a key you
    /// press, can two of them be let talk. An approval lasts SESSION_TTL (a day) from when it was
    /// given or refreshed; agent-say clears what has lapsed first. Declined ones aren't listed:
    /// they lapse on their own.
    pub(super) fn access(&mut self) {
        let argv = vec![b"timeout".to_vec(), b"10".to_vec(), self.asay(), b"_cull".to_vec()];
        let ttl = self.wait_job(move || {
            let a: Vec<&[u8]> = argv.iter().map(|x| x.as_slice()).collect();
            sh::cmdsub(&sh::run(&a).out)
        });
        let ttl = if m("^[1-9][0-9]{0,9}$", &ttl) { num(&ttl) } else { 86400 };
        let now = self.now();
        let (ids, labels) = access_list(&self.astate, ttl, now);
        if ids.is_empty() {
            return;
        }
        if !self.pick(&mut PickOpts::default(), b"LINK AGENTS TOGETHER", &labels) {
            return;
        }
        let picked = num(&self.picked) as usize;
        let r = sh::read_ws(&ids[picked], 3, b" \t\n");
        let (g, a, b) = (r[0].clone(), r[1].clone(), r[2].clone());
        let mut out: Bytes;
        if g == b"all" {
            // No first, so a bare Enter takes nothing away. Each pair once: revoke takes it both ways.
            let ng = itoa(ids.iter().filter(|x| x.starts_with(b"g ")).count() as i64);
            let items = vec![
                cat(&[&[NOTE], b"Approved agents can't message until you approve them again."]),
                cat(&[&[NOTE], b"Pending ones stay pending."]),
                b"No, keep them".to_vec(),
                cat(&[b"Yes, remove all ", &ng]),
            ];
            if !(self.pick(&mut PickOpts::default(), b"REMOVE ALL GRANTS?", &items) && num(&self.picked) == 3) {
                self.prev.clear();
                return;
            }
            let mut bad: Bytes = Vec::new();
            let mut gone: std::collections::HashSet<(Bytes, Bytes)> = std::collections::HashSet::new();
            for x in &ids {
                let r = sh::read_ws(x, 3, b" \t\n");
                let (g, a, b) = (r[0].clone(), r[1].clone(), r[2].clone());
                if !(g == b"g" && !gone.contains(&(a.clone(), b.clone())) && !gone.contains(&(b.clone(), a.clone()))) {
                    continue;
                }
                gone.insert((a.clone(), b.clone()));
                let argv = vec![self.asay(), b"revoke".to_vec(), a, b];
                let (st, o) = self.wait_job(move || run_all(&argv, &[]));
                if st != 0 && bad.is_empty() {
                    // ${out##*$'\n'}
                    let o = sh::cmdsub(&o);
                    bad = match o.iter().rposition(|&c| c == b'\n') {
                        Some(i) => o[i + 1..].to_vec(),
                        None => o,
                    };
                }
            }
            out = if bad.is_empty() { cat(&[b"Removed ", &ng, b" grants"]) } else { bad };
        } else if g == b"i" {
            let d = sh::path(&[&self.astate, b"/intros/", &a]);
            if !(m("^[0-9a-f]{32}$", &a) && sh::is_file(&sh::path(&[&d, b"/from"]))) {
                return;
            }
            let f = clean(&head1(&sh::path(&[&d, b"/from"])));
            let t = clean(&head1(&sh::path(&[&d, b"/to"])));
            let txt = std::fs::read(sh::os(&sh::path(&[&d, b"/intro"]))).unwrap_or_default();
            let txt = clean(&sh::cmdsub(&txt[..txt.len().min(180)]));
            // Its words (three lines at most), then the two choices. Approving takes a code
            // typed back in a popup, so agents on other computers can't approve it (one running
            // as you here could), and neither can a stray Enter here.
            let mut labels = intro_lines(&self.astate, &d, &f, &t, &txt);
            let nt = labels.len();
            labels.push(b"Approve".to_vec());
            labels.push(b"Deny".to_vec());
            if !self.pick(&mut PickOpts::default(), &cat(&[&cut(&f, 24), " → ".as_bytes(), &cut(&t, 24)]), &labels) {
                self.prev.clear(); // all of it drawn again over the box
                return;
            }
            if num(&self.picked) as usize == nt {
                let (ok, cp) = self.code_popup(&cat(&[b"Allow ", &f, b" to talk with ", &t, b"?"]), b"allow", &[b"approve", &a]);
                if !ok {
                    return;
                }
                out = cp;
                self.prev.clear();
                if out.is_empty() {
                    out = b"not approved: the code didn't match, so it's still waiting".to_vec();
                }
            } else {
                let argv = vec![self.asay(), b"_intro".to_vec(), b"deny".to_vec(), a.clone()];
                out = last_line(&self.wait_job(move || run_all(&argv, &[]).1));
            }
        } else {
            // Refresh first, so a bare Enter takes nothing away.
            let lab = &labels[picked];
            let l = match sh::contains(lab, " · ".as_bytes()) {
                true => lab[..lab.windows(" · ".len()).position(|w| w == " · ".as_bytes()).unwrap()].to_vec(),
                false => lab.clone(),
            };
            let lt = cut(lab, 60);
            if !self.pick(&mut PickOpts::default(), &lt, &[b"Refresh".to_vec(), b"Remove".to_vec()]) {
                self.prev.clear();
                return;
            }
            if num(&self.picked) == 0 {
                // The same code popup as Approve: no agent can refresh its own access.
                let (ok, cp) = self.code_popup(&cat(&[b"Refresh ", &l, b" for another day?"]), b"refresh", &[b"grant_refresh", &a, &b]);
                if !ok {
                    return;
                }
                out = cp;
                self.prev.clear();
                if out.starts_with(b"refreshed:") {
                    out = cat(&[b"refreshed: ", &l, " · ".as_bytes(), &itoa(ttl / 3600), b"h left"]);
                } else if out.is_empty() {
                    out = b"not refreshed: the code didn't match".to_vec();
                }
            } else {
                let argv = vec![self.asay(), b"revoke".to_vec(), a.clone(), b.clone()];
                let (st, o) = self.wait_job(move || run_all(&argv, &[]));
                out = sh::cmdsub(&o);
                if st == 0 {
                    out = cat(&[b"removed: ", &l]);
                }
            }
            // out=${out##*$'\n'}
            if let Some(i) = out.iter().rposition(|&c| c == b'\n') {
                out = out[i + 1..].to_vec();
            }
        }
        self.prev.clear(); // the boxes drawn over, all of it again
        self.flash(&unsay(&out));
    }

    /// link_out ARGS: what agent-say link said: all of it (LOUT), and the line to show (out)
    fn link_out(&mut self, h: &[u8], largs: &[Bytes], scan: &[u8]) -> (Bytes, Bytes) {
        let mut argv = vec![b"timeout".to_vec(), b"30".to_vec(), self.asay(), b"link".to_vec(), h.to_vec()];
        argv.extend(largs.iter().cloned());
        let env = scan_env(scan);
        let lout = sh::cmdsub(&self.wait_job(move || run_all(&argv, &env).1));
        let out = sh::here(&lout)
            .into_iter()
            .find(|l| (l.starts_with(b"linked to") || l.starts_with(b"agent-say:")) && !l.starts_with(b"agent-say: WARNING"))
            .unwrap_or_default();
        (lout, out)
    }

    /// act's B: link, relink, log in, unlink, and the link key. Every step of one B (its key
    /// shown, the link, a login) shares one ssh-keyscan of the host (AGENT_SAY_SCAN_ID): each
    /// scan is a connection that never logs in, which servers count against you.
    pub(super) fn link(&mut self) {
        let scan = cat(&[b"b", &itoa(std::process::id() as i64), &itoa((unsafe { libc::rand() } % 32768) as i64), &itoa(self.secs())]);
        let (hosts, labels, kr, hint) = link_hosts(&self.astate, &self.c.p);
        let all = all_links(&self.astate); // what "Unlink all" unlinks, as the list had them
        let mut o = PickOpts { keys: b"u".to_vec(), krows: kr, hint: Some(hint), ..Default::default() };
        if !self.pick(&mut o, b"ATTACH SERVERS", &labels) {
            return;
        }
        let mut h = hosts[num(&self.picked) as usize].clone();
        if self.pkey == b"u" {
            self.unlink_host(&h, &scan);
            return;
        }
        if h == b"*" {
            let items = vec![
                cat(&[&[NOTE], b"Each computer is unlinked in turn."]),
                cat(&[&[NOTE], b"Any that can't be reached are listed."]),
                b"No, keep them".to_vec(),
                cat(&[b"Yes, unlink all ", &itoa(all.len() as i64)]),
            ];
            if !(self.pick(&mut PickOpts::default(), &cat(&[b"UNLINK ALL ", &itoa(all.len() as i64), b" COMPUTERS?"]), &items) && num(&self.picked) == 3) {
                return;
            }
            self.unlink_all(&all, &scan);
            return;
        }
        if h.is_empty() {
            if !self.ask(b"Host to link (as you'd type after ssh):") {
                return;
            }
            h = self.reply.clone();
            if !m(HOST_RE, &h) {
                self.flash(&cat(&[b"not a host name: ", &h]));
                return;
            }
        }
        let ld = sh::path(&[&self.astate, b"/links/", &h]);
        let lf = |x: &[u8]| sh::is_file(&sh::path(&[&ld, x]));
        // A link whose login dropped: its key was confirmed when it was linked (and the link
        // checks it still), so only the login is asked for. LINKS then shows how it went.
        if linked(&self.astate, &h) && lf(b"/login") {
            self.flash(&cat(&[b"logging in to ", &h, "…".as_bytes()]));
            BoxHost::draw(self);
            self.login_window(&h, &[], &scan);
            self.c.p.flash.clear();
            return;
        }
        // A link there already (working or not): link it again, fresh, with the key ssh uses
        // for it now, or unlink it. Nothing changes until you say which. A link stopped on a
        // failure is tried again, once, with the key it has. A link not on the link key yet can
        // move to it: linked again as it is, with no unlink (agent-say's key_setup).
        let (mut again, mut was, mut usekey) = (false, Vec::new(), false);
        if linked(&self.astate, &h) && lf(b"/paused") {
            self.flash(&cat(&[b"trying ", &h, " again…".as_bytes()]));
            BoxHost::draw(self);
        } else if linked(&self.astate, &h) {
            let mut items = vec![
                cat(&[&[NOTE], b"It unlinks, then links again with the key ssh uses now."]),
                b"No, leave it as is".to_vec(),
                cat(&[b"Yes, link ", &h, b" again"]),
                cat(&[b"Unlink ", &h]),
            ];
            if !lf(b"/linkkey") {
                items.push(cat(&[b"Use the link key for ", &h]));
            }
            if !(self.pick(&mut PickOpts::default(), &cat(&[b"LINK ", &h, b" AGAIN?"]), &items) && num(&self.picked) > 1) {
                return;
            }
            match num(&self.picked) {
                3 => {
                    self.unlink_host(&h, &scan);
                    return;
                }
                4 => {
                    usekey = true;
                    self.flash(&cat(&[b"moving ", &h, " to the link key…".as_bytes()]));
                    BoxHost::draw(self);
                }
                _ => {
                    again = true;
                    was = sh::cmdsub(&std::fs::read(sh::os(&sh::path(&[&ld, b"/fingerprint"]))).unwrap_or_default());
                }
            }
        }
        // Its host key, found the way ssh itself has it. You only say yes or no to linking, Yes
        // first; a key that changed since you linked it has No first, so Enter alone doesn't
        // take it.
        self.flash(&cat(&[b"reading ", &h, "'s host key…".as_bytes()]));
        BoxHost::draw(self);
        let (mut keys, mut key_state) = self.read_host_keys(&h, if again { &b"--fresh"[..] } else { b"" }, &scan);
        self.prev.clear();
        let mut largs: Vec<Bytes> = Vec::new();
        let mut linked_msg: Bytes = Vec::new();
        if key_state == b"recorded" {
            linked_msg = cat(&[b"relinked ", &h, b" with the key you confirmed"]);
        } else {
            let mut title = cat(&[b"LINK ", &h, b"?"]);
            // Yes first, but for a key that changed (it could be someone in between).
            let mut yn = vec![cat(&[b"Yes, link ", &h]), cat(&[b"No, don't link ", &h])];
            let mut first = false;
            let warn = cat(&[b"WARNING: ", &h, b"'s HOST KEY CHANGED since you linked it"]);
            let mut note: Bytes = match key_state.as_slice() {
                b"trusted" => b"key from your known_hosts".to_vec(),
                b"live" => {
                    first = true;
                    b"key read through your open ssh connection".to_vec()
                }
                b"changed" => {
                    title = warn.clone();
                    yn.swap(0, 1);
                    b"its key now".to_vec()
                }
                _ => {
                    first = true;
                    b"new host: first key seen".to_vec()
                }
            };
            // Linked before, and none of the keys you confirmed then is among these: say so,
            // whatever vouches for them now (your known_hosts too may have changed).
            if !was.is_empty() && !keys.is_empty() && !sh::here(&was).iter().any(|l| keys.contains(l)) {
                title = warn.clone();
                yn = vec![cat(&[b"No, don't link ", &h]), cat(&[b"Yes, link ", &h])];
            }
            if !keys.is_empty() {
                note.extend(cat(&[b": ", &keys[0]]));
            } else {
                note = b"no key found (not in known_hosts, no answer to ssh-keyscan)".to_vec();
                first = false;
            }
            let mut notes = vec![cat(&[&[NOTE], &note])];
            if first {
                notes.push(cat(&[&[NOTE], b"First time we see this key, so check it matches your server."]));
            }
            let mut items = notes.clone();
            items.extend(yn.iter().cloned());
            if !self.pick(&mut PickOpts::default(), &title, &items) {
                self.c.p.flash.clear();
                return;
            }
            let p = num(&self.picked) - notes.len() as i64 + 1;
            if !yn.get((p - 1).max(0) as usize).is_some_and(|y| y.starts_with(b"Yes")) {
                self.c.p.flash.clear();
                return;
            }
            if key_state == b"trusted" {
                for k in &keys {
                    largs.push(b"--fingerprint".to_vec());
                    largs.push(k.clone());
                }
                linked_msg = cat(&[b"linked to ", &h, b" with the key from your known_hosts: ", &keys[0]]);
            } else if !keys.is_empty() {
                keys.truncate(1);
                largs = vec![b"--yes".to_vec(), b"--fingerprint".to_vec(), keys[0].clone()];
                if key_state == b"live" {
                    linked_msg = cat(&[b"linked to ", &h, b" with the key its open ssh connection uses: ", &keys[0]]);
                }
            } else {
                largs = vec![b"--yes".to_vec(), b"--no-key".to_vec()];
            }
            key_state = b"given".to_vec();
        }
        if again {
            self.flash(&cat(&[b"unlinking ", &h, "…".as_bytes()]));
            BoxHost::draw(self);
            let argv = vec![b"timeout".to_vec(), b"30".to_vec(), self.asay(), b"unlink".to_vec(), h.clone()];
            let env = scan_env(&scan);
            self.wait_job(move || run_all(&argv, &env));
            let _ = std::fs::remove_file(sh::os(&sh::path(&[&self.rdir, b"/", &h, b".rows"])));
        }
        self.flash(&cat(&[b"linking ", &h, "…".as_bytes()]));
        BoxHost::draw(self);
        let (mut lout, mut out) = self.link_out(&h, &largs, &scan);
        // Relinked, and turned away for its key: another key answers to it now. You see that
        // one, warned, and the link is bound to it only if you pick it here (by its fingerprint).
        if sh::contains(&lout, b"check it, then link again and confirm the new key") {
            // (its KEY_STATE is never read: changed, once a key is picked, or the end)
            keys = self.read_host_keys(&h, b"--new", &scan).0;
            if keys.is_empty() {
                self.flash(&cat(&[&h, b"'s host key isn't the one you confirmed, and ssh-keyscan shows no other, so it's not linked"]));
                return;
            }
            let items = vec![cat(&[&[NOTE], b"its key now: ", &keys[0]]), cat(&[b"No, don't link ", &h]), cat(&[b"Yes, link ", &h])];
            if !(self.pick(&mut PickOpts::default(), &cat(&[b"WARNING: ", &h, b"'s HOST KEY CHANGED since you linked it"]), &items) && num(&self.picked) == 2) {
                self.c.p.flash.clear();
                return;
            }
            keys.truncate(1);
            key_state = b"changed".to_vec();
            linked_msg.clear();
            largs = vec![b"--yes".to_vec(), b"--fingerprint".to_vec(), keys[0].clone()];
            self.flash(&cat(&[b"linking ", &h, "…".as_bytes()]));
            BoxHost::draw(self);
            (lout, out) = self.link_out(&h, &largs, &scan);
        }
        // A host that wants a password: you log in once, in a popup, and the link is made over
        // that login. The password can only go to a computer holding a key you just confirmed
        // (agent-say's login checks it strictly before ssh asks), so none confirmed, no login.
        // Relinked, it is the key the link recorded (login_window with none given takes that).
        if sh::contains(&out, &cat(&[&h, b" needs a login"])) {
            if keys.is_empty() {
                self.flash(&cat(&[b"no host key of ", &h, b" to confirm, so no password is sent to it; not linked"]));
                return;
            }
            if key_state == b"recorded" {
                keys.clear();
            }
            self.flash(&cat(&[b"logging in to ", &h, "…".as_bytes()]));
            BoxHost::draw(self);
            if !self.login_window(&h, &keys, &scan) {
                self.flash(&cat(&[b"not logged in to ", &h, b"; not linked"]));
                return;
            }
            self.flash(&cat(&[b"linking ", &h, "…".as_bytes()]));
            BoxHost::draw(self);
            (lout, out) = self.link_out(&h, &largs, &scan);
        }
        let mut out = clean(&out);
        if !linked_msg.is_empty() && out.starts_with(b"linked to ") {
            out = linked_msg.clone();
        }
        let made = |out: &Bytes| out.starts_with(b"linked to ") || (!linked_msg.is_empty() && *out == linked_msg);
        // What came of the link key (key_setup): said instead, when moving to it was what you
        // asked; and a line it couldn't put there itself, shown whole for you to place.
        let lines = sh::here(&lout);
        let kl = clean(&lines.iter().find(|l| l.starts_with(b"link key: ")).cloned().unwrap_or_default());
        let mut kline = clean(&lines.iter().find(|l| l.starts_with(b"link key line, ")).cloned().unwrap_or_default());
        let kl_ = kl.strip_prefix(b"link key: ".as_slice()).unwrap_or(&kl).to_vec();
        if usekey && !kl.is_empty() && made(&out) {
            out = kl_.clone();
        }
        if !kline.is_empty() {
            let mut kn = vec![cat(&[&[NOTE], &kl_]), vec![NOTE]];
            while !kline.is_empty() {
                kn.push(cat(&[&[NOTE], &cut(&kline, 70)]));
                kline = substr(&kline, 70, None).unwrap_or_default();
            }
            kn.push(b"OK".to_vec());
            self.pick(&mut PickOpts::default(), &cat(&[b"LINK KEY FOR ", &h]), &kn);
        }
        // Linked, LINKS shows it; tried once and failed, LINKS shows why. Anything else (a link
        // that never got made, what came of the link key) is said on the bar.
        if made(&out) || lf(b"/paused") {
            self.c.p.flash.clear();
        } else {
            self.flash(&unsay(&out));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compat::tests::{bash, setup};
    use crate::render::prim::tests::bash_prims;
    use crate::snapshot::Snapshot;
    use std::fs;

    /// The lines of act() from the one holding FROM to the one holding TO (both in): bash's B
    /// and G are inline in act(), not functions of their own
    fn act_lines(from: &str, to: &str) -> String {
        let src = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        let a = src.find("\nact() {").expect("act in panel.sh");
        let mut out = String::new();
        let mut on = false;
        for l in src[a..].lines() {
            if !on && l.contains(from) {
                on = true;
            }
            if on {
                out += l;
                out += "\n";
                if l.contains(to) {
                    return out;
                }
            }
        }
        panic!("no {} .. {} in act()", from, to);
    }

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("flows-test-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn state(recs: &[(&str, &str, &str)], sel: i64) -> State {
        let mut p = State::default();
        p.snap = Snapshot::apply(&recs.iter().map(|(a, b, c)| (a.as_bytes().to_vec(), b.as_bytes().to_vec(), c.as_bytes().to_vec())).collect::<Vec<_>>()).unwrap();
        p.sel = sel;
        p
    }

    /// bash's assignments for these arrays
    fn decl(recs: &[(&str, &str, &str)]) -> String {
        let mut s = String::new();
        for (n, i, v) in recs {
            s += &format!("{}[{}]=$'{}'\n", n, i, v.replace('\\', "\\\\").replace('\'', "\\'"));
        }
        s
    }

    fn show(v: &[Bytes]) -> String {
        v.iter().map(|x| String::from_utf8_lossy(x).into_owned() + "\n").collect()
    }

    /// B's list against bash's: links needing their login, ssh hosts (the selected pane's first,
    /// none twice, none linked), outside ones, links to link again (failing first, an older
    /// agent-say's "· L to try again" dropped, a long error cut), "Unlink all" and the "other host…"
    /// line, which lines U unlinks and the hint
    #[test]
    fn link_hosts_as_bash() {
        setup();
        let d = tmp("hosts");
        let st = d.join("state");
        let l = st.join("links");
        for (h, files) in [
            ("pw.example", vec![("on", ""), ("login", "")]),
            ("ok.example", vec![("on", "")]),
            ("Bad.example", vec![("on", ""), ("error", "stopped: host key changed since you linked it. Press B to link it again, a long one\n")]),
            ("slow.example", vec![("on", ""), ("paused", ""), ("error", "can't reach (connection timed out) · L to try again\n")]),
            ("off.example", vec![("error", "x\n")]),
            ("-bad", vec![("on", ""), ("login", "")]),
            ("esc.example", vec![("on", ""), ("error", "it said \x1b[31mred\x1b[0m · B to try again\n")]),
        ] {
            fs::create_dir_all(l.join(h)).unwrap();
            for (f, c) in files {
                fs::write(l.join(h).join(f), c).unwrap();
            }
        }
        let recs: Vec<(&str, &str, &str)> = vec![
            ("P_SSH", "0", ""),
            ("P_NAME", "0", "shop"),
            ("P_SSH", "1", "devbox.example"),
            ("P_NAME", "1", ""),
            ("P_LOC", "1", "work:1.0"),
            ("P_SSH", "2", "sel.example"),
            ("P_NAME", "2", "seln"),
            ("P_SSH", "3", "devbox.example"),
            ("P_NAME", "3", "again"),
            ("P_SSH", "4", "ok.example"),
            ("P_NAME", "4", "linked-one"),
            ("X_SSH", "0", "away.example"),
            ("X_WHERE", "0", "kitty"),
            ("X_SSH", "1", "sel.example"),
            ("X_WHERE", "1", "x"),
            ("X_SSH", "2", "out2.example"),
            ("X_WHERE", "2", "foot"),
        ];
        let stb = st.as_os_str().as_encoded_bytes().to_vec();
        for (recs, sel) in [(recs.clone(), 2), (recs.clone(), 0), (vec![("P_SSH", "0", "")], 0)] {
            let (hosts, labels, kr, hint) = link_hosts(&stb, &state(&recs, sel));
            let ours = format!("{}--\n{}--\n[{}] [{}]\n", show(&hosts), show(&labels), String::from_utf8_lossy(&kr), String::from_utf8_lossy(&hint));
            let body = format!(
                "{}\nNOTE=$'\\x1f' ASTATE=$1 SEL={}\nlinked() {{ [[ -f $ASTATE/links/$1/on ]]; }}\nP_SSH=() P_NAME=() P_LOC=() X_SSH=() X_WHERE=()\n{}\nf() {{\n{}\nprintf '%s\\n' \"${{hosts[@]}}\" -- \"${{labels[@]}}\" --; echo \"[$kr] [$hint]\"; }}\nf",
                bash_prims(),
                sel,
                decl(&recs),
                act_lines("local hosts=() labels=() seen=", "[[ $kr != \" \" ]] && hint=")
            );
            let theirs = bash(&body, &[&stb]);
            assert_eq!(ours, String::from_utf8_lossy(&theirs), "sel {}", sel);
        }
        let _ = fs::remove_dir_all(&d);
    }

    /// G's list and an intro's box against bash's: waiting intros (an odd name cleaned and cut),
    /// approvals in their time with what's left (lapsed, declined and unfinished lines not), the
    /// line that removes them all, the why lines (both ways with the earlier first, from how the
    /// message opens when there's no why whole, cut at 80), the words in three lines at most, and
    /// the restarted line
    #[test]
    fn access_as_bash() {
        setup();
        let d = tmp("access");
        let st = d.join("state");
        let now = 1_800_000_000i64;
        let ia = "1111111111111111aaaaaaaaaaaaaaaa";
        let ib = "2222222222222222bbbbbbbbbbbbbbbb";
        let ic = "3333333333333333cccccccccccccccc";
        let intro = |id: &str, from: &str, to: &str, text: &str, created: &str| {
            let p = st.join("intros").join(id);
            fs::create_dir_all(&p).unwrap();
            fs::write(p.join("from"), format!("{}\n", from)).unwrap();
            fs::write(p.join("to"), format!("{}\n", to)).unwrap();
            fs::write(p.join("intro"), text).unwrap();
            fs::write(p.join("created"), format!("{}\n", created)).unwrap();
            fs::write(p.join("from-session"), format!("s:{}@{}\n", id, from.split('@').nth(1).unwrap_or(""))).unwrap();
        };
        intro(ia, "live-root@far.invalid", "dev-root@near.invalid", &format!("may I ask dev-root about the failing build? {}", "and more words ".repeat(20)), "200");
        intro(ib, "a-name-that-is-rather-long-for-one@far.invalid", "dev\x1b[31m-root@near.invalid", "hello", "50");
        intro(ic, "dev-root@near.invalid", "live-root@far.invalid", "and back the other way, how it opens: a long first line of words that goes on", "100");
        fs::write(st.join("intros").join(ia).join("why"), format!("needs the logs\x1b]0;x\x07 {}\n", "w".repeat(90))).unwrap();
        fs::write(st.join("intros").join(ic).join("why"), "no newline at its end").unwrap();
        fs::create_dir_all(st.join("links/far.invalid")).unwrap();
        fs::write(st.join("links/far.invalid/sessions"), format!("  live-root   {}\ncx other\n", ia)).unwrap();
        fs::write(
            st.join("grants"),
            format!(
                "allow s:a1@far.invalid s:b1@near.invalid ann@far.invalid bob@near.invalid {}\ndeny s:c1 s:d1 cat@far.invalid dan@near.invalid {}\nallow s:e s:f old@x new@y {}\nallow s:g s:h odd@x\x1b[1m y@z {} extra words\nallow s:i s:j last@x nonl@y {}",
                now - 3600,
                now,
                now - 90000,
                now - 7,
                now
            ),
        )
        .unwrap();
        let stb = st.as_os_str().as_encoded_bytes().to_vec();
        let mut ours = String::new();
        let (ids, labels) = access_list(&stb, 86400, now);
        ours += &format!("{}--\n{}--\n", show(&ids), show(&labels));
        for id in [ia, ib, ic] {
            let dd = sh::path(&[&stb, b"/intros/", id.as_bytes()]);
            let f = clean(&head1(&sh::path(&[&dd, b"/from"])));
            let t = clean(&head1(&sh::path(&[&dd, b"/to"])));
            let txt = fs::read(sh::os(&sh::path(&[&dd, b"/intro"]))).unwrap();
            let txt = clean(&sh::cmdsub(&txt[..txt.len().min(180)]));
            ours += &show(&intro_lines(&stb, &dd, &f, &t, &txt));
            ours += "--\n";
        }
        let body = format!(
            "{}\nNOTE=$'\\x1f' ASTATE=$1 now=$2 ttl=86400\nlst() {{ local ids=() labels=() d f t w g a b\n{}\nprintf '%s\\n' \"${{ids[@]}}\" -- \"${{labels[@]}}\" --; }}\nlst\n\
             one() {{ local labels=() d=$ASTATE/intros/$1 f t txt\nf=$(head -n 1 \"$d/from\") t=$(head -n 1 \"$d/to\") txt=$(head -c 180 \"$d/intro\")\nclean f t txt\n{}\nprintf '%s\\n' \"${{labels[@]}}\" --; }}\none {}; one {}; one {}",
            bash_prims(),
            act_lines("for d in \"$ASTATE\"/intros/*/; do", "ids+=(\"all\")"),
            act_lines("\t\t\tlabels=()", "local nt=${#labels[@]}"),
            ia,
            ib,
            ic
        );
        let theirs = bash(&body, &[&stb, now.to_string().as_bytes()]);
        assert_eq!(ours, String::from_utf8_lossy(&theirs));
        let _ = fs::remove_dir_all(&d);
    }
}

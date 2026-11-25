//! The question: scripts/panel.sh draw_question, qhi and question_parts (plan Phase 1.3, step
//! 6). The screen and its coloured capture come from the snapshot, as bash's pane_screen gives
//! them under REVIVE_PANEL_SNAP; while answering, from QL.

use super::panes::sub;
use super::*;
use crate::compat::{blen, clean, itoa, re, read_split, Bytes};

/// The tab bar's line: `^[[:space:]]*←.*→[[:space:]]*$`
const TABBAR: &str = "^[[:space:]]*←.*→[[:space:]]*$";

impl Ctx {
    /// draw_question LINES: only the dialog at the bottom of its screen, bright
    pub fn draw_question(&mut self, lines: i64) {
        let id = self.p.sel_id();
        let name = self.p.sel_name();
        let host = self.p.sel_host();
        let keys = if self.p.answering != 0 {
            // On a free-text choice, [E]nter opens the box to write its answer in.
            let kc = if self.p.qon != 0 {
                self.kcs(&[b"E", b"nter", b"Esc", b" or", b"Ctrl-]", b" leaves"])
            } else {
                self.kcs(&[b"Esc", b" or", b"Ctrl-]", b" leaves"])
            };
            cat(&[B, BMAG, b"keys go to ", &name, R, b"  ", &kc])
        } else if !host.is_empty() {
            self.kcs(&[b"Enter", b" answer"])
        } else {
            self.kcs(&[b"Enter", b" answer", b"O", b" open the chat"])
        };
        let ft: &[u8] = if self.p.wf == 1 { "▸ ".as_bytes() } else { b"" };
        let (wb, wk) = (self.p.wb[1].clone(), self.p.wk[1].clone());
        self.sectk(&cat(&[ft, "QUESTION · ".as_bytes(), &name]), &keys, Some(b"5"), Some(&wb), Some(&wk));
        if self.p.answering != 0 {
            self.p.l = self.p.list("QL"); // answer() has just read it
        } else if !host.is_empty() {
            self.remote_peek(60);
        } else if !id.is_empty() {
            self.p.l = self.pane_screen(&id, false).iter().map(|l| clean(l)).collect();
        } else {
            // L is draw_peek's local, empty
            self.p.l = Vec::new();
        }
        self.question_parts();
        self.p.qhi.clear();
        if host.is_empty() && !id.is_empty() {
            self.qhi(&id);
        }
        self.peek_rows(lines, BMAG, true, BMAG);
    }

    /// qhi %ID -> QHI[i]="START LENGTH": on a question's tab bar, the tab Claude Code highlights
    /// (by a background colour only), read from the pane's coloured capture
    pub fn qhi(&mut self, id: &[u8]) {
        self.p.qhi.clear();
        let tb = re(TABBAR);
        let l = self.p.l.clone();
        // for i in "${!L[@]}"; do ... && break; done; [[ ${L[i]:-} =~ ... ]] || return 0
        if !l.iter().any(|x| tb.is_match(x)) {
            return;
        }
        let e = self.pane_screen(id, true);
        let sgr = re("^\x1b\\[([0-9;:]*)m");
        for (i, line) in l.iter().enumerate() {
            if !tb.is_match(line) {
                continue;
            }
            let mut s: Bytes = e.get(i).cloned().unwrap_or_default();
            let (mut pos, mut st, mut en, mut on) = (0i64, -1i64, -1i64, 0);
            while !s.is_empty() {
                if let Some(m) = sgr.matches(&s) {
                    s = sub(&s, blen(&m[0]), None);
                    let codes: &[u8] = if m[1].is_empty() { b"0" } else { &m[1] };
                    let mut p = read_split(codes, b';');
                    if p.is_empty() {
                        p = vec![b"0".to_vec()];
                    }
                    let mut c = 0usize;
                    while c < p.len() {
                        // p=${P[c]%%:*}
                        let pc: &[u8] = match p[c].iter().position(|&x| x == b':') {
                            Some(k) => &p[c][..k],
                            None => &p[c],
                        };
                        let nxt = |c: usize| -> &[u8] { p.get(c + 1).map(|v| v.as_slice()).unwrap_or(b"") };
                        match pc {
                            b"" | b"0" | b"27" | b"49" => on = 0,
                            b"7" | b"40" | b"41" | b"42" | b"43" | b"44" | b"45" | b"46" | b"47" | b"100" | b"101" | b"102" | b"103" | b"104" | b"105" | b"106" | b"107" => on = 1,
                            b"48" => {
                                on = 1;
                                if nxt(c) == b"5" {
                                    c += 2;
                                }
                                if nxt(c) == b"2" {
                                    c += 4;
                                }
                            }
                            b"38" | b"58" => {
                                if nxt(c) == b"5" {
                                    c += 2;
                                }
                                if nxt(c) == b"2" {
                                    c += 4;
                                }
                            }
                            _ => {}
                        }
                        c += 1;
                    }
                } else {
                    let first = sub(&s, 0, Some(1));
                    if first == b"\x1b" {
                        s = sub(&s, 1, None); // any other escape: not text
                        continue;
                    }
                    if on != 0 && (first != b" " || st >= 0) {
                        if st < 0 {
                            st = pos;
                        }
                        if first != b" " {
                            en = pos;
                        }
                    }
                    s = sub(&s, 1, None);
                    pos += 1;
                }
            }
            if st >= 0 && en >= st {
                self.p.qhi.insert(i as i64, cat(&[&itoa(st), b" ", &itoa(en - st + 1)]));
            }
        }
    }

    /// question_parts -> QSTYLE[i]: a colour for each line of L by what it is
    pub fn question_parts(&mut self) {
        self.p.qstyle.clear();
        let l = &self.p.l;
        let n = l.len() as i64;
        let at = |i: i64| -> &[u8] { if i >= 0 { l.get(i as usize).map(|v| v.as_slice()).unwrap_or(b"") } else { l.get((n + i) as usize).map(|v| v.as_slice()).unwrap_or(b"") } };
        let (mut first, mut top, mut last) = (-1i64, -1i64, -1i64);
        let mut i = n - 1;
        while i >= 0 {
            if re(r"^[[:space:]│]*([❯›][[:space:]]*)?1\.[[:space:]]").is_match(at(i)) {
                first = i;
                break;
            }
            i -= 1;
        }
        if first < 0 {
            return;
        }
        let rule = re("^[[:space:]]*[─━═╌]{8,}");
        let blank = re("^[[:space:]]*$");
        let mut i = first - 1;
        while i >= 0 && i >= first - 20 {
            if rule.is_match(at(i)) {
                top = i;
                break;
            }
            i -= 1;
        }
        if top < 0 {
            let mut i = first - 1;
            while i > 0 && blank.is_match(at(i)) {
                i -= 1;
            }
            while i > 0 && i >= first - 10 {
                // ${L[i - 1]}: i - 1 is 0 at least here
                if blank.is_match(at(i)) && blank.is_match(at(i - 1)) {
                    top = i;
                    break;
                }
                i -= 1;
            }
        }
        if top < 0 {
            top = if first > 6 { first - 6 } else { 0 };
        }
        let mut i = n - 1;
        while i > first {
            if re("(Esc to|Enter to|to navigate|to cancel|[Ee]nter (select|confirm|submit|choose)|[Ee]sc (back|cancel|close))").is_match(at(i)) {
                last = i;
                break;
            }
            i -= 1;
        }
        let mut qs = BTreeMap::new();
        for i in 0..n {
            let s = at(i);
            let st: Bytes = if i < top {
                cat(&[GRY, DIM])
            } else if rule.is_match(s) {
                MAG.to_vec()
            } else if i < first {
                cat(&[B, BYEL])
            } else if last >= 0 && i >= last {
                GRY.to_vec()
            } else if re(r"^[[:space:]│]*[❯›].*\[[^[:space:]]\]").is_match(s) {
                cat(&[QBAND, B, BGRN])
            } else if re("^[[:space:]│]*[❯›]").is_match(s) {
                cat(&[QBAND, B, BWHT])
            } else if re(r"^[[:space:]│]*[0-9]+\.[[:space:]]*\[[^[:space:]]\]").is_match(s) {
                cat(&[B, BGRN])
            } else if re(r"^[[:space:]│]*(\[.\][[:space:]]*)?[0-9]+\.").is_match(s) {
                BWHT.to_vec()
            } else if re("^[[:space:]│]*(Next|Submit)[[:space:]]*$").is_match(s) {
                BWHT.to_vec()
            } else {
                GRY.to_vec()
            };
            qs.insert(i, st);
        }
        self.p.qstyle = qs;
    }
}

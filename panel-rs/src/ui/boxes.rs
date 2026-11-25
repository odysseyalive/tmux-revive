//! One box at a time: scripts/panel.sh's box_flow, box_answered, box_out and box_clean, and the
//! two BOX_ lines at the top of its draw, ported literally (same names, same state).
//!
//! The boxes over the panel (pick, ask, note, and later edit_box, code_popup, login_window) show
//! one at a time. A box that opens from another has the panel under it drawn clean first, so
//! the one before is gone. Esc on it brings the one before back as it was (its title, its
//! choices, the one highlighted, what was typed), and the key goes on from there; finished, the
//! key goes on as it does.
//! What each box of the key asked and answered is kept, in order (BOX_LOG: its look, then its
//! status and answer, split by BOX_RS). Going back runs the key again (box_flow): the boxes
//! before come back answered as they were, unseen (BOX_PLAY), and the one to go back to is shown
//! again (BOX_AT), with its answer (BOX_SEL) highlighted or typed in. Only while the key has
//! drawn nothing but boxes: once it draws the panel (to say what it's doing, or after doing it),
//! the boxes before are done with (BOX_DONE), and Esc only closes, as it did.

use crate::compat::Bytes;

/// BOX_RS: what splits a BOX_LOG entry
pub const BOX_RS: u8 = 0x1e;

/// BOX_LOG BOX_PLAY BOX_N BOX_AT BOX_SEL BOX_RE BOX_SIG BOX_RC BOX_ANS BOX_UP BOX_ON BOX_DONE
/// BOX_BACK
#[derive(Debug, Clone)]
pub struct Boxes {
    pub log: Vec<Bytes>,
    pub play: Vec<Bytes>,
    pub n: usize,
    pub at: i64,
    pub sel: Bytes,
    pub re: Bytes,
    pub sig: Bytes,
    pub rc: i32,
    pub ans: Bytes,
    pub up: bool,
    pub on: bool,
    pub done: bool,
    pub back: bool,
}

impl Default for Boxes {
    fn default() -> Self {
        Boxes { log: vec![], play: vec![], n: 0, at: -1, sel: vec![], re: vec![], sig: vec![], rc: 0, ans: vec![], up: false, on: false, done: false, back: false }
    }
}

/// `${l%%"$BOX_RS"*}` and `${l#*"$BOX_RS"}`
fn split_rs(l: &[u8]) -> (&[u8], &[u8]) {
    match l.iter().position(|&c| c == BOX_RS) {
        Some(i) => (&l[..i], &l[i + 1..]),
        None => (l, l), // ${l#*RS} with no RS is l whole
    }
}

/// What a panel with boxes gives them: the box state, its flash, and its draws
pub trait BoxHost {
    fn bx(&mut self) -> &mut Boxes;
    /// FLASH and FLASH_T
    fn flash_get(&self) -> (Bytes, i64);
    fn flash_put(&mut self, f: (Bytes, i64));
    /// PREV=(): the panel drawn whole the next time
    fn prev_clear(&mut self);
    /// draw: a key's own draw, its BOX_ lines first (draw_box_lines)
    fn draw(&mut self);

    /// draw()'s first two lines: a box left over the panel goes, all of it drawn again; drawn
    /// by a key's own steps, the boxes it opened before are done with (box_out).
    fn draw_box_lines(&mut self) {
        if self.bx().up {
            self.prev_clear();
            self.bx().up = false;
        }
        let b = self.bx();
        if b.on {
            b.done = true;
            b.play.clear();
            b.at = -1;
        }
    }

    /// box_flow FUNCTION ARGS...: a key's work (act KEY), run again while a box in it goes back.
    fn box_flow(&mut self, f: &mut dyn FnMut(&mut Self)) {
        let fl = self.flash_get();
        {
            let b = self.bx();
            b.play.clear();
            b.at = -1;
        }
        loop {
            {
                let b = self.bx();
                b.log.clear();
                b.n = 0;
                b.done = false;
                b.back = false;
                b.on = true;
            }
            f(self);
            if !self.bx().back {
                break;
            }
            self.flash_put(fl.clone()); // what the way out of it said, unsaid: it goes on from the box before
        }
        let b = self.bx();
        b.on = false;
        b.log.clear();
        b.play.clear();
        b.at = -1;
        if b.up {
            b.up = false;
            self.prev_clear();
        }
    }

    /// box_answered KIND ARGS...: before a box is drawn. Answered already, run again to go back
    /// past it: BOX_RC, its status, and BOX_ANS, its answer, for it to return (true). Otherwise
    /// (false) it's to be drawn, over the panel drawn clean if a box was on it; BOX_RE, what it
    /// had when it's the one gone back to.
    fn box_answered(&mut self, args: &[&[u8]]) -> bool {
        // local s="$*"; s=${s//[0-9]/}: the same box, though a clock or a count in it has moved on
        let s: Bytes = args.join(&b' ').into_iter().filter(|c| !c.is_ascii_digit()).collect();
        let b = self.bx();
        b.sig = s.into_iter().filter(|&c| c != BOX_RS).collect();
        b.re.clear();
        // Going back, and still opening boxes: they go as if escaped, unseen.
        if b.back {
            b.rc = 1;
            b.ans.clear();
            return true;
        }
        if b.n < b.play.len() {
            let l = b.play[b.n].clone();
            let (sig, r) = split_rs(&l);
            if sig == b.sig.as_slice() {
                let (rc, ans) = split_rs(r);
                b.rc = crate::render::num(rc) as i32;
                b.ans = ans.to_vec();
                let n = b.n;
                if n < b.log.len() {
                    b.log[n] = l.clone();
                } else {
                    b.log.push(l.clone());
                }
                b.n += 1;
                return true;
            }
            b.play.clear(); // not the box it was: from here on, as they come
            b.at = -1;
        }
        if b.n as i64 == b.at {
            b.re = b.sel.clone();
            b.play.clear();
            b.at = -1;
        }
        if b.up {
            self.box_clean();
        }
        false
    }

    /// box_out STATUS ANSWER [done]: a box closed, finished (0) with ANSWER, or escaped. done:
    /// what it did is done (a code typed back, a login), so nothing before it comes back.
    /// Returns STATUS.
    fn box_out(&mut self, st: i32, ans: &[u8], done: bool) -> i32 {
        let b = self.bx();
        let j = b.n as i64 - 1;
        let mut e = b.sig.clone();
        e.push(BOX_RS);
        e.extend(crate::compat::itoa(st as i64));
        e.push(BOX_RS);
        e.extend_from_slice(ans);
        let n = b.n;
        if n < b.log.len() {
            b.log[n] = e;
        } else {
            b.log.push(e);
        }
        b.n += 1;
        b.up = true;
        if done {
            b.done = true;
        }
        if st == 0 {
            return 0;
        }
        // Escaped: the box it opened from, if it was finished, comes back.
        if b.on && !b.done && j >= 0 {
            let l = b.log[j as usize].clone();
            let (_, r) = split_rs(&l);
            let (rc, sel) = split_rs(r);
            if rc == b"0" {
                b.play = b.log[..j as usize].to_vec();
                b.at = j;
                b.sel = sel.to_vec();
                b.back = true;
            }
        }
        st
    }

    /// box_clean: the panel drawn whole, with nothing over it, by the boxes themselves (draw,
    /// called by a key's own steps instead, ends what boxes went before).
    fn box_clean(&mut self) {
        // local BOX_ON=0
        let on = self.bx().on;
        self.bx().on = false;
        self.bx().up = false;
        self.prev_clear();
        self.draw();
        self.bx().on = on;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::gather::tests::bash_fn;
    use crate::compat::tests::bash;

    /// A panel with nothing but boxes: each box answers from a list, and what happens is told
    struct T {
        bx: Boxes,
        flash: (Bytes, i64),
        answers: Vec<(i32, Bytes)>,
        said: Vec<String>,
    }
    impl BoxHost for T {
        fn bx(&mut self) -> &mut Boxes {
            &mut self.bx
        }
        fn flash_get(&self) -> (Bytes, i64) {
            self.flash.clone()
        }
        fn flash_put(&mut self, f: (Bytes, i64)) {
            self.flash = f;
        }
        fn prev_clear(&mut self) {
            self.said.push("prev".into());
        }
        fn draw(&mut self) {
            self.draw_box_lines();
            self.said.push("draw".into());
        }
    }
    impl T {
        /// fake KIND ARGS...: a box that, shown, takes the next answer of the list
        fn fake(&mut self, args: &[&[u8]]) -> i32 {
            if self.box_answered(args) {
                self.said.push(format!("replay {} {}", self.bx.rc, String::from_utf8_lossy(&self.bx.ans)));
                return self.bx.rc;
            }
            self.said.push(format!("show {} re={}", String::from_utf8_lossy(&args.join(&b' ')), String::from_utf8_lossy(&self.bx.re)));
            let (st, a) = if self.answers.is_empty() { (1, vec![]) } else { self.answers.remove(0) };
            self.box_out(st, &a, false)
        }
        /// The flow: three boxes, the third with a count in it that moves on; a draw after
        /// the second when DRAW is set
        fn flow(&mut self, draw: bool) {
            self.flash = (b"said".to_vec(), 1);
            if self.fake(&[b"pick", b"A", b"one"]) != 0 {
                self.said.push("esc1".into());
                return;
            }
            if self.fake(&[b"ask", b"B"]) != 0 {
                self.said.push("esc2".into());
                return;
            }
            if draw {
                self.draw();
            }
            let n = format!("C {}", self.said.len());
            let st = self.fake(&[b"pick", n.as_bytes()]);
            self.said.push(format!("end {}", st));
        }
    }

    fn ours(answers: &[(i32, &str)], draw: bool) -> String {
        let mut t = T { bx: Boxes::default(), flash: (vec![], 0), answers: answers.iter().map(|(s, a)| (*s, a.as_bytes().to_vec())).collect(), said: vec![] };
        t.box_flow(&mut |t: &mut T| t.flow(draw));
        t.said.push(format!("flash {}", String::from_utf8_lossy(&t.flash.0)));
        t.said.join("\n") + "\n"
    }

    fn theirs(answers: &[(i32, &str)], draw: bool) -> String {
        let mut s = String::new();
        s += "BOX_RS=$'\\x1e' BOX_LOG=() BOX_PLAY=() BOX_N=0 BOX_AT=-1 BOX_SEL='' BOX_RE='' BOX_SIG='' BOX_RC=0 BOX_ANS=''\nBOX_UP=0 BOX_ON=0 BOX_DONE=0 BOX_BACK=0 FLASH='' FLASH_T=0 PREV=(x)\n";
        for f in ["box_flow", "box_answered", "box_out", "box_clean"] {
            s += &bash_fn(f);
        }
        s += "said() { SAID+=(\"$*\"); }\nSAID=()\n";
        s += "draw() { ((BOX_UP)) && PREV=() BOX_UP=0 && said prev\n((BOX_ON)) && BOX_DONE=1 BOX_PLAY=() BOX_AT=-1\nsaid draw; }\n";
        s += "ANS=(";
        for (st, a) in answers {
            s += &format!("'{} {}' ", st, a);
        }
        s += ")\nAI=0\n";
        s += "fake() { box_answered \"$@\" && { said replay \"$BOX_RC\" \"$BOX_ANS\"; return \"$BOX_RC\"; }; said show \"$*\" \"re=$BOX_RE\"; local a=${ANS[AI++]:-1 }; box_out \"${a%% *}\" \"${a#* }\"; }\n";
        s += &format!(
            "flow() {{ FLASH=said FLASH_T=1; fake pick A one || {{ said esc1; return; }}; fake ask B || {{ said esc2; return; }}; {} fake pick \"C ${{#SAID[@]}}\"; said end $?; }}\n",
            if draw { "draw;" } else { "" }
        );
        s += "box_flow flow\nsaid flash \"$FLASH\"\nprintf '%s\\n' \"${SAID[@]}\"\n";
        // PREV=() said where box_flow and box_clean clear it, as the stand-in draw says it
        let s = s.replace("PREV=() BOX_UP=0\n}", "PREV=() BOX_UP=0 && said prev\n}").replace("BOX_UP=0 PREV=()\n", "BOX_UP=0 PREV=(); said prev\n");
        String::from_utf8(bash(&s, &[])).unwrap()
    }

    #[test]
    fn going_back_replays_as_bash() {
        let cases: Vec<(Vec<(i32, &str)>, bool)> = vec![
            // all finished
            (vec![(0, "1 "), (0, "typed"), (0, "2 ")], false),
            // the first escaped: no box before it
            (vec![(1, "")], false),
            // the third escaped: back to the second, typed in again; escaped there, back to the
            // first, then all the way through
            (vec![(0, "1 "), (0, "typed"), (1, ""), (1, ""), (0, "0 "), (0, "new"), (0, "3 ")], false),
            // a draw between: the third escaped only closes
            (vec![(0, "1 "), (0, "typed"), (1, "")], true),
        ];
        for (a, d) in &cases {
            assert_eq!(ours(a, *d), theirs(a, *d), "answers {:?} draw {}", a, d);
        }
    }
}

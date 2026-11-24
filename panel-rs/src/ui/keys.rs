//! Key decoding, as scripts/panel.sh's keys() reads them: one character at a time from the
//! terminal (`read -rsn1`), an escape sequence's rest within 0.05 s a character (`read -rsn1
//! -t 0.05`), and notice_key's and the loading box's rules. A key comes out as bash's word for
//! it: up, down, pgup, pgdn, home, end, enter, a character, or "" (nothing to do).

use crate::compat::Bytes;
use std::time::Duration;

/// Where the bytes come from: the terminal (fd 0) live, a list in tests.
pub trait Src {
    /// One byte within T (`read -t T`); None: none came (or the input is closed). T zero is
    /// `read -t 0`: only a byte already waiting.
    fn byte(&mut self, t: Duration) -> Option<u8>;
}

pub const SEQ_WAIT: Duration = Duration::from_millis(50);

/// `read -rsn1` given its first byte: the rest of a UTF-8 character, as bash reads one character
/// in a UTF-8 locale. A newline (the delimiter) reads as "".
pub fn read_char(src: &mut dyn Src, first: u8) -> Bytes {
    if first == b'\n' {
        return Vec::new();
    }
    let more = match first {
        0xc2..=0xdf => 1,
        0xe0..=0xef => 2,
        0xf0..=0xf4 => 3,
        _ => 0,
    };
    let mut c = vec![first];
    for _ in 0..more {
        match src.byte(SEQ_WAIT) {
            Some(b) if b & 0xc0 == 0x80 => c.push(b),
            // not a character's continuation: bash would have read the bytes one by one too
            Some(b) => {
                c.push(b);
                break;
            }
            None => break,
        }
    }
    c
}

/// keys()'s decoding of one key from its first byte (`:5389-5404`): Enter (an empty read or
/// CR), an escape sequence by its final character, Tab as nothing, j and k as down and up.
pub fn decode(src: &mut dyn Src, first: u8) -> Bytes {
    let mut key = read_char(src, first);
    // [[ -z $key || $key == $'\r' ]] && key=enter
    if key.is_empty() || key == b"\r" {
        key = b"enter".to_vec();
    }
    if key == b"\x1b" {
        // A sequence: ESC [ or ESC O, then up to its final character (PgUp is ESC [ 5 ~).
        let mut seq: Bytes = Vec::new();
        let mut n = 0; // ${#seq}, in characters
        let rest = src.byte(SEQ_WAIT).map(|b| read_char(src, b));
        if matches!(rest.as_deref(), Some(b"[") | Some(b"O")) {
            while let Some(b) = src.byte(SEQ_WAIT) {
                let r = read_char(src, b);
                seq.extend_from_slice(&r);
                n += 1;
                // [[ $rest == [@-~] || ${#seq} -gt 8 ]] && break
                if (r.len() == 1 && (b'@'..=b'~').contains(&r[0])) || n > 8 {
                    break;
                }
            }
        }
        key = match seq.as_slice() {
            b"A" => b"up".to_vec(),
            b"B" => b"down".to_vec(),
            b"5~" => b"pgup".to_vec(),
            b"6~" => b"pgdn".to_vec(),
            b"H" | b"1~" | b"7~" => b"home".to_vec(),
            b"F" | b"4~" | b"8~" => b"end".to_vec(),
            _ => Vec::new(), // Left, Right, Shift-Tab: nothing
        };
    }
    if key == b"\t" {
        key = Vec::new(); // Tab does nothing: J and K move between windows
    }
    match key.as_slice() {
        b"j" => b"down".to_vec(),
        b"k" => b"up".to_vec(),
        _ => key,
    }
}

/// What keys() does with a key once decoded
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Class {
    /// up down pgup pgdn home end J K 0-9: act, then only drawn again (nav=1), and the next key
    /// already waiting taken with it
    Nav,
    /// p P a A: act, drawn at once from what was gathered, then looked at again
    View,
    /// "": nothing; the next key waiting is taken
    Nothing,
    /// any other: act, then looked at again
    Act,
}

pub fn class(key: &[u8]) -> Class {
    match key {
        b"up" | b"down" | b"pgup" | b"pgdn" | b"home" | b"end" | b"J" | b"K" => Class::Nav,
        [c] if c.is_ascii_digit() => Class::Nav,
        b"p" | b"P" | b"a" | b"A" => Class::View,
        b"" => Class::Nothing,
        _ => Class::Act,
    }
}

/// notice_key KEY (1.2.55): a key while a notice shows. Only a lone Esc closes it (true); an
/// Esc that starts a sequence has its rest read and dropped, every other key is ignored.
pub fn notice_key(src: &mut dyn Src, first: u8) -> bool {
    let key = read_char(src, first);
    if key != b"\x1b" {
        return false;
    }
    // IFS= read -rsn1 -t 0.05 rest
    match src.byte(SEQ_WAIT) {
        None => true,
        Some(b) => {
            read_char(src, b);
            // IFS= read -rsn4 -t 0.02 _: the rest of the sequence, 4 characters at most
            for _ in 0..4 {
                match src.byte(Duration::from_millis(20)) {
                    Some(b) => {
                        read_char(src, b);
                    }
                    None => break,
                }
            }
            false
        }
    }
}

/// keys() while the loading box is up: q or Q quits (true); the key and all waiting behind it
/// are dropped.
pub fn lbox_key(src: &mut dyn Src, first: u8) -> bool {
    let key = read_char(src, first);
    if key == b"q" || key == b"Q" {
        return true;
    }
    // while read -t 0 && IFS= read -rsn1 _; do :; done
    while src.byte(Duration::ZERO).is_some() {}
    false
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// Bytes as they arrive: a None in the list is a gap longer than any wait
    pub struct List(pub VecDeque<Option<u8>>);
    impl List {
        pub fn new(parts: &[&[u8]]) -> List {
            let mut q = VecDeque::new();
            for (i, p) in parts.iter().enumerate() {
                if i > 0 {
                    q.push_back(None);
                }
                q.extend(p.iter().map(|&b| Some(b)));
            }
            List(q)
        }
    }
    impl Src for List {
        fn byte(&mut self, _t: Duration) -> Option<u8> {
            match self.0.front() {
                Some(None) => {
                    if !_t.is_zero() {
                        self.0.pop_front(); // the gap passes only for a read that waits
                    }
                    None
                }
                Some(Some(b)) => {
                    let b = *b;
                    self.0.pop_front();
                    Some(b)
                }
                None => None,
            }
        }
    }

    /// Every key in one burst, as keys() takes those waiting: each decoded in turn
    fn all(parts: &[&[u8]]) -> Vec<String> {
        let mut s = List::new(parts);
        let mut v = Vec::new();
        while let Some(b) = s.byte(Duration::from_secs(1)) {
            v.push(String::from_utf8_lossy(&decode(&mut s, b)).into_owned());
        }
        v
    }

    #[test]
    fn keys_decode_as_bash_reads_them() {
        assert_eq!(all(&[b"\x1b[A\x1b[B"]), ["up", "down"]);
        assert_eq!(all(&[b"\x1bOA\x1bOB"]), ["up", "down"]);
        assert_eq!(all(&[b"\x1b[5~\x1b[6~"]), ["pgup", "pgdn"]);
        assert_eq!(all(&[b"\x1b[H\x1b[1~\x1b[7~\x1b[F\x1b[4~\x1b[8~"]), ["home", "home", "home", "end", "end", "end"]);
        assert_eq!(all(&[b"\x1b[C\x1b[D\x1b[Z"]), ["", "", ""]); // Right, Left, Shift-Tab
        assert_eq!(all(&[b"\n\r"]), ["enter", "enter"]);
        assert_eq!(all(&[b"jkJK\t"]), ["down", "up", "J", "K", ""]);
        assert_eq!(all(&[b"a7?"]), ["a", "7", "?"]);
        assert_eq!(all(&["é".as_bytes()]), ["é"]);
        // A lone Esc (nothing within 0.05 s) is nothing; Alt-x (ESC x) drops the x with it.
        assert_eq!(all(&[b"\x1b", b"a"]), ["", "a"]);
        assert_eq!(all(&[b"\x1bxa"]), ["", "a"]);
        // A sequence cut short by a pause is nothing, and what follows is a key of its own.
        assert_eq!(all(&[b"\x1b[", b"a"]), ["", "a"]);
        // A sequence's rest stops at 9 characters with no final one.
        assert_eq!(all(&[b"\x1b[123456789x"]), ["", "x"]);
        // F5 (ESC [ 1 5 ~) is nothing.
        assert_eq!(all(&[b"\x1b[15~q"]), ["", "q"]);
    }

    #[test]
    fn classes_as_keys_sorts_them() {
        for k in ["up", "down", "pgup", "pgdn", "home", "end", "J", "K", "0", "9"] {
            assert_eq!(class(k.as_bytes()), Class::Nav, "{}", k);
        }
        for k in ["p", "P", "a", "A"] {
            assert_eq!(class(k.as_bytes()), Class::View, "{}", k);
        }
        assert_eq!(class(b""), Class::Nothing);
        for k in ["enter", "f", "F", "q", "N", "?", "x", "é"] {
            assert_eq!(class(k.as_bytes()), Class::Act, "{}", k);
        }
    }

    #[test]
    fn a_notice_closes_on_a_lone_esc_only() {
        let mut s = List::new(&[b"\x1b"]);
        let b = s.byte(Duration::ZERO).unwrap();
        assert!(notice_key(&mut s, b));
        // An arrow is read whole and ignored: nothing of it is left to be a key.
        let mut s = List::new(&[b"\x1b[A", b"x"]);
        let b = s.byte(Duration::ZERO).unwrap();
        assert!(!notice_key(&mut s, b));
        assert_eq!(s.byte(Duration::from_secs(1)), Some(b'x'));
        let mut s = List::new(&[b"q"]);
        let b = s.byte(Duration::ZERO).unwrap();
        assert!(!notice_key(&mut s, b));
    }

    #[test]
    fn the_loading_box_takes_q_only() {
        let mut s = List::new(&[b"q"]);
        let b = s.byte(Duration::ZERO).unwrap();
        assert!(lbox_key(&mut s, b));
        let mut s = List::new(&[b"abc"]);
        let b = s.byte(Duration::ZERO).unwrap();
        assert!(!lbox_key(&mut s, b));
        assert_eq!(s.byte(Duration::ZERO), None, "the keys behind it are dropped");
    }
}

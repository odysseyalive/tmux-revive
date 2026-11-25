//! Bash's semantics, made explicit (plan Step 1.2). The panel's text is bytes from end to end:
//! panes, files and other computers need not send valid UTF-8, and bash counts what it can't
//! decode a byte at a time. Every helper here is checked against the bash it stands for, in
//! the tests at the bottom (bash one-liners over the same inputs), and through whole frames by
//! test/panel-golden.sh's render stage.

use std::ffi::CString;
use std::sync::Once;

/// A bash string: any bytes but NUL.
pub type Bytes = Vec<u8>;

// Not in the libc crate for every target: declared here, still libc's own functions.
#[repr(C, align(8))]
struct MbState([u8; 128]); // glibc's mbstate_t is 8 bytes, macOS's 128: room for either

// regex_t, with re_nsub where the libc crate keeps it private: BASH_REMATCH has re_nsub + 1
// entries, groups that took no part included.
#[cfg(target_os = "linux")]
#[repr(C)]
struct RegexT {
    buffer: *mut libc::c_void,
    allocated: libc::size_t,
    used: libc::size_t,
    syntax: libc::c_ulong,
    fastmap: *mut libc::c_char,
    translate: *mut libc::c_char,
    re_nsub: libc::size_t,
    bits: u8,
}
#[cfg(target_os = "macos")]
#[repr(C)]
struct RegexT {
    magic: libc::c_int,
    re_nsub: libc::size_t,
    endp: *const libc::c_char,
    g: *mut libc::c_void,
}

extern "C" {
    fn mbrtowc(pwc: *mut libc::wchar_t, s: *const libc::c_char, n: libc::size_t, ps: *mut MbState) -> libc::size_t;
    fn iswcntrl(wc: libc::c_uint) -> libc::c_int;
    fn iswprint(wc: libc::c_uint) -> libc::c_int;
    fn iswspace(wc: libc::c_uint) -> libc::c_int;
    fn towupper(wc: libc::c_uint) -> libc::c_uint;
    fn towlower(wc: libc::c_uint) -> libc::c_uint;
    fn wcrtomb(s: *mut libc::c_char, wc: libc::wchar_t, ps: *mut MbState) -> libc::size_t;
    fn tzset();
    fn regcomp(re: *mut RegexT, pat: *const libc::c_char, flags: libc::c_int) -> libc::c_int;
    fn regexec(re: *const RegexT, s: *const libc::c_char, n: libc::size_t, m: *mut libc::regmatch_t, flags: libc::c_int) -> libc::c_int;
    fn regfree(re: *mut RegexT);
}

/// The character mbrtowc decodes at the start of S, and its length in bytes; None for a byte
/// that doesn't decode (or an empty S, or a NUL).
pub fn mb_decode(s: &[u8]) -> Option<(libc::wchar_t, usize)> {
    if s.is_empty() {
        return None;
    }
    let mut wc: libc::wchar_t = 0;
    let mut st = MbState([0; 128]);
    let n = unsafe { mbrtowc(&mut wc, s.as_ptr() as *const libc::c_char, s.len(), &mut st) };
    if n == 0 || n >= usize::MAX - 1 {
        None
    } else {
        Some((wc, n))
    }
}
/// iswprint, under the panel's locale
pub fn wprint(wc: libc::wchar_t) -> bool {
    unsafe { iswprint(wc as libc::c_uint) != 0 }
}

// ------------------------------------------------------------------ the locale

static LOCALE: Once = Once::new();

/// The panel's locale, as panel.sh sets it (`:44-49` at 475f43a): the environment's, unless its
/// charmap isn't UTF-8; then the first of C.UTF-8 and en_US.UTF-8 that is, exported as LC_ALL
/// so the programs it runs count the same way. Once per process; the first call decides.
pub fn init_locale() {
    START.get_or_init(|| std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0));
    LOCALE.call_once(|| unsafe {
        libc::setlocale(libc::LC_ALL, c"".as_ptr());
        if codeset_utf8() {
            return;
        }
        for l in [c"C.UTF-8", c"en_US.UTF-8"] {
            if !libc::setlocale(libc::LC_ALL, l.as_ptr()).is_null() && codeset_utf8() {
                std::env::set_var("LC_ALL", l.to_str().unwrap());
                return;
            }
        }
        libc::setlocale(libc::LC_ALL, c"".as_ptr());
    });
}

/// Tests: the locale fixed to C.UTF-8 (the frames' locale in test/panel-golden.sh), whatever the
/// environment says. A test that needs another locale runs the binary or bash with it instead:
/// the locale is the whole process's, and cargo runs tests as threads.
pub fn init_locale_named(name: &str) {
    LOCALE.call_once(|| unsafe {
        let n = CString::new(name).unwrap();
        libc::setlocale(libc::LC_ALL, n.as_ptr());
    });
}

fn codeset_utf8() -> bool {
    unsafe {
        let p = libc::nl_langinfo(libc::CODESET);
        !p.is_null() && std::ffi::CStr::from_ptr(p).to_bytes() == b"UTF-8"
    }
}

// ------------------------------------------------------------------ characters

/// The bytes of the character that starts `s`, as bash counts characters (`${#s}`, `${s:i:n}`):
/// what libc's mbrtowc decodes is one character; a byte it can't (an invalid or cut-short
/// sequence) is one character on its own. glibc decodes the old 5- and 6-byte forms and code
/// points past U+10FFFF as one character, and so does bash; it refuses overlong forms and
/// surrogates, and bash counts those per byte. 0 only for an empty `s`.
pub fn char_len(s: &[u8]) -> usize {
    match s.first() {
        None => 0,
        Some(&b) if b < 0x80 => 1,
        Some(_) => {
            let (n, _) = decode(s);
            n
        }
    }
}

/// decode S -> (bytes, Some(wide char)) for the character that starts S, or (1, None) for a
/// byte that doesn't decode.
fn decode(s: &[u8]) -> (usize, Option<u32>) {
    let mut st = MbState([0; 128]);
    let mut wc: libc::wchar_t = 0;
    let r = unsafe { mbrtowc(&mut wc, s.as_ptr() as *const libc::c_char, s.len(), &mut st) };
    if r == usize::MAX || r == usize::MAX - 1 {
        (1, None)
    } else if r == 0 {
        (1, Some(0))
    } else {
        (r, Some(wc as u32))
    }
}

/// Whether `s`, all of it, is the start of a character cut short (mbrtowc gives -2).
fn incomplete(s: &[u8]) -> bool {
    let mut st = MbState([0; 128]);
    let mut wc: libc::wchar_t = 0;
    unsafe { mbrtowc(&mut wc, s.as_ptr() as *const libc::c_char, s.len(), &mut st) == usize::MAX - 1 }
}

/// Characters of `s`, as bash splits them.
pub fn chars(s: &[u8]) -> Chars<'_> {
    Chars { s }
}
pub struct Chars<'a> {
    s: &'a [u8],
}
impl<'a> Iterator for Chars<'a> {
    type Item = &'a [u8];
    fn next(&mut self) -> Option<&'a [u8]> {
        let n = char_len(self.s);
        if n == 0 {
            return None;
        }
        let (c, rest) = self.s.split_at(n);
        self.s = rest;
        Some(c)
    }
}

/// `${#s}`: its length in characters.
pub fn blen(s: &[u8]) -> i64 {
    if s.is_ascii() {
        return s.len() as i64;
    }
    chars(s).count() as i64
}

/// Whether bash would decode all of `s` (no invalid or cut-short sequence in it).
fn all_valid(s: &[u8]) -> bool {
    let mut r = s;
    while let Some(&b) = r.first() {
        if b < 0x80 {
            r = &r[1..];
            continue;
        }
        match decode(r) {
            (_, None) => return false,
            (n, Some(_)) => r = &r[n..],
        }
    }
    true
}

/// `${s:off:len}` (len None: `${s:off}`), in characters. A negative offset counts from the end
/// (nothing when it's before the start); a negative length stops that many short of the end.
/// None: bash's "substring expression < 0" error.
pub fn substr(s: &[u8], off: i64, len: Option<i64>) -> Option<Bytes> {
    let cs: Vec<&[u8]> = chars(s).collect();
    let n = cs.len() as i64;
    let mut a = off;
    if a < 0 {
        a += n;
        if a < 0 {
            return Some(Vec::new());
        }
    }
    if a > n {
        return Some(Vec::new());
    }
    let e = match len {
        None => n,
        Some(l) if l < 0 => {
            let e = n + l;
            if e < a {
                return None;
            }
            e
        }
        Some(l) => (a.saturating_add(l)).min(n),
    };
    Some(cs[a as usize..e as usize].concat())
}

/// `printf '%*s' N ''`: N spaces, and as many for a negative N (left-justified, the same width).
pub fn pad(n: i64) -> Bytes {
    vec![b' '; n.unsigned_abs() as usize]
}

// ------------------------------------------------------------------ ${v//[SET]/}

/// The bracket expressions `clean` removes, one character at a time.
#[derive(Clone, Copy)]
pub enum Set<'a> {
    /// `[[:cntrl:]]`
    Cntrl,
    /// `[CHARS]`, CHARS the bracket's contents as written (valid UTF-8, nothing special in it)
    Of(&'a [u8]),
    /// `[[:space:]CHARS]`: isspace or one of CHARS byte by byte, iswspace or one of CHARS by
    /// character (blank_tail's `[[:space:]]`, peek_wrap's `[[:space:]│]`)
    SpaceOr(&'a [u8]),
}

/// `${s//[SET]/}`, as bash does it. Bash looks for the next match in what is left after the last
/// one, and how it looks depends on that remainder: one that is all valid (and the pattern or the
/// remainder has a multibyte character) is matched character by character, with iswcntrl for
/// [:cntrl:]; one holding any byte that doesn't decode is matched byte by byte, the bracket a set
/// of bytes and [:cntrl:] iscntrl. So `\xffé…` loses the a9 of é to the zero-width set, and then
/// keeps … whole, its remainder being valid again. Not fixed here: it is what bash prints.
pub fn remove_all(s: &[u8], set: Set) -> Bytes {
    let mut out = Vec::with_capacity(s.len());
    let mut rest = s;
    let set_mb = match set {
        Set::Cntrl => false,
        Set::Of(b) | Set::SpaceOr(b) => !b.is_ascii(),
    };
    let set_chars: Vec<u32> = match set {
        Set::Of(b) | Set::SpaceOr(b) => chars(b).map(|c| decode(c).1.unwrap_or(c[0] as u32)).collect(),
        Set::Cntrl => Vec::new(),
    };
    loop {
        let found = if (rest.is_ascii() && !set_mb) || !all_valid(rest) {
            // byte by byte
            rest.iter().position(|&b| match set {
                Set::Cntrl => unsafe { libc::iscntrl(b as libc::c_int) != 0 },
                Set::Of(bs) => bs.contains(&b),
                Set::SpaceOr(bs) => (unsafe { libc::isspace(b as libc::c_int) != 0 }) || bs.contains(&b),
            })
            .map(|i| (i, i + 1))
        } else {
            let mut i = 0;
            let mut hit = None;
            while i < rest.len() {
                let (n, wc) = decode(&rest[i..]);
                let wc = wc.unwrap_or(0);
                let m = match set {
                    Set::Cntrl => unsafe { iswcntrl(wc as libc::c_uint) != 0 },
                    Set::Of(_) => set_chars.contains(&wc),
                    Set::SpaceOr(_) => (unsafe { iswspace(wc as libc::c_uint) != 0 }) || set_chars.contains(&wc),
                };
                if m {
                    hit = Some((i, i + n));
                    break;
                }
                i += n;
            }
            hit
        };
        match found {
            None => {
                out.extend_from_slice(rest);
                return out;
            }
            Some((a, e)) => {
                out.extend_from_slice(&rest[..a]);
                rest = &rest[e..];
            }
        }
    }
}

/// `[[ $c == [[:space:]] ]]` for one character as bash matches it: iswspace when it decodes,
/// isspace on the byte when it doesn't.
pub fn is_space(c: &[u8]) -> bool {
    match c {
        [] => false,
        [b] if *b < 0x80 => unsafe { libc::isspace(*b as libc::c_int) != 0 },
        _ => match decode(c) {
            (_, Some(wc)) => unsafe { iswspace(wc as libc::c_uint) != 0 },
            (_, None) => unsafe { libc::isspace(c[0] as libc::c_int) != 0 },
        },
    }
}

/// `[[ $c == [[:cntrl:]] ]]` for one character: iswcntrl when it decodes, iscntrl on the byte
/// when it doesn't.
pub fn is_cntrl(c: &[u8]) -> bool {
    match c {
        [] => false,
        [b] if *b < 0x80 => unsafe { libc::iscntrl(*b as libc::c_int) != 0 },
        _ => match decode(c) {
            (_, Some(wc)) => unsafe { iswcntrl(wc as libc::c_uint) != 0 },
            (_, None) => unsafe { libc::iscntrl(c[0] as libc::c_int) != 0 },
        },
    }
}

/// C1: the C1 controls U+0080-U+009F, as panel.sh builds it (UTF-8 bytes).
pub fn c1_set() -> Bytes {
    let mut v = Vec::new();
    for i in 128u8..=159 {
        v.extend_from_slice(&[0xc2, i]);
    }
    v
}
/// ZW: the bidi and zero-width characters U+200B-200F, U+202A-202E, U+2066-2069.
pub fn zw_set() -> Bytes {
    let mut v = Vec::new();
    for c in [0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0xaa, 0xab, 0xac, 0xad, 0xae] {
        v.extend_from_slice(&[0xe2, 0x80, c]);
    }
    for c in [0xa6, 0xa7, 0xa8, 0xa9] {
        v.extend_from_slice(&[0xe2, 0x81, c]);
    }
    v
}

/// clean (scripts/panel.sh `clean`): `_v=${_v//[[:cntrl:]]/} _v=${_v//[$C1]/} _v=${_v//[$ZW]/}`.
pub fn clean(s: &[u8]) -> Bytes {
    let a = remove_all(s, Set::Cntrl);
    let b = remove_all(&a, Set::Of(&c1_set()));
    remove_all(&b, Set::Of(&zw_set()))
}

/// `${s^^}` (upper) or `${s,,}`: each character bash decodes through towupper or towlower and
/// back through wcrtomb; a byte that doesn't decode is kept as it is (bash's sh_modcase).
pub fn case_map(s: &[u8], upper: bool) -> Bytes {
    let mut out = Vec::with_capacity(s.len());
    let mut r = s;
    while !r.is_empty() {
        if r[0] < 0x80 {
            out.push(if upper { r[0].to_ascii_uppercase() } else { r[0].to_ascii_lowercase() });
            r = &r[1..];
            continue;
        }
        // A sequence cut short by the end of the string (mbrtowc's -2) one byte before its end:
        // bash 5.3 writes its k >= 2 bytes as s[0], s[0..k], s[1..k] (e2 82 -> e2 e2 82 82,
        // f0 9f 98 -> f0 f0 9f 98 9f 98); shorter ones (f0 90, a lone c3) as they are. Found
        // by trying bytes on bash, not from its source. Not fixed: it is what bash prints.
        if incomplete(r) {
            let want = match r[0] {
                0xc0..=0xdf => 2,
                0xe0..=0xef => 3,
                0xf0..=0xf7 => 4,
                0xf8..=0xfb => 5,
                _ => 6,
            };
            // an overlong (e0 80, f0 80) or surrogate (ed a0) start is left alone; f4 90 80 isn't
            let odd = r.len() >= 2 && ((r[0] == 0xe0 && r[1] < 0xa0) || (r[0] == 0xed && r[1] >= 0xa0) || (r[0] == 0xf0 && r[1] < 0x90));
            if r.len() >= 2 && r.len() + 1 == want && !odd {
                out.push(r[0]);
                out.extend_from_slice(r);
                out.extend_from_slice(&r[1..]);
            } else {
                out.extend_from_slice(r);
            }
            break;
        }
        let (n, wc) = decode(r);
        match wc {
            None => out.extend_from_slice(&r[..n]),
            Some(wc) => {
                let m = unsafe { if upper { towupper(wc) } else { towlower(wc) } };
                let mut buf = [0u8; 16];
                let mut st = MbState([0; 128]);
                let k = unsafe { wcrtomb(buf.as_mut_ptr() as *mut libc::c_char, m as libc::wchar_t, &mut st) };
                if k == usize::MAX {
                    out.extend_from_slice(&r[..n]);
                } else {
                    out.extend_from_slice(&buf[..k]);
                }
            }
        }
        r = &r[n..];
    }
    out
}

/// `${s/#PAT/REP}` with PAT a glob (unquoted, as `${P_DIR[i]/#$HOME/\~}` has it): the longest
/// prefix PAT matches, replaced. A PAT with nothing special in it is a plain prefix; one with
/// `*?[\` goes through libc's fnmatch over each prefix, longest first. An empty PAT matches the
/// empty prefix, so REP goes in front.
pub fn sub_prefix(s: &[u8], pat: &[u8], rep: &[u8]) -> Bytes {
    if !pat.iter().any(|c| b"*?[\\".contains(c)) {
        if s.starts_with(pat) {
            return [rep, &s[pat.len()..]].concat();
        }
        return s.to_vec();
    }
    let Ok(p) = CString::new(pat) else { return s.to_vec() };
    let mut ends: Vec<usize> = vec![0];
    let mut i = 0;
    for c in chars(s) {
        i += c.len();
        ends.push(i);
    }
    for &e in ends.iter().rev() {
        let Ok(t) = CString::new(&s[..e]) else { continue };
        if unsafe { libc::fnmatch(p.as_ptr(), t.as_ptr(), 0) } == 0 {
            return [rep, &s[e..]].concat();
        }
    }
    s.to_vec()
}

/// `IFS=C read -ra A <<<"$s"`, C one byte that isn't white space: the fields between each C,
/// an empty one kept, except one left empty at the very end (bash's read drops it).
pub fn read_split(s: &[u8], c: u8) -> Vec<Bytes> {
    let mut v: Vec<Bytes> = s.split(|&b| b == c).map(|f| f.to_vec()).collect();
    if v.last().is_some_and(|f| f.is_empty()) {
        v.pop();
    }
    v
}

/// The ERE PAT compiled once and kept (each `=~` the frame runs, compiled as bash compiles it).
pub fn re(pat: &str) -> &'static Ere {
    use std::collections::HashMap;
    use std::sync::Mutex;
    static CACHE: std::sync::OnceLock<Mutex<HashMap<String, &'static Ere>>> = std::sync::OnceLock::new();
    let m = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut g = m.lock().unwrap();
    if let Some(e) = g.get(pat) {
        return e;
    }
    let e: &'static Ere = Box::leak(Box::new(Ere::new(pat.as_bytes(), false).unwrap_or_else(|| panic!("regcomp {}", pat))));
    g.insert(pat.to_string(), e);
    e
}

// ------------------------------------------------------------------ arithmetic

/// A shell variable's value read in `$(( ))`: a decimal number, octal with a leading 0, hex with
/// 0x, or base#digits; empty is 0. Signed 64-bit, wrapping as bash does. Anything else bash would
/// read as a variable name or fail on: None (the panel never gives it one).
pub fn arith_int(s: &[u8]) -> Option<i64> {
    let t = s.trim_ascii();
    if t.is_empty() {
        return Some(0);
    }
    let (neg, t) = match t[0] {
        b'-' => (true, &t[1..]),
        b'+' => (false, &t[1..]),
        _ => (false, t),
    };
    if t.is_empty() {
        return None;
    }
    let (base, digits): (u32, &[u8]) = if let Some(p) = t.iter().position(|&c| c == b'#') {
        let b: u32 = std::str::from_utf8(&t[..p]).ok()?.parse().ok()?;
        if !(2..=64).contains(&b) {
            return None;
        }
        (b, &t[p + 1..])
    } else if t.len() > 1 && t[0] == b'0' && (t[1] == b'x' || t[1] == b'X') {
        (16, &t[2..])
    } else if t.len() > 1 && t[0] == b'0' {
        (8, &t[1..])
    } else {
        (10, t)
    };
    let mut v: i64 = 0;
    for &c in digits {
        let d = match c {
            b'0'..=b'9' => (c - b'0') as u32,
            b'a'..=b'z' => (c - b'a') as u32 + 10,
            b'A'..=b'Z' if base <= 36 => (c - b'A') as u32 + 10,
            b'A'..=b'Z' => (c - b'A') as u32 + 36,
            b'@' => 62,
            b'_' => 63,
            _ => return None,
        };
        if d >= base {
            return None;
        }
        v = v.wrapping_mul(base as i64).wrapping_add(d as i64);
    }
    Some(if neg { v.wrapping_neg() } else { v })
}

/// The decimal digits of N, as `$N` prints it.
pub fn itoa(n: i64) -> Bytes {
    n.to_string().into_bytes()
}

// ------------------------------------------------------------------ time

static TZ: Once = Once::new();
static START: std::sync::OnceLock<i64> = std::sync::OnceLock::new();

/// TZ is the whole process's: the live panel's threads each format times (the clock on the UI
/// thread, limits and messages on the collectors'), and bash's `TZ=ZONE printf '%(...)T'` is a
/// change of it for a moment. ZONE_LOCK makes that moment and every strftime take turns.
static ZONE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
thread_local! {
    /// This thread holds ZONE_LOCK (inside in_zone): its strftime calls don't take it again.
    static IN_ZONE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// `TZ=ZONE CMD` for what F formats: TZ set to ZONE, F run, TZ put back, no other thread's
/// strftime between
pub fn in_zone<R>(zone: &[u8], f: impl FnOnce() -> R) -> R {
    let _g = ZONE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let old = std::env::var_os("TZ");
    std::env::set_var("TZ", <std::ffi::OsStr as std::os::unix::ffi::OsStrExt>::from_bytes(zone));
    unsafe { tzset() };
    IN_ZONE.with(|z| z.set(true));
    let r = f();
    IN_ZONE.with(|z| z.set(false));
    match old {
        Some(v) => std::env::set_var("TZ", v),
        None => std::env::remove_var("TZ"),
    }
    unsafe { tzset() };
    r
}

/// `printf '%(FMT)T' EPOCH`: libc's localtime_r and strftime, with TZ and LC_TIME as bash has them.
/// An empty FMT is %X. As in bash, -1 is now (and -2 the shell's start, here the process's); the panel always passes
/// a time of its own (NOW).
pub fn strftime(fmt: &[u8], epoch: i64) -> Bytes {
    let _g = if IN_ZONE.with(|z| z.get()) { None } else { Some(ZONE_LOCK.lock().unwrap_or_else(|e| e.into_inner())) };
    TZ.call_once(|| unsafe { tzset() });
    let now = || std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let epoch = match epoch {
        -1 => now(),
        -2 => *START.get_or_init(now),
        e => e,
    };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let t = epoch as libc::time_t;
    if unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
        return Vec::new();
    }
    // An empty format is bash's "%X".
    let fmt: &[u8] = if fmt.is_empty() { b"%X" } else { fmt };
    let f = match CString::new(fmt) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    // bash grows its buffer until the result fits (an empty result is empty).
    let mut cap = 128usize;
    loop {
        let mut buf = vec![0u8; cap];
        let n = unsafe { libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, cap, f.as_ptr(), &tm) };
        if n > 0 || cap >= 1 << 16 {
            buf.truncate(n);
            return buf;
        }
        cap *= 4;
    }
}

// ------------------------------------------------------------------ collation and globs

/// libc's strcoll, under the panel's locale.
pub fn strcoll(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    let (a, b) = (CString::new(a).unwrap_or_default(), CString::new(b).unwrap_or_default());
    unsafe { libc::strcoll(a.as_ptr(), b.as_ptr()) }.cmp(&0)
}

/// `"DIR"/*/`: the folders in DIR (and links to folders), names not starting with a dot, each as
/// `DIR/NAME/`, in bash's glob order: by strcoll of the whole path (`man bash`, GLOBSORT unset).
/// No match: the pattern itself, as bash leaves it (no nullglob).
pub fn glob_dirs(dir: &[u8]) -> Vec<Bytes> {
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    let mut v: Vec<Bytes> = Vec::new();
    let path = std::ffi::OsStr::from_bytes(dir);
    if let Ok(rd) = std::fs::read_dir(path) {
        for e in rd.flatten() {
            let name = e.file_name().into_vec();
            if name.first() == Some(&b'.') {
                continue;
            }
            let mut p = dir.to_vec();
            if !p.ends_with(b"/") {
                p.push(b'/');
            }
            p.extend_from_slice(&name);
            if std::fs::metadata(std::ffi::OsStr::from_bytes(&p)).map(|m| m.is_dir()).unwrap_or(false) {
                p.push(b'/');
                v.push(p);
            }
        }
    }
    if v.is_empty() {
        let mut p = dir.to_vec();
        p.extend_from_slice(b"/*/");
        return vec![p];
    }
    v.sort_by(|a, b| strcoll(a, b));
    v
}

// ------------------------------------------------------------------ [[ =~ ]]

/// A POSIX extended regular expression, compiled by libc's regcomp as bash's `=~` does (`man
/// bash`: "using the POSIX regcomp and regexec interfaces"), with REG_ICASE where bash has
/// `shopt -s nocasematch`. Never the regex crate: its syntax and bracket classes differ.
pub struct Ere {
    re: RegexT,
}
unsafe impl Send for Ere {}
unsafe impl Sync for Ere {}

impl Ere {
    pub fn new(pat: &[u8], icase: bool) -> Option<Ere> {
        let p = CString::new(pat).ok()?;
        let mut re: RegexT = unsafe { std::mem::zeroed() };
        let flags = libc::REG_EXTENDED | if icase { libc::REG_ICASE } else { 0 };
        if unsafe { regcomp(&mut re, p.as_ptr(), flags) } != 0 {
            return None;
        }
        Some(Ere { re })
    }
    /// `[[ S =~ RE ]]` -> BASH_REMATCH (a group that took no part: empty), or None for no match.
    pub fn matches(&self, s: &[u8]) -> Option<Vec<Bytes>> {
        let c = CString::new(s).ok()?;
        let n = self.re.re_nsub + 1;
        let mut m: Vec<libc::regmatch_t> = vec![libc::regmatch_t { rm_so: -1, rm_eo: -1 }; n];
        if unsafe { regexec(&self.re, c.as_ptr(), n, m.as_mut_ptr(), 0) } != 0 {
            return None;
        }
        Some(
            m.iter()
                .map(|r| if r.rm_so < 0 { Vec::new() } else { s[r.rm_so as usize..r.rm_eo as usize].to_vec() })
                .collect(),
        )
    }
    pub fn is_match(&self, s: &[u8]) -> bool {
        self.matches(s).is_some()
    }
}
impl Drop for Ere {
    fn drop(&mut self) {
        unsafe { regfree(&mut self.re) }
    }
}

// ------------------------------------------------------------------ tests against bash

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;
    use std::process::Command;

    /// bash -c SCRIPT _ ARGS..., under C.UTF-8 and UTC: what it prints.
    pub fn bash(script: &str, args: &[&[u8]]) -> Bytes {
        let mut c = Command::new("bash");
        c.arg("-c").arg(script).arg("_");
        for a in args {
            c.arg(std::ffi::OsStr::from_bytes(a));
        }
        c.env("LC_ALL", "C.UTF-8").env("TZ", "UTC");
        let o = c.output().expect("bash runs");
        assert!(o.status.success(), "bash failed: {}", String::from_utf8_lossy(&o.stderr));
        o.stdout
    }
    static SETUP: Once = Once::new();
    /// The test process's locale and zone, once: C.UTF-8 and UTC, as the bash it is compared with.
    pub fn setup() {
        SETUP.call_once(|| std::env::set_var("TZ", "UTC"));
        init_locale_named("C.UTF-8");
    }
    /// What each test feeds bash and Rust alike: CJK, combining marks, C0 and C1 controls, bidi
    /// and zero-width characters, a long line, and bytes that aren't UTF-8 (a lone \xff, a cut-
    /// short sequence, an overlong form, a surrogate, past U+10FFFF, a 5-byte form).
    pub fn inputs() -> Vec<Bytes> {
        let mut v: Vec<Bytes> = [
            &b""[..], b"plain", "漢字テスト".as_bytes(), "e\u{301}a\u{308}".as_bytes(), b"a\x01b\x7fc\td",
            b"a\xc2\x85b\xc2\x9fc", "a\u{202e}b\u{200b}c\u{2066}d\u{2028}e".as_bytes(), b"x\xffy", b"\xe2\x82z",
            b"\xe2\x82", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xf8\x88\x80\x80\x80",
            b"\xfc\x84\x80\x80\x80\x80", b"\xfe\xff", b"\xff\xc3\xa9\xe2\x80\xa6", b"\xc3\xa9\xe2\x80\xa6\xc2",
            b"\xe2\x80\xc3\xa9\xe2\x80\xa6", b"\x85\xc3\xa9", b"\x1b[1;32mok\x1b[0m \xe2\x95\x90", "─━═│😀".as_bytes(),
        ]
        .iter()
        .map(|s| s.to_vec())
        .collect();
        v.push("long ±".repeat(200).into_bytes());
        // A pseudo-random mix, the same every run, weighted to bytes that start sequences.
        let mut seed: u64 = 7919;
        for _ in 0..60 {
            let mut s = Vec::new();
            for _ in 0..(seed % 13) {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let r = (seed >> 33) as u8;
                s.push(match r % 6 {
                    0 => b'a' + r % 26,
                    1 => 0x80 | (r & 0x3f),
                    2 => 0xc2 + r % 30,
                    3 => 0xe0 + r % 16,
                    4 => 0xf0 + r % 16,
                    _ => [0x1b, b'[', b'm', b'1', b';', 0x7f, 0x01][(r % 7) as usize],
                });
            }
            seed = seed.wrapping_add(1);
            v.push(s);
        }
        v
    }
    fn nul_split(b: &[u8]) -> Vec<Bytes> {
        let mut v: Vec<Bytes> = b.split(|&c| c == 0).map(|s| s.to_vec()).collect();
        v.pop();
        v
    }

    #[test]
    fn length_counts_as_bash() {
        setup();
        let ins = inputs();
        let args: Vec<&[u8]> = ins.iter().map(|v| v.as_slice()).collect();
        let out = nul_split(&bash(r#"for s; do printf '%s\0' "${#s}"; done"#, &args));
        for (s, b) in ins.iter().zip(out) {
            assert_eq!(itoa(blen(s)), b, "${{#s}} of {:?}", s);
        }
    }

    #[test]
    fn substrings_as_bash() {
        setup();
        let ins = inputs();
        let args: Vec<&[u8]> = ins.iter().map(|v| v.as_slice()).collect();
        let out = nul_split(&bash(
            r#"for s; do printf '%s\0' "${s:0:1}" "${s:1}" "${s:2:3}" "${s:0:0}" "${s: -2}"; (printf '%s\0' "${s:1:-1}") 2>/dev/null || printf 'ERR\0'; printf '%s\0' "${s:40:2}"; done"#,
            &args,
        ));
        let mut o = out.into_iter();
        for s in &ins {
            for (off, len) in [(0, Some(1)), (1, None), (2, Some(3)), (0, Some(0)), (-2, None), (1, Some(-1)), (40, Some(2))] {
                let b = o.next().unwrap();
                // A negative length that ends before the start is an error in bash.
                assert_eq!(substr(s, off, len).unwrap_or(b"ERR".to_vec()), b, "${{s:{}:{:?}}} of {:?}", off, len, s);
            }
        }
    }

    #[test]
    fn printf_pads_as_bash() {
        setup();
        let out = bash(r#"for n in 0 1 5 -3 -1; do printf '[%*s]' "$n" ''; printf '[%s%*s]' ab "$n" ''; done"#, &[]);
        let mut r = Vec::new();
        for n in [0, 1, 5, -3, -1] {
            r.extend(b"[");
            r.extend(pad(n));
            r.extend(b"][ab");
            r.extend(pad(n));
            r.extend(b"]");
        }
        assert_eq!(String::from_utf8_lossy(&r), String::from_utf8_lossy(&out));
    }

    #[test]
    fn clean_as_bash() {
        setup();
        // The panel's own clean, from scripts/panel.sh: its C1 and ZW lines and the function.
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        let pick: Vec<&str> = src
            .lines()
            .filter(|l| l.starts_with("C1=\"\" ZW=\"\"") || l.starts_with("for i in {128..159}") || l.starts_with("for c in 80{8b"))
            .collect();
        assert_eq!(pick.len(), 3, "panel.sh's C1/ZW lines moved");
        let f = src.find("\nclean() {").expect("clean in panel.sh");
        let body = &src[f + 1..];
        let body = &body[..body.find("\n}\n").unwrap() + 3];
        let script = format!("{}\n{}\nfor s; do v=$s; clean v; printf '%s\\0' \"$v\"; done", pick.join("\n"), body);
        let ins = inputs();
        let args: Vec<&[u8]> = ins.iter().map(|v| v.as_slice()).collect();
        let out = nul_split(&bash(&script, &args));
        for (s, b) in ins.iter().zip(out) {
            assert_eq!(clean(s), b, "clean {:?}", s);
        }
    }

    #[test]
    fn each_pass_of_clean_as_bash() {
        setup();
        let script = r#"C1="" ZW=""
for i in {128..159}; do printf -v c '\\xc2\\x%x' "$i"; printf -v c "$c"; C1+=$c; done
for c in 80{8b,8c,8d,8e,8f,aa,ab,ac,ad,ae} 81{a6,a7,a8,a9}; do printf -v c '\\xe2\\x%s\\x%s' "${c:0:2}" "${c:2}"; printf -v c "$c"; ZW+=$c; done
for s; do printf '%s\0' "${s//[[:cntrl:]]/}" "${s//[$C1]/}" "${s//[$ZW]/}"; done"#;
        let ins = inputs();
        let args: Vec<&[u8]> = ins.iter().map(|v| v.as_slice()).collect();
        let mut o = nul_split(&bash(script, &args)).into_iter();
        let (c1, zw) = (c1_set(), zw_set());
        for s in &ins {
            assert_eq!(remove_all(s, Set::Cntrl), o.next().unwrap(), "[[:cntrl:]] {:?}", s);
            assert_eq!(remove_all(s, Set::Of(&c1)), o.next().unwrap(), "[$C1] {:?}", s);
            assert_eq!(remove_all(s, Set::Of(&zw)), o.next().unwrap(), "[$ZW] {:?}", s);
        }
    }

    #[test]
    fn arithmetic_as_bash() {
        setup();
        let ins: [&[u8]; 12] = [b"0", b"12", b"-7", b"010", b"0x1f", b"2#101", b"36#zz", b"", b" 5 ", b"9223372036854775807", b"64#_@", b"+3"];
        let mut script = String::new();
        for (i, _) in ins.iter().enumerate() {
            script.push_str(&format!("v=${{{}}}; printf '%s\\0' $((v)) $((v * 1103515245 + 12345)) $((v / -2)) $((v % 7)) $((v >> 3));", i + 1));
        }
        let out = nul_split(&bash(&script, &ins));
        let mut o = out.into_iter();
        for s in ins {
            let v = arith_int(s).unwrap();
            for r in [v, v.wrapping_mul(1103515245).wrapping_add(12345), v.wrapping_div(-2), v.wrapping_rem(7), v >> 3] {
                assert_eq!(itoa(r), o.next().unwrap(), "arithmetic on {:?}", s);
            }
        }
    }

    #[test]
    fn ere_as_bash() {
        setup();
        // [[ S =~ RE ]] and BASH_REMATCH, with and without nocasematch.
        let res: [&[u8]; 6] = [
            b"^([^[]*)\\[([^]]+)\\](.*)$",
            b"\x1b\\[[0-9;]*m",
            b"^[[:space:]\xe2\x94\x80]*$",
            b"(a|ab)(c|bcd)(d*)",
            b"[[:alpha:]]+",
            b"^(\xe2\x9d\xaf|>)\\ ?",
        ];
        let ins = inputs();
        let mut more: Vec<Bytes> = vec![b"Turn [P]eek on".to_vec(), b"abcd".to_vec(), b"ABCD".to_vec(), "❯ 1".as_bytes().to_vec(), b"> x".to_vec(), "── ─".as_bytes().to_vec()];
        more.extend(ins);
        for icase in [false, true] {
            for re in res {
                let mut args: Vec<&[u8]> = vec![re];
                args.extend(more.iter().map(|v| v.as_slice()));
                let script = format!(
                    "re=$1; shift; {}; for s; do if [[ $s =~ $re ]]; then printf '1\\0'; printf '%s\\0' \"${{BASH_REMATCH[@]}}\"; else printf '0\\0'; fi; done",
                    if icase { "shopt -s nocasematch" } else { ":" }
                );
                let out = nul_split(&bash(&script, &args));
                let mut o = out.into_iter();
                let e = Ere::new(re, icase).expect("compiles");
                for s in &more {
                    let hit = o.next().unwrap();
                    match e.matches(s) {
                        None => assert_eq!(hit, b"0", "{:?} =~ {:?}", s, re),
                        Some(m) => {
                            assert_eq!(hit, b"1", "{:?} =~ {:?}", s, re);
                            for g in m {
                                assert_eq!(g, o.next().unwrap(), "{:?} =~ {:?}", s, re);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every regex constant in panel.sh, as bash's own assignment gives it, compiled here and
    /// matched against a table of lines, with and without nocasematch, as `[[ =~ ]]` matches them.
    /// (The Rust constants themselves come with the code that uses them, Phase 2 to 5.)
    #[test]
    fn panel_regex_constants_as_bash() {
        setup();
        let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap();
        let names = ["VER_RE", "Q_RE", "W_RE", "UUID_RE", "LIM_RE", "STAT_RE", "USER_RE", "PW_STUB", "EB_RE", "KEY_RE"];
        let lines: Vec<&[u8]> = vec![
            b"1.2.56", b"1.2", b"01.002.3", b"Do you want to proceed?", b"Allow once", b"(Y/n)", b" Enter to select \xc2\xb7 Esc to cancel",
            b"enter select \xc2\xb7 esc back", b"Enter confirm, Esc close", b"3. Submit answers", b"esc to interrupt", b"Ctrl+C to interrupt",
            b"/tmp/claude-1000/x/0123abcd-0123-4567-89ab-0123456789ab/y", b"resets 3pm (Europe/Berlin)", b"Try again at Jan 5th, 2027 11:30 PM",
            b"1234 (bash) S 1 1234 1234 0 -1 4194560 100 0 0 0 12 34 5 6", b"root", b"_svc.x-1", b"9user",
            "  \u{2500}\u{2500}\u{256d}\u{256e} ".as_bytes(), b"\xe2\x94\x80x", b"", b"see /fix-this and @shop or `code` at https://x.example/a",
            b"Up", b"C-c", b"C-C", b"Enter ", b"x\xffy esc to interrupt", "漢字 do you want to".as_bytes(),
        ];
        for n in names {
            let line = src.lines().find(|l| l.starts_with(&format!("{}=", n))).unwrap_or_else(|| panic!("{} in panel.sh", n));
            for icase in [false, true] {
                let script = format!(
                    "{}\nprintf '%s\\0' \"${}\"; {}; for s in \"$@\"; do [[ $s =~ ${} ]] && printf '1\\0' || printf '0\\0'; done",
                    line, n, if icase { "shopt -s nocasematch" } else { ":" }, n
                );
                let out = bash(&script, &lines);
                let mut o = out.split(|&c| c == 0);
                let re = o.next().unwrap().to_vec();
                let e = Ere::new(&re, icase).unwrap_or_else(|| panic!("{} compiles", n));
                for l in &lines {
                    let b = o.next().unwrap();
                    assert_eq!(if e.is_match(l) { &b"1"[..] } else { &b"0"[..] }, b, "{} (icase {}) on {:?}", n, icase, String::from_utf8_lossy(l));
                }
            }
        }
    }

    /// regex_t is mirrored here (re_nsub is private in the libc crate): it must be the same size.
    #[test]
    fn regex_t_layout() {
        assert_eq!(std::mem::size_of::<RegexT>(), std::mem::size_of::<libc::regex_t>());
    }

    #[test]
    fn strftime_as_bash_in_utc() {
        setup();
        let fmts: [&[u8]; 4] = [b"%a %H:%M:%S", b"%H:%M:%S", b"%Y-%m-%d %b %j", b""];
        for f in fmts {
            for t in [0i64, 1795000000, 1700000000, -3, 4102444800] {
                let out = bash("printf \"%($1)T\" \"$2\"", &[f, t.to_string().as_bytes()]);
                // UTC here (setup); other zones and LC_TIME are not compared since the component stage went (plan, 1.3).
                assert_eq!(strftime(f, t), out, "%({:?})T {}", f, t);
            }
        }
    }

    /// The frame's other expansions: `${s^^}`, `${s,,}`, `${s/#$HOME/\~}` (HOME a glob),
    /// `IFS=';' read -ra`, and the `[[:space:]]` and `[[:space:]│]` removals (blank_tail,
    /// peek_wrap), over the same inputs.
    fn num_of(b: &[u8]) -> usize {
        std::str::from_utf8(b).unwrap().parse().unwrap()
    }
    #[test]
    fn frame_expansions_as_bash() {
        setup();
        let mut ins = inputs();
        ins.extend([&b"/tmp/golden/home/work"[..], b"/tmp/golden/homework", b"/tmp/gold*/x", b" \t \xe2\x94\x82 ", "│ │".as_bytes(), b"1;;2;", b";", b"a b\xe2\x94\x82", b"\xe2\x94 ", b"\xe2\x82\xe2\x82", b"a\xe2\x82", b"\xf0\x9f\x98", b"x\xc3", b"\xc3", b"\xe0\xa0", b"\xe0\x80", b"\xed\xa0", b"\xed\x9f", b"\xf0\x90", b"\xf0\x90\x80", b"\xf4\x90\x80", b"\xfc\x8f", b"\xf0\x80\x80", b"\xf1\x80\x80", b"\xf5\x80\x80", b"\xf8\x88\x80\x80", b"\xe1\x80"].iter().map(|v| v.to_vec()));
        let args: Vec<&[u8]> = ins.iter().map(|v| v.as_slice()).collect();
        let out = nul_split(&bash(
            r#"for s; do printf '%s\0' "${s^^}" "${s,,}"; for HOME in /tmp/golden/home '/tmp/g*' ''; do printf '%s\0' "${s/#$HOME/\~}"; done
IFS=';' read -ra P <<<"$s"; printf '%s\0' "${#P[@]}" "${P[@]}"; printf '%s\0' "${s//[[:space:]]/}" "${s//[[:space:]│]/}"; done"#,
            &args,
        ));
        let mut o = out.into_iter();
        for s in &ins {
            assert_eq!(case_map(s, true), o.next().unwrap(), "^^ {:?}", s);
            assert_eq!(case_map(s, false), o.next().unwrap(), ",, {:?}", s);
            for h in [&b"/tmp/golden/home"[..], b"/tmp/g*", b""] {
                assert_eq!(sub_prefix(s, h, b"~"), o.next().unwrap(), "/#{:?} {:?}", h, s);
            }
            // read stops at a newline: the inputs here have none past their first line's use
            // (read drops \x01 and \x7f, bash's own quoting bytes; read_split is given only
            // SGR parameters, [0-9;:], so those inputs are only read past here)
            let first = s.split(|&c| c == b'\n').next().unwrap();
            let p = read_split(first, b';');
            let n = o.next().unwrap();
            let theirs: Vec<Bytes> = (0..num_of(&n)).map(|_| o.next().unwrap()).collect();
            if !first.contains(&1) && !first.contains(&0x7f) {
                assert_eq!(p, theirs, "read -ra {:?}", s);
            }
            assert_eq!(remove_all(s, Set::SpaceOr(b"")), o.next().unwrap(), "[[:space:]] {:?}", s);
            assert_eq!(remove_all(s, Set::SpaceOr("│".as_bytes())), o.next().unwrap(), "[[:space:]│] {:?}", s);
        }
    }
}

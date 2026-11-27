//! The snapshot a bash `--once` saves (REVIVE_PANEL_SNAP=save:FILE, plan Phase 0.1), read as
//! bash's `snap_read` and `snap_apply` read it (scripts/panel.sh, "snapshots (tests)").
//!
//! FILE is NUL-separated records NAME\0INDEX\0VALUE\0: a variable's INDEX is empty, an array has a
//! record per element. Which names are read, and as what, comes from SNAP_VARS (a mirror of the
//! bash list, checked against it by a test), never from the file.

use crate::compat::{arith_int, Bytes};
use std::collections::{BTreeMap, HashMap};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    /// `s:` a variable
    Scalar,
    /// `a:` an indexed array (sparse: P_LIM, P_SRV, W_SINCE keep their indexes)
    Indexed,
    /// `A:` an associative array
    Assoc,
}
use Kind::*;

/// SNAP_VARS in scripts/panel.sh, in its order. A change there lands here in the same commit
/// (the test `snap_vars_match_panel_sh` fails until it does).
pub const SNAP_VARS: &[(Kind, &str)] = &[
    // What the looks gathered.
    (Indexed, "P_ID"), (Indexed, "P_LOC"), (Indexed, "P_NAME"), (Indexed, "P_APP"), (Indexed, "P_STATE"),
    (Indexed, "P_DIR"), (Indexed, "P_GIT"), (Indexed, "P_CPU"), (Indexed, "P_MEM"), (Indexed, "P_CTX"),
    (Indexed, "P_AGENT"), (Indexed, "P_SSH"), (Indexed, "P_HOST"), (Indexed, "P_RID"), (Indexed, "P_WP"),
    (Indexed, "P_USER"), (Indexed, "P_INST"), (Indexed, "P_ACCT"), (Indexed, "P_SRV"), (Indexed, "P_LIM"),
    (Indexed, "P_LWHY"), (Scalar, "P_GROUPS"),
    (Indexed, "W_SINCE"), (Indexed, "W_FROM"), (Indexed, "W_REPLY"), (Indexed, "X_SSH"), (Indexed, "X_WHERE"),
    (Assoc, "RVER"), (Assoc, "ROWNER"), (Assoc, "LUP"), (Assoc, "FOLD"), (Indexed, "CPU_HIST"),
    (Scalar, "VERSION"), (Scalar, "HOST"), (Scalar, "SCENE"), (Scalar, "TICK"), (Scalar, "SECONDS"),
    // What draw reads from outside (snap_look).
    (Indexed, "MSG"), (Scalar, "MOLD"), (Scalar, "MWAIT"), (Scalar, "MSG_INTRO"), (Scalar, "INTRO_ON"),
    (Indexed, "SIDE"), (Indexed, "INTROS"),
    (Scalar, "SCREEN_ID"), (Indexed, "SCREEN"), (Indexed, "SCREEN_E"), (Scalar, "RPEEK_FOR"), (Scalar, "RPEEK_AT"),
    (Indexed, "RPEEK"),
    // Where you are: the selection, the windows, the peek, the ? page, a flash, a question.
    (Scalar, "SEL"), (Scalar, "SEL_ID"), (Scalar, "HSEL"), (Scalar, "FOCUS"), (Indexed, "WON"), (Scalar, "PO"),
    (Scalar, "PB"), (Scalar, "PB_FOR"), (Scalar, "MO"), (Scalar, "SO"), (Scalar, "MMAN"),
    (Scalar, "PEEK"), (Scalar, "PEEK_SEL"), (Scalar, "PEEK_ALL"), (Scalar, "HELP"), (Scalar, "HELP_TOP"),
    (Scalar, "FLASH"), (Scalar, "FLASH_T"),
    // The notices waiting, and the loading box, which holds them back.
    (Indexed, "NOTICES"), (Scalar, "LBOX"),
    (Scalar, "ANSWERING"), (Indexed, "ATOP"), (Scalar, "ATOP_BH"), (Indexed, "QL"), (Scalar, "QFREE"),
    (Scalar, "QFREEN"), (Scalar, "QON"), (Scalar, "QEMPTY"), (Scalar, "QHAS"),
];

pub fn kind_of(name: &[u8]) -> Option<(Kind, &'static str)> {
    SNAP_VARS.iter().find(|(_, n)| n.as_bytes() == name).map(|&(k, n)| (k, n))
}

/// What snap_apply leaves: every array emptied and then filled from the file; a variable only
/// when the file has it (bash's variable otherwise keeps the value the panel started with, so
/// "absent" is kept apart from "empty"). SECONDS goes to `snap_secs` (bash's SNAP_SECS).
#[derive(Default, Debug, Clone, PartialEq)]
pub struct Snapshot {
    pub scalars: HashMap<&'static str, Bytes>,
    pub arrays: HashMap<&'static str, BTreeMap<i64, Bytes>>,
    pub assoc: HashMap<&'static str, BTreeMap<Bytes, Bytes>>,
    pub snap_secs: Option<Bytes>,
}

#[derive(Debug)]
pub enum Error {
    /// snap_read: `[[ -f $1 && -r $1 ]] || return 1`
    NoFile,
    /// An index bash's arithmetic refuses (08 is octal and too great for its base): bash's
    /// non-interactive shell exits there, with this message.
    BadIndex(String),
}

/// snap_read FILE -> its records (NAME, INDEX, VALUE), as `read -r -d ''` three at a time takes
/// them: a last record cut short (no NUL after its value, or missing fields) is dropped.
pub fn records(data: &[u8]) -> Vec<(Bytes, Bytes, Bytes)> {
    let mut f = data.split(|&b| b == 0);
    let mut parts: Vec<&[u8]> = Vec::new();
    let mut out = Vec::new();
    // split yields a final piece after the last NUL (empty when the file ends in one): it never
    // completes a field, since read -d '' fails at end of file without its delimiter.
    let n_complete = data.iter().filter(|&&b| b == 0).count();
    for _ in 0..n_complete {
        parts.push(f.next().unwrap());
        if parts.len() == 3 {
            out.push((parts[0].to_vec(), parts[1].to_vec(), parts[2].to_vec()));
            parts.clear();
        }
    }
    out
}

impl Snapshot {
    pub fn read(path: &std::path::Path) -> Result<Snapshot, Error> {
        if !path.is_file() {
            return Err(Error::NoFile);
        }
        let data = std::fs::read(path).map_err(|_| Error::NoFile)?;
        Snapshot::apply(&records(&data))
    }

    /// snap_apply: each record whose name is in SNAP_VARS, with an index that fits its kind.
    pub fn apply(recs: &[(Bytes, Bytes, Bytes)]) -> Result<Snapshot, Error> {
        let mut s = Snapshot::default();
        for &(k, n) in SNAP_VARS {
            match k {
                Indexed => {
                    s.arrays.insert(n, BTreeMap::new());
                }
                Assoc => {
                    s.assoc.insert(n, BTreeMap::new());
                }
                Scalar => {}
            }
        }
        for (n, k, v) in recs {
            // [[ $n =~ ^[A-Z][A-Z0-9_]*$ ]]
            if n.is_empty() || !n[0].is_ascii_uppercase() || !n.iter().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || *c == b'_') {
                continue;
            }
            let Some((kind, name)) = kind_of(n) else { continue };
            match kind {
                Scalar => {
                    if !k.is_empty() {
                        continue;
                    }
                    if name == "SECONDS" {
                        s.snap_secs = Some(v.clone());
                    } else {
                        s.scalars.insert(name, v.clone());
                    }
                }
                Indexed => {
                    // [[ $k =~ ^[0-9]{1,9}$ ]], then _t[$k]: arithmetic, so 010 is 8 and 08 an error
                    if k.is_empty() || k.len() > 9 || !k.iter().all(u8::is_ascii_digit) {
                        continue;
                    }
                    let i = arith_int(k).ok_or_else(|| {
                        Error::BadIndex(format!("{}: value too great for base (error token is \"{}\")", String::from_utf8_lossy(k), String::from_utf8_lossy(k)))
                    })?;
                    s.arrays.get_mut(name).unwrap().insert(i, v.clone());
                }
                Assoc => {
                    if k.is_empty() {
                        continue;
                    }
                    s.assoc.get_mut(name).unwrap().insert(k.clone(), v.clone());
                }
            }
        }
        Ok(s)
    }

    /// A variable: Some (set, maybe empty) or None (the file doesn't have it).
    pub fn var(&self, name: &str) -> Option<&[u8]> {
        self.scalars.get(name).map(|v| v.as_slice())
    }
    /// An indexed array's elements in index order (as "${A[@]}").
    pub fn list(&self, name: &str) -> Vec<Bytes> {
        self.arrays.get(name).map(|m| m.values().cloned().collect()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compat::tests::{bash, setup};

    fn panel_sh() -> String {
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh")).unwrap()
    }
    /// The text of bash function NAME in panel.sh, through its closing brace.
    fn func(src: &str, name: &str) -> String {
        let a = src.find(&format!("\n{}() {{", name)).unwrap_or_else(|| panic!("{} in panel.sh", name)) + 1;
        let b = src[a..].find("\n}\n").unwrap() + a + 3;
        src[a..b].to_string()
    }

    #[test]
    fn snap_vars_match_panel_sh() {
        let src = panel_sh();
        let a = src.find("\nSNAP_VARS=(").expect("SNAP_VARS in panel.sh");
        let b = src[a..].find("\n)\n").unwrap() + a;
        let theirs: Vec<String> = src[a + 12..b]
            .lines()
            .map(|l| l.split('#').next().unwrap())
            .flat_map(|l| l.split_whitespace().map(String::from).collect::<Vec<_>>())
            .collect();
        let ours: Vec<String> = SNAP_VARS
            .iter()
            .map(|(k, n)| format!("{}:{}", match k { Scalar => "s", Indexed => "a", Assoc => "A" }, n))
            .collect();
        assert_eq!(ours, theirs, "SNAP_VARS here and in scripts/panel.sh differ");
    }

    /// Records with a bit of everything: bytes that aren't UTF-8, newlines and escapes in values,
    /// sparse and octal-looking indexes, names not in the list, a scalar given an index, an
    /// associative array, SECONDS, and a last record cut short.
    fn tricky() -> Vec<u8> {
        let mut f = Vec::new();
        let mut rec = |n: &[u8], k: &[u8], v: &[u8]| {
            f.extend_from_slice(n);
            f.push(0);
            f.extend_from_slice(k);
            f.push(0);
            f.extend_from_slice(v);
            f.push(0);
        };
        rec(b"P_ID", b"0", b"%1");
        rec(b"P_ID", b"3", b"%9");
        rec(b"P_LIM", b"7", b"1795000000");
        rec(b"P_NAME", b"0", b"caf\xe9-\xff\nsecond line\x1b[31m");
        rec(b"P_NAME", b"010", b"octal: index 8");
        rec(b"HOST", b"", b"golden");
        rec(b"HOST", b"1", b"a scalar with an index: passed over");
        rec(b"SECONDS", b"", b"42");
        rec(b"FOLD", b"far.example", b"1");
        rec(b"FOLD", b"", b"empty key: passed over");
        rec(b"NOPE", b"", b"not in the list");
        rec(b"p_id", b"0", b"lower case");
        rec(b"FLASH", b"", b"");
        rec(b"SCREEN", b"1x", b"not a number");
        rec(b"SCREEN", b"1234567890", b"ten digits");
        rec(b"SCREEN", b"2", b"\\ back\\slash");
        f.extend_from_slice(b"TICK\0\x007");
        f
    }

    #[test]
    fn read_as_bash_reads() {
        setup();
        let dir = std::env::temp_dir().join(format!("panel-rs-snap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("snap");
        std::fs::write(&file, tricky()).unwrap();
        let src = panel_sh();
        let a = src.find("\nSNAP_VARS=(").unwrap() + 1;
        let b = src[a..].find("\n)\n").unwrap() + a + 3;
        // bash's own reader, then every listed name dumped: a variable only when it is set.
        let script = format!(
            "{}declare -A SNAP_T=()\nfor v in \"${{SNAP_VARS[@]}}\"; do SNAP_T[${{v#?:}}]=${{v%%:*}}; done\n{}{}{}{}",
            &src[a..b],
            func(&src, "snap_read"),
            func(&src, "snap_apply"),
            func(&src, "snap_set"),
            r#"for v in "${SNAP_VARS[@]}"; do case $v in a:*) declare -a "${v#a:}" ;; A:*) declare -gA "${v#A:}" ;; esac; done
snap_read "$1"; snap_apply
for v in "${SNAP_VARS[@]}"; do
	n=${v#?:}
	case $v in
	s:SECONDS) [[ -n ${SNAP_SECS+set} ]] && printf 's\0%s\0\0%s\0' "$n" "$SNAP_SECS" ;;
	s:*) [[ -n ${!n+set} ]] && printf 's\0%s\0\0%s\0' "$n" "${!n}" ;;
	*) declare -n _a=$n; for k in "${!_a[@]}"; do printf '%s\0%s\0%s\0%s\0' "${v%%:*}" "$n" "$k" "${_a[$k]}"; done; unset -n _a ;;
	esac
done
:"#
        );
        let out = bash(&script, &[file.as_os_str().as_encoded_bytes()]);
        let mut theirs: Vec<Vec<Bytes>> = out.split(|&c| c == 0).map(|s| s.to_vec()).collect::<Vec<_>>().chunks(4).filter(|c| c.len() == 4).map(|c| c.to_vec()).collect();
        let s = Snapshot::read(&file).unwrap();
        let mut ours: Vec<Vec<Bytes>> = Vec::new();
        for &(k, n) in SNAP_VARS {
            match k {
                Scalar => {
                    let v = if n == "SECONDS" { s.snap_secs.clone() } else { s.var(n).map(|v| v.to_vec()) };
                    if let Some(v) = v {
                        ours.push(vec![b"s".to_vec(), n.into(), vec![], v]);
                    }
                }
                Indexed => {
                    for (i, v) in &s.arrays[n] {
                        ours.push(vec![b"a".to_vec(), n.into(), i.to_string().into(), v.clone()]);
                    }
                }
                Assoc => {
                    for (i, v) in &s.assoc[n] {
                        ours.push(vec![b"A".to_vec(), n.into(), i.clone(), v.clone()]);
                    }
                }
            }
        }
        // An associative array's order is bash's hash order: compared as sets.
        theirs.sort();
        ours.sort();
        assert_eq!(ours, theirs);
        assert!(s.var("TICK").is_none(), "a record cut short is dropped");
        assert_eq!(s.arrays["P_NAME"].get(&8).map(|v| v.as_slice()), Some(&b"octal: index 8"[..]));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_index_bash_cannot_read_stops_it() {
        let r = Snapshot::apply(&[(b"P_ID".to_vec(), b"08".to_vec(), b"x".to_vec())]);
        assert!(matches!(r, Err(Error::BadIndex(_))));
    }
}

//! The live frame's writer: scripts/panel.sh draw's `else` branch after the frame is built (plan
//! Phase 3.1). Only the lines that changed since the last frame are sent, each placed by row,
//! the tail cleared when the frame got shorter, and the whole update wrapped in synchronized-output marks (?2026), the cursor left at the top.

use crate::compat::{itoa, Bytes};

const E: &[u8] = b"\x1b";

/// draw's writer: OUT against PREV (PREV becomes OUT), and NB, the notice box painted over the
/// frame when one is up -> what is printed (nothing when nothing changed)
pub fn frame(out: &[Bytes], prev: &mut Vec<Bytes>, nb: Option<&[u8]>) -> Bytes {
    let mut buf: Bytes = Vec::new();
    for (i, l) in out.iter().enumerate() {
        // [[ ${OUT[i]} == "${PREV[i]-}" ]] && continue
        if prev.get(i).map(|p| p.as_slice()).unwrap_or(b"") == l.as_slice() {
            continue;
        }
        buf.extend_from_slice(E);
        buf.push(b'[');
        buf.extend(itoa(i as i64 + 1));
        buf.extend_from_slice(b";1H");
        buf.extend_from_slice(l);
        buf.extend_from_slice(E);
        buf.extend_from_slice(b"[K");
    }
    if out.len() < prev.len() {
        buf.extend_from_slice(E);
        buf.push(b'[');
        buf.extend(itoa(out.len() as i64 + 1));
        buf.extend_from_slice(b";1H");
        buf.extend_from_slice(E);
        buf.extend_from_slice(b"[J");
    }
    *prev = out.to_vec();
    if let Some(nb) = nb {
        buf.extend_from_slice(nb);
    }
    if buf.is_empty() {
        return buf;
    }
    let mut w = b"\x1b[?2026h".to_vec();
    w.extend(buf);
    w.extend_from_slice(b"\x1b[H\x1b[?2026l");
    w
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compat::tests::bash;

    /// bash's own loop, cut out of scripts/panel.sh's draw with sed: from `local buf="" i` to
    /// the printf that sends it, run on OUT and PREV given as NUL-separated arguments
    fn theirs(out: &[Bytes], prev: &[Bytes], nb: Option<&[u8]>) -> Bytes {
        let f = concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/panel.sh");
        let cut = std::process::Command::new("sed")
            .args(["-n", r#"/^		local buf="" i$/,/^		\[\[ -n \$buf \]\] && printf/p"#, f])
            .output()
            .expect("sed runs")
            .stdout;
        let cut = String::from_utf8(cut).unwrap();
        assert!(cut.contains("PREV=(\"${OUT[@]}\")") && cut.contains("?2026"), "the writer wasn't found in panel.sh:\n{}", cut);
        let s = format!(
            "e=$'\\e'\nOUT=() PREV=()\nmode=out\nfor a in \"${{@:2}}\"; do [[ $a == --prev ]] && {{ mode=prev; continue; }}; if [[ $mode == out ]]; then OUT+=(\"$a\"); else PREV+=(\"$a\"); fi; done\nNB=$1\nnotice_up() {{ [[ -n $NB ]]; }}\nnotice_box() {{ :; }}\nw() {{\n{}\n}}\nw\nprintf '\\n--\\n'\nprintf '%s\\n' \"${{PREV[@]}}\"\n",
            cut
        );
        let mut args: Vec<&[u8]> = vec![nb.unwrap_or(b"")];
        for o in out {
            args.push(o);
        }
        args.push(b"--prev");
        for p in prev {
            args.push(p);
        }
        bash(&s, &args)
    }

    fn ours(out: &[Bytes], prev: &[Bytes], nb: Option<&[u8]>) -> Bytes {
        let mut p = prev.to_vec();
        let mut v = frame(out, &mut p, nb);
        v.extend_from_slice(b"\n--\n");
        if p.is_empty() {
            v.push(b'\n'); // printf '%s\n' with no arguments
        }
        for l in &p {
            v.extend_from_slice(l);
            v.push(b'\n');
        }
        v
    }

    #[test]
    fn the_same_bytes_as_bashs_writer() {
        crate::compat::tests::setup();
        let b = |v: &[&str]| -> Vec<Bytes> { v.iter().map(|s| s.as_bytes().to_vec()).collect() };
        let cases: Vec<(Vec<Bytes>, Vec<Bytes>, Option<&[u8]>)> = vec![
            (b(&["╔══╗", "║ a ║", "╚══╝"]), vec![], None),
            (b(&["╔══╗", "║ a ║", "╚══╝"]), b(&["╔══╗", "║ a ║", "╚══╝"]), None),
            (b(&["╔══╗", "║ b ║", "╚══╝"]), b(&["╔══╗", "║ a ║", "╚══╝"]), None),
            (b(&["╔══╗", "╚══╝"]), b(&["╔══╗", "║ a ║", "╚══╝"]), None),
            (b(&["x", "y", "z", "w"]), b(&["x"]), None),
            (b(&["x", "", "z"]), b(&["x"]), None),
            (b(&["\x1b[34mx\x1b[0m", "y"]), b(&["x", "y"]), Some(b"\x1b[3;4H\x1b[44m box \x1b[0m")),
            (b(&["same"]), b(&["same"]), Some(b"\x1b[1;1HNB")),
            (vec![], b(&["a", "b"]), None),
            (vec![vec![0xff, b'q', 0xc3]], vec![vec![0xff]], None),
        ];
        for (out, prev, nb) in &cases {
            assert_eq!(
                String::from_utf8_lossy(&ours(out, prev, *nb)),
                String::from_utf8_lossy(&theirs(out, prev, *nb)),
                "OUT {:?} PREV {:?}",
                out,
                prev
            );
            assert_eq!(ours(out, prev, *nb), theirs(out, prev, *nb));
        }
    }
}

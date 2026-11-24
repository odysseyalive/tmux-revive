//! The ported builders against bash's own (test-only, until whole frames are compared): the calls
//! of tests/calls.py run through tests/component.sh, which cuts the functions out of
//! scripts/panel.sh, and through `tmux-revive-panel --component`, and every call's results are
//! compared byte for byte. test/panel-golden.sh's `components` stage runs the same with the art
//! at the sizes the frames draw it.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn here() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn calls(args: &[&str]) -> Vec<u8> {
    let o = Command::new("python3").arg("-I").arg(here().join("tests/calls.py")).args(args).output().expect("python3 runs");
    assert!(o.status.success(), "calls.py: {}", String::from_utf8_lossy(&o.stderr));
    o.stdout
}

fn run(cmd: &mut Command, input: &[u8], env: &[(&str, &str)]) -> Vec<u8> {
    use std::io::Write;
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut c = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().expect("runs");
    let mut i = c.stdin.take().unwrap();
    let data = input.to_vec();
    let w = std::thread::spawn(move || i.write_all(&data));
    let o = c.wait_with_output().unwrap();
    w.join().unwrap().ok();
    assert!(o.status.success(), "{:?}: {}", cmd, String::from_utf8_lossy(&o.stderr));
    o.stdout
}

/// The calls, as (name and arguments) for the failure message.
fn split_calls(input: &[u8]) -> Vec<Vec<String>> {
    let f: Vec<&[u8]> = input.split(|&b| b == 0).collect();
    let mut v = Vec::new();
    let mut i = 0;
    while i + 1 < f.len() {
        let n: usize = std::str::from_utf8(f[i]).unwrap().parse().unwrap();
        v.push(f[i + 1..i + 1 + n].iter().map(|a| format!("{:?}", String::from_utf8_lossy(a))).collect());
        i += 1 + n;
    }
    v
}

fn compare(group: &str, input: &[u8], env: &[(&str, &str)]) {
    let bash = run(Command::new("bash").arg(here().join("tests/component.sh")), input, env);
    let rust = run(&mut Command::new(env!("CARGO_BIN_EXE_tmux-revive-panel")).arg("--component"), input, env);
    let cs = split_calls(input);
    let (a, b): (Vec<&[u8]>, Vec<&[u8]>) = (bash.split(|&c| c == b'\n').collect(), rust.split(|&c| c == b'\n').collect());
    assert_eq!(a.len(), cs.len() + 1, "{}: bash answered {} of {} calls", group, a.len() - 1, cs.len());
    let bad: Vec<usize> = (0..cs.len()).filter(|&k| a[k] != b[k]).collect();
    if let Some(&k) = bad.first() {
        panic!(
            "{} {:?}: {} of {} calls differ; the first, {}: {:?}\n bash: {:?}\n rust: {:?}",
            group,
            env,
            bad.len(),
            cs.len(),
            k,
            cs[k],
            String::from_utf8_lossy(a[k]),
            String::from_utf8_lossy(b[k])
        );
    }
}

const UTF8: &[(&str, &str)] = &[("LC_ALL", "C.UTF-8"), ("TZ", "UTC")];

#[test]
fn primitives_as_bash() {
    compare("prims", &calls(&["prims"]), UTF8);
}

#[test]
fn banner_as_bash() {
    compare("banner", &calls(&["banner"]), UTF8);
}

#[test]
fn art_as_bash() {
    compare("art", &calls(&["art"]), UTF8);
}

/// strftime and the */ glob's order under each locale and zone: the process's own, so each is a
/// run of its own.
#[test]
fn locale_and_zone_as_bash() {
    let d = std::env::temp_dir().join(format!("panel-rs-glob-{}", std::process::id()));
    for n in ["B", "a", "_c", "Zed.example", "far.example", ".hidden", "é", "x y", "caf\u{e9}-2"] {
        std::fs::create_dir_all(d.join(n)).unwrap();
    }
    std::fs::write(d.join("file"), b"").unwrap();
    std::os::unix::fs::symlink("B", d.join("linkB")).ok();
    let input = calls(&["locale", d.to_str().unwrap()]);
    for loc in ["C.UTF-8", "en_US.UTF-8", "C"] {
        for tz in ["UTC", "America/New_York", "Asia/Kolkata"] {
            compare("locale", &input, &[("LC_ALL", loc), ("TZ", tz)]);
        }
    }
    std::fs::remove_dir_all(Path::new(&d)).ok();
}

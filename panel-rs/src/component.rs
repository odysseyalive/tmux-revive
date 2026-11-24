//! `--component`, test-only: the ported builders called one at a time, for comparing with bash's
//! own functions cut out of scripts/panel.sh (panel-rs/tests/component.sh reads the same calls
//! and writes the same way). It stands in for the frame until `--once --snapshot` draws one;
//! once tier 1 (`test/panel-golden.sh render`) compares whole frames, which hold every builder
//! here, it is removed with component.sh (plan, Phase 1.3).
//!
//! Input: calls, each ARGC\0 then ARGC fields NAME\0ARG\0...; output: each call's results, every
//! one followed by \0, then \n.

use crate::compat::{self, arith_int, Bytes};
use crate::render::Ctx;
use std::io::{Read, Write};

fn num(b: &[u8]) -> i64 {
    arith_int(b).unwrap_or(0)
}
fn opt(a: &[Bytes], i: usize) -> Option<&[u8]> {
    a.get(i).map(|v| v.as_slice())
}

pub fn run(input: &mut dyn Read, out: &mut dyn Write) -> std::io::Result<()> {
    let mut data = Vec::new();
    input.read_to_end(&mut data)?;
    let mut f = data.split(|&b| b == 0);
    let mut ctx = Ctx::new();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(argc) = f.next() {
        if argc.is_empty() && f.clone().next().is_none() {
            break;
        }
        let n = num(argc) as usize;
        let mut a: Vec<Bytes> = Vec::with_capacity(n);
        for _ in 0..n {
            a.push(f.next().unwrap_or_default().to_vec());
        }
        let res = call(&mut ctx, &a);
        for r in res {
            buf.extend_from_slice(&r);
            buf.push(0);
        }
        buf.push(b'\n');
    }
    out.write_all(&buf)
}

fn call(ctx: &mut Ctx, a: &[Bytes]) -> Vec<Bytes> {
    let name = a[0].as_slice();
    let args = &a[1..];
    let s = |i: usize| -> &[u8] { args.get(i).map(|v| v.as_slice()).unwrap_or(b"") };
    match name {
        // The globals the builders read.
        b"set" => {
            let v = s(1).to_vec();
            match s(0) {
                b"TICK" => ctx.tick = num(&v),
                b"W" => ctx.w = num(&v),
                b"IW" => ctx.iw = num(&v),
                b"RBAR" => ctx.rbar = v,
                b"ROWL" => ctx.rowl = v,
                b"ROWR" => ctx.rowr = v,
                b"SCENE" => ctx.scene = num(&v),
                x => panic!("component: can't set {}", String::from_utf8_lossy(x)),
            }
            vec![]
        }
        b"hist" => {
            ctx.cpu_hist = args.iter().enumerate().map(|(i, v)| (i as i64, num(v))).collect();
            vec![]
        }
        // compat
        b"len" => vec![compat::itoa(compat::blen(s(0)))],
        b"clean" => vec![compat::clean(s(0))],
        b"strftime" => vec![compat::strftime(s(0), num(s(1)))],
        b"globdirs" => compat::glob_dirs(s(0)),
        b"ere" => {
            let icase = s(2) == b"icase";
            match compat::Ere::new(s(0), icase).and_then(|e| e.matches(s(1))) {
                Some(m) => std::iter::once(b"1".to_vec()).chain(m).collect(),
                None => vec![b"0".to_vec()],
            }
        }
        // drawing
        b"rep" => vec![ctx.rep(s(0), num(s(1)))],
        b"fld" => vec![ctx.fld(s(0), num(s(1)))],
        b"vlen" => vec![compat::itoa(ctx.vlen(s(0)))],
        b"padv" => vec![ctx.padv(s(0), num(s(1)))],
        b"trim_colored" => vec![ctx.trim_colored(s(0), num(s(1)))],
        b"line" | b"row" | b"sectk" | b"sect" | b"sect2" => {
            ctx.out.clear();
            match name {
                b"line" => ctx.line(s(0).to_vec()),
                b"row" => {
                    let w = opt(args, 1).filter(|w| !w.is_empty()).map(num);
                    ctx.row(&s(0).to_vec(), w)
                }
                b"sectk" => ctx.sectk(s(0), s(1), opt(args, 2), opt(args, 3), opt(args, 4)),
                b"sect" => ctx.sect(s(0), opt(args, 1), opt(args, 2), opt(args, 3)),
                _ => ctx.sect2(num(s(0)), s(1), s(2), s(3), s(4), s(5), s(6), s(7), s(8), s(9)),
            }
            std::mem::take(&mut ctx.out)
        }
        b"sbar" => ctx
            .sbar(num(s(0)), num(s(1)), num(s(2)), num(s(3)), num(s(4)), opt(args, 5))
            .into_iter()
            .flat_map(|(i, v)| [compat::itoa(i), v])
            .collect(),
        b"tab" => vec![ctx.tab(s(0), opt(args, 1))],
        b"seg" => vec![ctx.seg(s(0), s(1), s(2), num(s(3)), s(4))],
        b"kc" => vec![ctx.kc(s(0), s(1))],
        b"kcs" => {
            let v: Vec<&[u8]> = args.iter().map(|x| x.as_slice()).collect();
            vec![ctx.kcs(&v)]
        }
        b"meter" => vec![ctx.meter(s(0))],
        b"human" => vec![ctx.human(num(s(0)))],
        // banner
        b"banner_rows" => ctx.banner_rows(s(0)).to_vec(),
        b"big_banner" => {
            let v: Vec<&[u8]> = args.iter().skip(1).map(|x| x.as_slice()).collect();
            ctx.big_banner(s(0), &v)
        }
        b"monitor" => ctx.monitor(s(0), s(1), s(2)),
        b"spark" => vec![ctx.spark(num(s(0)))],
        // art
        b"tri" => vec![compat::itoa(ctx.tri(num(s(0)), num(s(1)), num(s(2))))],
        b"art" | b"art_memo" => ctx.art(num(s(0)), num(s(1)), s(2) == b"still"),
        x => panic!("component: no such call {}", String::from_utf8_lossy(x)),
    }
}

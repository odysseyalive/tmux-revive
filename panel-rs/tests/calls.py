#!/usr/bin/env python3
"""calls.py GROUP [SIZES]: the calls component.sh and `tmux-revive-panel --component` both run,
on stdout in their format (ARGC\\0 NAME\\0 ARG\\0 ...). The same every run (a fixed seed).

  prims    rep .. sect2, kc, kcs, trim_colored, meter, human, and clean/len, over edge cases and
           a fuzz of coloured strings with bytes that aren't UTF-8
  banner   banner_rows, big_banner, monitor, spark
  art      every scene at TICK 0, 1 and 7, at each WxH in SIZES ("76x10 196x27 ..."), beside the
           banner (still) and at a few small sizes; with no SIZES, a short list of its own.
  memo, fresh SIZES   each scene and size at TICK 1 then 7, through bash's memo (art_memo) or not
  locale   strftime and globdirs DIR (run under the locale and TZ being compared)
"""
import random
import sys

E = b"\x1b"
R = E + b"[0m"


def call(*args):
    a = [x if isinstance(x, bytes) else str(x).encode() for x in args]
    return str(len(a)).encode() + b"\0" + b"".join(x + b"\0" for x in a)


TEXT = [
    b"", b"plain", "漢字テスト".encode(), "éä".encode(), b"a\x01b\x7fc", b"a\xc2\x85b",
    "a‮b​c".encode(), b"x\xffy", b"\xe2\x82z", b"\xe2\x82", b"\xc0\x80", b"\xed\xa0\x80",
    b"\xf4\x90\x80\x80", b"\xf8\x88\x80\x80\x80", b"\xff\xc3\xa9\xe2\x80\xa6", "─━═│😀".encode(),
    "PANES".encode(), "▸ PEEK · asker".encode(), ("long ±" * 40).encode(),
]
SGR = [R, E + b"[1m", E + b"[1;32m", E + b"[38;5;123m", E + b"[m", E + b"[1", E + b"[\x1b[0mm", E + b"[48;5;31m", E + b"[;;m"]


def fuzz(rng, n):
    out = []
    for _ in range(n):
        s = b""
        for _ in range(rng.randrange(0, 9)):
            k = rng.randrange(6)
            if k == 0:
                s += rng.choice(SGR)
            elif k == 1:
                s += rng.choice(TEXT[:16])
            elif k == 2:
                s += bytes([rng.choice([0x80, 0xa9, 0xc2, 0xc3, 0xe2, 0xf0, 0xf8, 0xff, 0x1b, 0x5b, 0x6d, 0x3b, 0x31])])
            else:
                s += rng.choice([b"a", b"ab ", "é".encode(), "…".encode(), "█".encode(), b"[P]", b"0", b";"])
        out.append(s)
    return out


def prims():
    rng = random.Random(7919)
    texts = TEXT + fuzz(rng, 120)
    v = []
    for t in texts:
        v.append(call("len", t))
        v.append(call("clean", t))
        v.append(call("vlen", t))
    for ch in ["═", " ", "ab", "─"]:
        for n in [0, 1, 5, -3]:
            v.append(call("rep", ch, n))
    for t in texts:
        for w in [0, 1, 5, 11, 40]:
            v.append(call("fld", t, w))
    for t in texts:
        for w in [0, 1, 3, 10, 30]:
            v.append(call("padv", t, w))
        for w in [-1, 0, 1, 2, 5, 20]:
            v.append(call("trim_colored", t, w))
    for iw in [76, 96, 6]:
        v.append(call("set", "IW", iw))
        for rbar, rowl in [(b"", b"\x1b[34m"), (b"\x1b[34m\xe2\x96\x93", b"\x1b[96m")]:
            v.append(call("set", "RBAR", rbar))
            v.append(call("set", "ROWL", rowl))
            v.append(call("set", "ROWR", rowl))
            for t in texts[::3]:
                v.append(call("row", t))
                v.append(call("row", t, ""))
                v.append(call("row", t, 70))
    v.append(call("set", "RBAR", b""))
    v.append(call("set", "ROWL", b"\x1b[34m"))
    v.append(call("set", "ROWR", b"\x1b[34m"))
    v.append(call("set", "IW", 76))
    v.append(call("line", "a line"))
    for tick in [0, 1]:
        v.append(call("set", "TICK", tick))
        for h in [0, 1, 2, 3, 5, 10]:
            for n in [0, 1, 3, 10, 57]:
                for o in [0, 1, 4, 40]:
                    for up, dn in [(0, 0), (1, 0), (0, 1), (1, 1)]:
                        v.append(call("sbar", h, n, o, up, dn))
                        if (h + n + o) % 3 == 0:
                            v.append(call("sbar", h, n, o, up, dn, b"\x1b[96m"))
                            v.append(call("sbar", h, n, o, up, dn, b""))
    tabs = []
    for t in [b"PANES", "▸ PANES".encode(), "ART · night city".encode(), b"", "QUESTION · 漢字".encode(), b"x\xffy"]:
        for c in [None, b"", b"4", b"5", b"6"]:
            v.append(call("tab", t) if c is None else call("tab", t, c))
        tabs.append(t)
    keys = [b"", b"\x1b[94m[\x1b[1m\x1b[93mP\x1b[0m\x1b[94m]\x1b[0m\x1b[97meek\x1b[0m", ("k" * 90).encode()]
    hints = [b"", "[⇧J] focus".encode(), ("hint " * 20).encode()]
    for t in tabs:
        for c in [b"4", b"5"]:
            tab = b"\x1b[3" + c + "m░▒▓".encode() + b"\x1b[4" + c + b"m\x1b[1m\x1b[97m " + t + b" " + R + b"\x1b[3" + c + "m▓▒░".encode() + R
            for h in hints:
                for k in keys:
                    for w in [10, 20, 40, 78, 126]:
                        v.append(call("seg", tab, h, k, w, b"\x1b[34m"))
    for W in [80, 100, 200]:
        v.append(call("set", "W", W))
        for t in tabs[:3]:
            for k in keys:
                v.append(call("sectk", t, k))
                v.append(call("sectk", t, k, "6", b"\x1b[96m", hints[1]))
                v.append(call("sectk", t, k, "", "", ""))
            v.append(call("sect", t))
            v.append(call("sect", t, "6", b"\x1b[96m", hints[1]))
            v.append(call("sect", t, "", "", ""))
        for split in [30, 47, 70]:
            v.append(call("sect2", split, b"\x1b[34m", "MESSAGES", "4", b"\x1b[34m", hints[1], "LINKS · SAVES", "4", b"\x1b[96m", ""))
            v.append(call("sect2", split, b"\x1b[96m", ("M" * 60).encode(), "6", b"\x1b[96m", hints[2], "L", "", b"\x1b[34m", hints[1]))
    for k, l in [("P", "eek"), ("⇧J/⇧K", " focus"), ("", ""), ("Esc", " closes")]:
        v.append(call("kc", k, l))
    v.append(call("kcs", "E", "nter", "Esc", " or", "Ctrl-]", " leaves"))
    v.append(call("kcs", "Enter", " answer"))
    v.append(call("kcs", "a", "b", "c"))
    v.append(call("kcs"))
    for p in ["", "0", "5", "12.7", "13", "19", "20", "47.5", "100", "120", "-5", ".5", "010"]:
        v.append(call("meter", p))
    for k in [0, 1, 1023, 1024, 1048575, 1048576, 1572864, 99999999, -5]:
        v.append(call("human", k))
    return v


def banner():
    v = []
    for w in ["REVIVE", "", "RIVE"]:
        v.append(call("banner_rows", w))
    v.append(call("big_banner", "REVIVE"))
    v.append(call("big_banner", "VIE"))
    v.append(call("big_banner", ""))
    v.append(call("big_banner", "HELP", b"\x1b[1m\x1b[97m", b"\x1b[1m\x1b[93m", b"\x1b[33m", b"\x1b[91m", b"\x1b[95m"))
    for tick in [0, 1, 7]:
        v.append(call("set", "TICK", tick))
        for w, a, s in [("0", "0", "0"), ("3", "0", "5"), ("0", "2", "5"), ("12", "3", "15"), ("03", "0", "1"), ("100", "0", "100")]:
            v.append(call("monitor", w, a, s))
    # A short history (a panel just opened) fills the right of the graph, padded on the left:
    # 12 samples at widths under, at and over 12, and at the widths a frame gives the graph.
    for hist in [[], [0], [3, 50, 7, 120, 0, 9], list(range(0, 400, 3)), [5, -3, 0, 70], list(range(10, 130, 10))]:
        v.append(call("hist", *hist))
        for w in [0, 1, 5, 11, 12, 13, 40, 52, 120, 172, -2]:
            v.append(call("spark", w))
    return v


def art(sizes, name="art"):
    v = []
    extras = ["1x1", "2x1", "1x5", "7x2", "8x3", "9x4", "20x6", "21x7", "26x3"]
    for t in [0, 1, 7]:
        v.append(call("set", "TICK", t))
        for s in range(5):
            v.append(call("set", "SCENE", s))
            for wh in sizes + extras:
                w, h = wh.split("x")
                v.append(call(name, w, h))
            # Beside the banner, the scene holds still: the width left of IW, 6 rows or 3.
            for iw in [76, 96, 126, 196]:
                for tw, bh in [(iw - 95, 6), (iw - 79, 6), (iw - 90, 3)]:
                    if tw >= 8:
                        v.append(call(name, tw, bh, "still"))
    return v


def locale(d):
    v = []
    for f in [b"%a %H:%M:%S", b"%H:%M:%S", b"%a %b %d %Y", b"", b"%c"]:
        for t in [0, 1795000000, 1700000000, 1719000000]:
            v.append(call("strftime", f, t))
    v.append(call("globdirs", d))
    v.append(call("globdirs", d + b"/none"))
    return v


def main():
    g = sys.argv[1]
    if g == "prims":
        v = prims()
    elif g == "banner":
        v = banner()
    elif g == "art":
        sizes = sys.argv[2].split() if len(sys.argv) > 2 and sys.argv[2].strip() else ["76x10", "40x3", "31x6"]
        v = art(sizes)
    elif g in ("memo", "fresh"):
        # Each scene and size at TICK 1 and straight after at 7, which bash's memo serves from 1's
        # frame for the scenes that only blink: through the memo, then each drawn afresh.
        v = []
        for s in range(5):
            v.append(call("set", "SCENE", s))
            for wh in sys.argv[2].split():
                w, h = wh.split("x")
                for t in [1, 7]:
                    v.append(call("set", "TICK", t))
                    v.append(call("art_memo" if g == "memo" else "art", w, h))
    elif g == "locale":
        v = locale(sys.argv[2].encode("utf-8", "surrogateescape"))
    else:
        sys.exit("calls.py: no group " + g)
    sys.stdout.buffer.write(b"".join(v))


main()

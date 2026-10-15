#!/usr/bin/env python3
"""Compare the vertex-stage inputs (LARECOMP_DUMP_VSUBO / LARECOMP_DUMP_SSBO) of a draw.

Both logs are read for the draws whose fragment fingerprint is FINGERPRINT, in order. The vertex UBO
lines ([vsubo]) and the vertex storage buffer record lines ([ssbo] rec*) that precede each draw are
paired up and compared field by field, so a differing light/bone matrix shows up as a float offset.
"""
import re
import sys


def draws(path, fp):
    out, cur, last = [], [], None
    for ln in open(path, errors="replace"):
        m = re.search(r"\[fshash\] fs=[0-9a-f]+ hash ([0-9a-f]+)", ln)
        if m:
            last = m.group(1)
        u = re.match(r"\[vsubo\] (v\d+) \((\d+)\): (.*)", ln)
        if u:
            cur.append((u.group(1), int(u.group(2)), [float(v) for v in u.group(3).split()]))
        s = re.match(r"\[ssbo\] (rec\d+): (.*)", ln)
        if s:
            cur.append((s.group(1), 0, list(s.group(2).split())))
        if ln.startswith("[draw]") and last == fp:
            out.append(cur)
            cur = []
    return out


def main():
    a, b = sys.argv[1], sys.argv[2]
    fp = sys.argv[3] if len(sys.argv) > 3 else "6804ba6e5340c6f9"
    A, B = draws(a, fp), draws(b, fp)
    print(f"{a}: {len(A)} draws, {b}: {len(B)} draws")
    for i, (x, y) in enumerate(zip(A, B)):
        print(f"--- body draw {i}: {len(x)} vs {len(y)} input groups")
        for (na, sa, va), (nb, sb, vb) in zip(x, y):
            if na == nb and sa == sb and va == vb:
                continue
            print(f"  {na} size {sa}/{sb}")
            if len(va) == len(vb):
                d = [(k, p, q) for k, (p, q) in enumerate(zip(va, vb)) if p != q]
                print(f"    {len(d)} of {len(va)} differ: {[(k, p, q) for k, p, q in d[:8]]}")


main()

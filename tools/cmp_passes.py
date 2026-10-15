#!/usr/bin/env python3
"""Compare two pass-dump trees (build/pass_*.png vs a device copy) pass by pass.

The runtime's debug frame (LARECOMP_DEBUG_FRAME) writes one PNG per render pass, plus the alpha of
each, into build/. Passes are numbered in the order the encoder ends them, so the same frame on two
platforms gives the same numbering as long as the frame's pass sequence is the same - which is the
thing being checked. Prints per pass: size, mean, near-white count, and where the two differ.
"""
import glob
import os
import sys

import numpy as np
from PIL import Image


def stats(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
    return a


def main():
    a_dir, b_dir = sys.argv[1], sys.argv[2]
    names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(a_dir, "pass_*.png")))
    for n in names:
        pa, pb = os.path.join(a_dir, n), os.path.join(b_dir, n)
        if not os.path.exists(pb):
            print(f"{n:18s} missing in {b_dir}")
            continue
        A, B = stats(pa), stats(pb)
        if A.shape != B.shape:
            print(f"{n:18s} SHAPE {A.shape} vs {B.shape}")
            continue
        d = np.abs(A - B).max(axis=2)
        nz = int((d > 8).sum())
        wa = int((A.min(axis=2) > 245).sum())
        wb = int((B.min(axis=2) > 245).sum())
        print(f"{n:18s} {A.shape[1]:5d}x{A.shape[0]:<5d} mean {A.mean():7.2f} / {B.mean():7.2f}"
              f"  white {wa:7d} / {wb:7d}  maxdiff {int(d.max()):3d}  px>8 {nz:8d}"
              + ("   <-- DIFFERS" if nz > 200 else ""))


main()

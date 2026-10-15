#!/usr/bin/env python3
"""Compare one probed register between two platforms.

`LARECOMP_DBG_FS_HASH=<fingerprint>:<pc>:<reg>` makes the chosen shader output that one register as the pixel
value, so the scene-target dump shows it across the object's silhouette (all three channels equal). Run the
same probe with the same pacing on both platforms and pass the two dumps here.

The object is found as the densest 64x64 tile of "lit grey" pixels - equal channels, value >= 3. A whole-image
histogram does not work: naturally grey scene pixels and the black border outnumber the object.

Caveat: the dump goes through an RGBA8 target, so any probed value >= 1.0 clips to 255. Two platforms that both
saturate cannot be told apart - probe the *input* of a suspect operation (a small value) rather than its output.
"""
import sys

import numpy as np
from PIL import Image

TILE = 64


def blob(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
    eq = (a[..., 0] == a[..., 1]) & (a[..., 1] == a[..., 2]) & (a[..., 0] >= 3)
    h, w = eq.shape
    best = (0, 0, 0)
    for y in range(0, h - TILE, TILE):
        for x in range(0, w - TILE, TILE):
            c = int(eq[y:y + TILE, x:x + TILE].sum())
            if c > best[0]:
                best = (c, y, x)
    c, y, x = best
    v = a[y:y + TILE, x:x + TILE, 0][eq[y:y + TILE, x:x + TILE]]
    return c, (x, y), v


def main():
    out = []
    for p in sys.argv[1:3]:
        c, (x, y), v = blob(p)
        bands = [int(((v >= 3) & (v <= 20)).sum()), int(((v > 20) & (v <= 80)).sum()),
                 int(((v > 80) & (v <= 200)).sum()), int((v > 200).sum())]
        sat = 100.0 * bands[3] / max(len(v), 1)
        print(f"{p:36s} tile ({x:4d},{y:4d}) probed {c:5d} mean {v.mean():6.1f} max {v.max():3d} "
              f"3-20/20-80/80-200/>200 {bands} saturated {sat:.0f}%")
        out.append((v, bands))
    if len(out) == 2:
        (va, ba), (vb, bb) = out
        if ba[3] > 0.9 * len(va) and bb[3] > 0.9 * len(vb):
            print("both saturate -> indistinguishable, probe an input instead")


main()

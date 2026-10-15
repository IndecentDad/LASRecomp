#!/usr/bin/env python3
"""Compare a probed register between two platforms.

`LARECOMP_DBG_FS_HASH=<fingerprint>:<pc>:<reg>` makes the chosen shader output that one register as the pixel
value, so the dump of the scene target shows the register across the object's silhouette (all three channels
equal). Run the same probe on both platforms at the same frame and pass the two pass_006 dumps here.
"""
import sys

import numpy as np
from PIL import Image

BOX = (1180, 980, 1560, 1300)  # Link, in the 2732x1537 scene target


def load(p):
    a = np.asarray(Image.open(p).convert("RGB")).astype(np.int16)
    return a


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    ca, cb = a[BOX[1]:BOX[3], BOX[0]:BOX[2]], b[BOX[1]:BOX[3], BOX[0]:BOX[2]]
    gray = lambda c: np.abs(c - c.mean(axis=2, keepdims=True)).max() < 3
    print(f"A {sys.argv[1]}: crop mean {ca.reshape(-1,3).mean(0).round(1)} max {ca.reshape(-1,3).max(0)} "
          f"grayscale {gray(ca).mean():.3f}")
    print(f"B {sys.argv[2]}: crop mean {cb.reshape(-1,3).mean(0).round(1)} max {cb.reshape(-1,3).max(0)} "
          f"grayscale {gray(cb).mean():.3f}")
    # both are register values (grayscale); compare the red channel over the silhouette
    ma = ca[..., 0]
    mb = cb[..., 0]
    both = (ma > 2) | (mb > 2)
    if not both.any():
        print("no probed pixels found in either")
        return
    d = np.abs(ma - mb)[both]
    print(f"pixels probed in either: {int(both.sum())}   differing >2: {int((d > 2).sum())} "
          f"({100.0 * (d > 2).mean():.1f}%)   max diff {int(d.max())}")
    print(f"A mean {ma[both].mean():.1f}   B mean {mb[both].mean():.1f}")


main()

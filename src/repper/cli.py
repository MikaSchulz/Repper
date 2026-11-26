"""Count repetitions in a recording.

    python3 -m repper.cli recordings/leg_press_set1.csv
    python3 -m repper.cli rec.json --fs 60 --min-rep-s 1.0 --verbose
"""

from __future__ import annotations

import argparse

import numpy as np

from .io import load
from .pipeline import detect_reps


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path")
    ap.add_argument("--fs", type=float, default=100.0)
    ap.add_argument("--min-rep-s", type=float, default=0.6)
    ap.add_argument("--prominence-frac", type=float, default=0.30)
    ap.add_argument("--detrend-order", type=int, default=None,
                    help="pin the drift polynomial; default follows the recording's "
                         "length (one degree per 30 s, 2 for anything under a minute)")
    ap.add_argument("--gravity-removed", action="store_true",
                    help="input is userAcceleration-style (no gravity); disables the "
                         "orientation-independent magnitude path")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    t, x, y, z = load(args.path)
    det = detect_reps(t, x, y, z, fs=args.fs, min_rep_s=args.min_rep_s,
                      prominence_frac=args.prominence_frac,
                      detrend_order=args.detrend_order,
                      gravity_removed=args.gravity_removed)
    rate = 1.0 / np.median(np.diff(t)[np.diff(t) > 0])
    print(f"{args.path}: {len(t)} samples, {t[-1]:.1f}s, ~{rate:.0f} Hz recorded, "
          f"detrend order {det.detrend_order}")
    print(det.summary())
    if args.verbose:
        for i, (c, e) in enumerate(zip(det.concentric, det.eccentric), 1):
            print(f"  rep {i:2d}  t={det.rep_times[i-1]:6.2f}s  "
                  f"con {c[1]-c[0]:.2f}s  ecc {e[1]-e[0]:.2f}s")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Validate the detection pipeline against synthetic sets with known ground truth.

Reports precision / recall / F-score for repetition detection and Bland-Altman
limits of agreement for the phase durations, mirroring the metrics reported in
Viecelli et al. 2020 so the numbers are directly comparable.

    python3 scripts/validate_synthetic.py            # default sweep
    python3 scripts/validate_synthetic.py --fs 60    # web-prototype sampling rate
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from repper.pipeline import detect_reps           # noqa: E402
from repper.synth import MACHINE_TIMING, make_set  # noqa: E402


def match(true_t: np.ndarray, det_t: np.ndarray, tol: float):
    """Greedy nearest matching within `tol` seconds -> (tp, fp, fn, errors)."""
    used = np.zeros(len(det_t), dtype=bool)
    tp, errs = 0, []
    for tt in true_t:
        if not len(det_t):
            break
        d = np.abs(det_t - tt)
        d[used] = np.inf
        k = int(np.argmin(d))
        if d[k] <= tol:
            used[k] = True
            tp += 1
            errs.append(det_t[k] - tt)
    return tp, int((~used).sum()), len(true_t) - tp, np.array(errs)


def loa(x: np.ndarray):
    """Bland-Altman: (bias, lower, upper)."""
    if not len(x):
        return 0.0, 0.0, 0.0
    m, s = float(np.mean(x)), float(np.std(x, ddof=1)) if len(x) > 1 else 0.0
    return m, m - 1.96 * s, m + 1.96 * s


def run(fs: float, tempo: float, sets_per_machine: int, seed: int, **kw):
    tp = fp = fn = 0
    rep_err, con_err, ecc_err = [], [], []
    rng = np.random.default_rng(seed)
    for machine in MACHINE_TIMING:
        for _ in range(sets_per_machine):
            s = make_set(machine=machine, reps=10, fs=fs, tempo_scale=tempo,
                         rng=np.random.default_rng(rng.integers(1 << 31)))
            det = detect_reps(s.t, s.ax, s.ay, s.az, fs=fs, **kw)
            a, b, c, e = match(s.rep_times, det.rep_times, tol=0.5 * tempo)
            tp, fp, fn = tp + a, fp + b, fn + c
            rep_err.extend(e)
            n = min(len(det.concentric), len(s.concentric))
            con_err.extend((det.concentric[i][1] - det.concentric[i][0])
                           - (s.concentric[i][1] - s.concentric[i][0]) for i in range(n))
            ecc_err.extend((det.eccentric[i][1] - det.eccentric[i][0])
                           - (s.eccentric[i][1] - s.eccentric[i][0]) for i in range(n))
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    f = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    return dict(tp=tp, fp=fp, fn=fn, precision=prec, recall=rec, f=f,
                rep=loa(np.array(rep_err)), con=loa(np.array(con_err)),
                ecc=loa(np.array(ecc_err)))


def show(label: str, r: dict) -> None:
    print(f"{label:<22} P={r['precision']:.4f} R={r['recall']:.4f} F={r['f']:.4f} "
          f"err={1 - r['f']:.2%}  (tp={r['tp']} fp={r['fp']} fn={r['fn']})")
    for k in ("rep", "con", "ecc"):
        b, lo, hi = r[k]
        print(f"    {k} timing  bias {b:+.3f}s  LoA [{lo:+.2f}, {hi:+.2f}] s")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fs", type=float, default=100.0)
    ap.add_argument("--sets", type=int, default=5, help="sets per machine")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--min-rep-s", type=float, default=0.6)
    ap.add_argument("--prominence-frac", type=float, default=0.30)
    args = ap.parse_args()

    kw = dict(min_rep_s=args.min_rep_s, prominence_frac=args.prominence_frac)
    print(f"9 machines x {args.sets} sets x 10 reps, fs={args.fs:.0f} Hz, "
          f"min_rep_s={args.min_rep_s}, prominence_frac={args.prominence_frac}\n")
    for tempo, label in ((1.0, "self-paced (60% 1RM)"), (0.55, "fast (~1 s/rep)"),
                         (2.5, "slow (~8 s/rep)")):
        show(label, run(args.fs, tempo, args.sets, args.seed, **kw))
        print()


if __name__ == "__main__":
    main()

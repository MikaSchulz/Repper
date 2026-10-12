#!/usr/bin/env python3
"""Evaluate sets exported from the app against the repetition count typed in by hand.

The app writes two files per set: the raw signal (`set_*.csv`) and a summary
(`summary_set_*.csv.json`) holding what each algorithm variant counted plus the true
count. Drop them in a folder (AirDrop lands them in ~/Downloads) and point this at it.

    python3 scripts/evaluate_exports.py ~/Downloads/repper
    python3 scripts/evaluate_exports.py ~/Downloads/repper --sweep

Without --sweep it scores the variants the app already ran. With --sweep it re-runs the
Python detector over the raw signals across a parameter grid and reports which settings
would have matched the truth best — that is the loop that turns gym recordings into
better defaults.
"""

from __future__ import annotations

import argparse
import itertools
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from repper.io import load               # noqa: E402
from repper.pipeline import detect_reps  # noqa: E402


def load_sets(folder: Path) -> list[dict]:
    """Every summary with a raw file next to it and a hand-typed count."""
    out = []
    for summary in sorted(folder.glob("summary_*.json")):
        try:
            record = json.loads(summary.read_text())
        except json.JSONDecodeError:
            print(f"  übersprungen (kein JSON): {summary.name}")
            continue
        raw = folder / record.get("rawFile", "")
        if not raw.exists():
            print(f"  übersprungen (Rohdatei fehlt): {record.get('rawFile')}")
            continue
        record["_raw"] = raw
        out.append(record)
    return out


def score_timing(sets: list[dict]) -> None:
    """Match detected repetitions against the taps, one by one.

    The count alone hides a lot: a detector can be right in total and still have missed
    one repetition and invented another. Matching in time shows that, and the median
    offset says whether the detector is systematically early or late — a tap lands where
    the lifter felt the repetition, the detector marks the peak of the velocity.
    """
    labelled = [s for s in sets if s.get("manualMarks")]
    if not labelled:
        return
    variants = sorted({v for s in labelled for v in s.get("repTimes", {})})
    if not variants:
        return
    print("\nAbgleich gegen die getippten Zeitpunkte (Toleranz 1,5 s)\n")
    print(f"{'Variante':<10} {'Treffer':>8} {'zu viel':>8} {'fehlt':>7} {'Versatz':>10}")
    for v in variants:
        tp = fp = fn = 0
        offsets: list[float] = []
        for s in labelled:
            taps = sorted(float(x) for x in s["manualMarks"])
            found = sorted(float(x) for x in s.get("repTimes", {}).get(v, []))
            used = [False] * len(found)
            for tap in taps:
                best, best_i = 1.5, -1
                for i, f in enumerate(found):
                    if used[i]:
                        continue
                    if abs(f - tap) < best:
                        best, best_i = abs(f - tap), i
                if best_i >= 0:
                    used[best_i] = True
                    tp += 1
                    offsets.append(found[best_i] - tap)
                else:
                    fn += 1
            fp += used.count(False)
        offset = f"{np.median(offsets):+.2f} s" if offsets else "—"
        print(f"{v:<10} {tp:>8} {fp:>8} {fn:>7} {offset:>10}")


def score_phases(sets: list[dict]) -> None:
    """Phase durations from the taps, compared with what the detector reports.

    A tap at the bottom and the next tap at the top bracket the concentric phase; top to
    the following bottom is the eccentric one. Until now those durations had no reference
    at all outside synthetic signals.
    """
    labelled = [s for s in sets if s.get("manualMarks") and s.get("manualBottoms")]
    if not labelled:
        return
    print("\nPhasendauern aus den Tipps (unten -> oben -> unten)\n")
    print(f"{'Satz':<18} {'Wdh.':>5} {'con [s]':>9} {'ecc [s]':>9} "
          f"{'App con':>9} {'App ecc':>9}")
    for s in labelled:
        tops = sorted(float(x) for x in s["manualMarks"])
        bottoms = sorted(float(x) for x in s["manualBottoms"])
        cons, eccs = [], []
        for i, bottom in enumerate(bottoms):
            after_top = [t for t in tops if t > bottom]
            if not after_top:
                continue
            top = after_top[0]
            cons.append(top - bottom)
            next_bottom = [b for b in bottoms[i + 1:] if b > top]
            if next_bottom:
                eccs.append(next_bottom[0] - top)
        if not cons:
            continue
        app_con = s.get("medianCon")
        app_ecc = s.get("medianEcc")
        print(f"{s['date'][:16]:<18} {len(cons):>5} {np.median(cons):>9.2f} "
              f"{np.median(eccs) if eccs else float('nan'):>9.2f} "
              f"{app_con if app_con is not None else float('nan'):>9.2f} "
              f"{app_ecc if app_ecc is not None else float('nan'):>9.2f}")


def score_variants(sets: list[dict]) -> None:
    labelled = [s for s in sets if s.get("trueReps") is not None]
    print(f"\n{len(sets)} Sätze gefunden, davon {len(labelled)} mit eingetragener Wahrheit")
    if not labelled:
        print("Ohne 'Tatsächlich' im Verlauf lässt sich nichts bewerten.")
        return

    variants = sorted({v for s in labelled for v in s["counts"]})
    print(f"\n{'Satz':<18} {'wahr':>5} " + " ".join(f"{v:>6}" for v in variants))
    for s in labelled:
        line = f"{s['date'][:16]:<18} {s['trueReps']:>5} "
        line += " ".join(f"{s['counts'].get(v, 0):>6}" for v in variants)
        print(line)

    print(f"\n{'Variante':<10} {'exakt':>7} {'mittl. Fehler':>15} {'max':>5}")
    for v in variants:
        errs = [s["counts"].get(v, 0) - s["trueReps"] for s in labelled]
        exact = sum(1 for e in errs if e == 0)
        print(f"{v:<10} {exact:>3}/{len(errs):<3} {np.mean(np.abs(errs)):>15.2f} "
              f"{max(abs(e) for e in errs):>5}")


def sweep(sets: list[dict], grid: dict) -> None:
    labelled = [s for s in sets if s.get("trueReps") is not None]
    if not labelled:
        return
    keys = list(grid)
    combos = list(itertools.product(*(grid[k] for k in keys)))
    print(f"\nParametersuche über {len(combos)} Kombinationen "
          f"an {len(labelled)} Sätzen (offline, Python-Pipeline)\n")

    signals = [(s, load(s["_raw"])) for s in labelled]
    results = []
    for combo in combos:
        params = dict(zip(keys, combo))
        errs = []
        for s, (t, x, y, z) in signals:
            det = detect_reps(t, x, y, z, **params)
            errs.append(det.count - s["trueReps"])
        results.append((np.mean(np.abs(errs)), sum(1 for e in errs if e == 0), params, errs))

    results.sort(key=lambda r: (r[0], -r[1]))
    print(f"{'mittl. Fehler':>13} {'exakt':>7}  Parameter")
    for mean_err, exact, params, _ in results[:12]:
        text = ", ".join(f"{k}={v}" for k, v in params.items())
        print(f"{mean_err:>13.2f} {exact:>3}/{len(labelled):<3}  {text}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path)
    ap.add_argument("--sweep", action="store_true",
                    help="Parametersuche über die Rohsignale statt nur der App-Zahlen")
    args = ap.parse_args()

    if not args.folder.is_dir():
        sys.exit(f"kein Ordner: {args.folder}")

    sets = load_sets(args.folder)
    if not sets:
        sys.exit("keine Sätze gefunden (erwartet summary_*.json neben set_*.csv)")

    score_variants(sets)
    score_timing(sets)
    score_phases(sets)
    if args.sweep:
        sweep(sets, {
            "min_rom_frac": [0.0, 0.55, 0.65, 0.75],
            "prominence_frac": [0.20, 0.30, 0.40],
            "min_rep_s": [0.5, 0.6, 0.8],
        })


if __name__ == "__main__":
    main()

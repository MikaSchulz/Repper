#!/usr/bin/env python3
"""Count wrist recordings made with the watch, and score them against the true count.

    python3 scripts/analyze_wrist.py ~/Downloads/repper
    python3 scripts/analyze_wrist.py ~/Downloads/repper --sweep

Each recording is a `wrist_*.csv` with attitude alongside acceleration; the true count
travels in the `summary_*.json` next to it, typed in on the watch after the set.
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

from repper import wrist  # noqa: E402


def collect(folder: Path) -> list[dict]:
    truth: dict[str, dict] = {}
    for summary in folder.glob("summary_*.json"):
        try:
            record = json.loads(summary.read_text())
        except json.JSONDecodeError:
            continue
        truth[record.get("rawFile", "")] = record
    out = []
    for path in sorted(folder.glob("wrist_*.csv")):
        record = truth.get(path.name, {})
        out.append({"path": path, "trueReps": record.get("trueReps"),
                    "machine": record.get("machine")})
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path)
    ap.add_argument("--sweep", action="store_true")
    args = ap.parse_args()

    files = collect(args.folder)
    if not files:
        sys.exit("keine wrist_*.csv gefunden")

    print(f"{'Datei':<28} {'Maschine':<16} {'wahr':>5} {'gezählt':>8} {'Spitzen-v [m/s]':>32}")
    loaded = []
    for f in files:
        t, acc, quat = wrist.load(f["path"])
        det = wrist.detect_reps(t, acc, quat)
        loaded.append((f, (t, acc, quat)))
        speeds = " ".join(f"{v:.2f}" for v in det.peak_speed[:8])
        truth = f["trueReps"] if f["trueReps"] is not None else "—"
        print(f"{f['path'].name[:27]:<28} {str(f['machine'])[:15]:<16} "
              f"{str(truth):>5} {det.count:>8} {speeds:>32}")

    labelled = [(f, d) for f, d in loaded if f["trueReps"] is not None]
    if not labelled:
        print("\nOhne eingetragene Wiederholungszahl lässt sich nichts bewerten.")
        return

    if args.sweep:
        grid = {"min_rom_frac": [0.45, 0.55, 0.65, 0.75],
                "prominence_frac": [0.20, 0.30, 0.40],
                "min_move_s": [0.25, 0.35, 0.5]}
        keys = list(grid)
        print(f"\nParametersuche über {len(list(itertools.product(*grid.values())))} "
              f"Kombinationen an {len(labelled)} Aufnahmen\n")
        rows = []
        for combo in itertools.product(*(grid[k] for k in keys)):
            params = dict(zip(keys, combo))
            errs = [wrist.detect_reps(t, acc, quat, **params).count - f["trueReps"]
                    for f, (t, acc, quat) in labelled]
            rows.append((float(np.mean(np.abs(errs))),
                         sum(1 for e in errs if e == 0), params))
        rows.sort(key=lambda r: (r[0], -r[1]))
        print(f"{'mittl. Fehler':>13} {'exakt':>7}  Parameter")
        for mean_err, exact, params in rows[:10]:
            print(f"{mean_err:>13.2f} {exact:>3}/{len(labelled):<3}  "
                  + ", ".join(f"{k}={v}" for k, v in params.items()))


if __name__ == "__main__":
    main()

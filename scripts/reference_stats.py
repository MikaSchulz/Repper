#!/usr/bin/env python3
"""Cadence statistics from the published datasets -> detector threshold priors.

The shortest repetition in the 2020 dataset sets the ceiling for `min_rep_s`
(the minimum-distance parameter of the peak detector); the tempo strata of the
2021 dataset show how far that has to stretch for deliberately fast sets.
"""

from __future__ import annotations

import csv
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

DATA = Path(__file__).resolve().parents[1] / "data"


def rows(name: str):
    p = DATA / name
    if not p.exists():
        sys.exit(f"missing {p} -- run scripts/fetch_reference.py first")
    with open(p, newline="") as fh:
        yield from csv.DictReader(fh, delimiter="\t")


def num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f > 0 else None


def table(groups: dict, title: str, keyname: str) -> None:
    print(f"\n{title}")
    print(f"{keyname:<20} {'mode':<4} {'n':>5} {'min':>7} {'p05':>7} {'median':>7} {'max':>7}")
    for k in sorted(groups):
        v = sorted(groups[k])
        if not v:
            continue
        print(f"{k[0]:<20} {k[1]:<4} {len(v):>5} {v[0]:>7.0f} "
              f"{v[int(0.05*len(v))]:>7.0f} {st.median(v):>7.0f} {v[-1]:>7.0f}")


def main() -> None:
    g = defaultdict(list)
    for r in rows("2020_main.tab"):
        v = num(r["VideoRaterMean[ms]"])
        if v is not None:
            g[(r["Machine"].strip('"'), r["ContractionModeLevels"].strip('"'))].append(v)
    table(g, "2020 main study - video ground truth, ms (9 machines, 60 % 1RM, self-paced)", "machine")
    reps = [x for k, v in g.items() if k[1] == "Rep" for x in v]
    print(f"\nfastest repetition overall: {min(reps)/1000:.2f} s  "
          f"-> min_rep_s must stay below this")

    g2 = defaultdict(list)
    for r in rows("2021_robustness.tab"):
        v = num(r["RaterMean[ms]"])
        if v is not None:
            g2[(f"tempo {float(r['RepDuration[s]']):.0f} s",
                r["ContractionModeLevel"].strip('"'))].append(v)
    table(g2, "2021 robustness study - video ground truth, ms (Leg Press / Leg Extension, 30 & 80 % 1RM)", "tempo")
    reps2 = [x for k, v in g2.items() if k[1] == "Rep" for x in v]
    print(f"\nfastest repetition overall: {min(reps2)/1000:.2f} s")


if __name__ == "__main__":
    main()

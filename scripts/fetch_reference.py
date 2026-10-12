#!/usr/bin/env python3
"""Download the two published Viecelli et al. datasets from Harvard Dataverse.

Note what these files are: per-contraction-phase DURATIONS from two video raters
and two smartphones. They are analysis results, not raw accelerometer traces --
no acceleration signal was published with either paper. They are useful as a
source of realistic cadence distributions (see scripts/reference_stats.py) and
as the reference the algorithm's own error metrics get compared against.
"""

from __future__ import annotations

import shutil
import urllib.request
from pathlib import Path

DATASETS = {
    "2020_main.tab": ("doi:10.7910/DVN/R3ZKYH", 3754768),
    "2021_robustness.tab": ("doi:10.7910/DVN/A6QHLF", 4210045),
}
BASE = "https://dataverse.harvard.edu/api/access/datafile/"
# Dataverse answers 403 to urllib's default User-Agent
HEADERS = {"User-Agent": "repper/0.1 (+research prototype)"}
OUT = Path(__file__).resolve().parents[1] / "data"


def main() -> None:
    OUT.mkdir(exist_ok=True)
    for name, (doi, file_id) in DATASETS.items():
        dest = OUT / name
        if dest.exists():
            print(f"{name}: present ({dest.stat().st_size} bytes)")
            continue
        print(f"{name}: downloading {doi} ...")
        req = urllib.request.Request(f"{BASE}{file_id}", headers=HEADERS)
        tmp = dest.with_suffix(dest.suffix + ".part")
        with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as fh:
            shutil.copyfileobj(resp, fh)
        tmp.replace(dest)
        print(f"{name}: {dest.stat().st_size} bytes")


if __name__ == "__main__":
    main()

"""Loading recordings produced by the web prototype (or any CSV with t/x/y/z)."""

from __future__ import annotations

import csv
import json
from pathlib import Path

import numpy as np

_ALIASES = {
    "t": ("t", "time", "timestamp", "ts", "t_s", "time_s"),
    "x": ("x", "ax", "accx", "acceleration_x", "gx"),
    "y": ("y", "ay", "accy", "acceleration_y", "gy"),
    "z": ("z", "az", "accz", "acceleration_z", "gz"),
}


def _pick(header: list[str], key: str) -> int:
    low = [h.strip().lower() for h in header]
    for cand in _ALIASES[key]:
        if cand in low:
            return low.index(cand)
    raise KeyError(f"no column for {key!r} in {header}")


def load_csv(path: str | Path):
    """CSV with a header row. Timestamps in seconds, or milliseconds (auto-detected)."""
    with open(path, newline="") as fh:
        rows = list(csv.reader(fh))
    header, body = rows[0], rows[1:]
    ci = {k: _pick(header, k) for k in _ALIASES}
    arr = np.array([[float(r[ci[k]]) for k in ("t", "x", "y", "z")] for r in body if r])
    return _normalize(arr)


def load_json(path: str | Path):
    """JSON as written by the web prototype: {"samples": [[t, x, y, z], ...]}."""
    data = json.loads(Path(path).read_text())
    samples = data["samples"] if isinstance(data, dict) else data
    return _normalize(np.asarray(samples, dtype=float))


def _normalize(arr: np.ndarray):
    t = arr[:, 0]
    span = t[-1] - t[0]
    if span > 3600:  # milliseconds
        t = t / 1000.0
    t = t - t[0]
    return t, arr[:, 1], arr[:, 2], arr[:, 3]


def load(path: str | Path):
    p = Path(path)
    return load_json(p) if p.suffix.lower() == ".json" else load_csv(p)

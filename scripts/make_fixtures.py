#!/usr/bin/env python3
"""Write synthetic recordings + ground truth for the JS parity test."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from repper.pipeline import detect_reps   # noqa: E402
from repper.synth import make_set          # noqa: E402

OUT = ROOT / "test" / "fixtures"
# name, machine, tempo_scale, recording rate, reps
CASES = [
    ("legpress_normal", "LEG PRESS", 1.0, 100.0, 10),
    ("chest_fast", "CHEST PRESS", 0.55, 60.0, 10),
    ("legcurl_slow", "LEG CURL", 2.5, 60.0, 10),
    ("abductor_normal", "ABDUCTOR", 1.0, 60.0, 10),
    ("vertical_traction", "VERTICAL TRACTION", 1.0, 60.0, 12),
    ("lowerback_slow", "LOWER BACK", 2.0, 100.0, 8),
    ("adductor_fast", "ADDUCTOR", 0.6, 100.0, 15),
    ("idle_phone", "LEG PRESS", 1.0, 60.0, 0),   # phone lying on the stack, no set
]

# name -> {rep index: stroke fraction}. Partial repetitions are excluded from the
# ground truth: lifting the stack part of the way and setting it down is not a rep.
PARTIALS = {
    "partial_reps": {2: 0.30, 6: 0.45},
    # lifting the stack into position first, and a last repetition that only makes it
    # half way up: the two cases the counter has to sort out from the set itself
    "setup_and_fade": {0: 0.25, 11: 0.50},
}
CASES.append(("partial_reps", "LEG PRESS", 1.0, 100.0, 10))
CASES.append(("setup_and_fade", "CHEST PRESS", 1.0, 100.0, 12))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    meta = {}
    for i, (name, machine, tempo, fs, reps) in enumerate(CASES):
        s = make_set(machine=machine, reps=reps, fs=fs, tempo_scale=tempo,
                     partials=PARTIALS.get(name), rng=np.random.default_rng(100 + i))
        rows = ["t,x,y,z"] + [f"{t:.5f},{x:.5f},{y:.5f},{z:.5f}"
                              for t, x, y, z in zip(s.t, s.ax, s.ay, s.az)]
        (OUT / f"{name}.csv").write_text("\n".join(rows) + "\n")
        det = detect_reps(s.t, s.ax, s.ay, s.az, fs=100.0)
        legacy = detect_reps(s.t, s.ax, s.ay, s.az, fs=100.0, legacy=True)
        meta[name] = {"machine": machine, "tempo_scale": tempo, "record_hz": fs,
                      "true_reps": s.count, "python_reps": det.count,
                      "python_legacy": legacy.count,
                      "true_times": [round(float(x), 3) for x in s.rep_times]}
        print(f"{name}: true={s.count} python={det.count} legacy={legacy.count} "
              f"({len(s.t)} samples @ {fs:.0f} Hz)")
    (OUT / "expected.json").write_text(json.dumps(meta, indent=2) + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Unit + fixture tests for the Python pipeline.  python3 test/test_pipeline.py"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from repper.io import load                                    # noqa: E402
from repper.pipeline import (GRAVITY, detect_reps, find_peaks,  # noqa: E402
                             hampel, magnitude, resample_uniform)
from repper.synth import make_set                              # noqa: E402

FIX = ROOT / "test" / "fixtures"


class TestBuildingBlocks(unittest.TestCase):
    def test_hampel_replaces_spikes_only(self):
        x = np.ones(200)
        x[50] = 40.0
        out = hampel(x, win=7)
        self.assertAlmostEqual(out[50], 1.0, places=6)
        self.assertTrue(np.allclose(np.delete(out, 50), 1.0))

    def test_resample_drops_duplicate_timestamps(self):
        t = np.array([0.0, 0.01, 0.01, 0.02, 0.03])
        x = np.array([0.0, 1.0, 9.0, 2.0, 3.0])
        tt, xx = resample_uniform(t, x, fs=100.0)
        self.assertTrue(np.all(np.diff(tt) > 0))
        self.assertLess(xx.max(), 9.0)

    def test_peak_prominence_filters_ripple(self):
        t = np.linspace(0, 4 * np.pi, 400)
        x = np.sin(t) + 0.05 * np.sin(20 * t)
        peaks, _ = find_peaks(x, min_distance=10, min_prominence=0.5)
        self.assertEqual(len(peaks), 2)

    def test_magnitude_is_orientation_invariant(self):
        """|specific force| - g recovers the axis acceleration for any phone pose."""
        a_axis = np.array([0.0, 0.5, -0.5, 1.2])
        rng = np.random.default_rng(0)
        for _ in range(5):
            axis = rng.normal(size=3)
            axis /= np.linalg.norm(axis)
            f = (GRAVITY + a_axis)[:, None] * axis[None, :]
            rec = magnitude(f[:, 0], f[:, 1], f[:, 2]) - GRAVITY
            self.assertTrue(np.allclose(rec, a_axis, atol=1e-9))


class TestFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (FIX / "expected.json").exists():
            raise unittest.SkipTest("run scripts/make_fixtures.py first")
        cls.expected = json.loads((FIX / "expected.json").read_text())

    def test_counts_match_ground_truth(self):
        for name, exp in self.expected.items():
            with self.subTest(name):
                t, x, y, z = load(FIX / f"{name}.csv")
                det = detect_reps(t, x, y, z)
                self.assertEqual(det.count, exp["true_reps"])

    def test_idle_recording_counts_nothing(self):
        t, x, y, z = load(FIX / "idle_phone.csv")
        det = detect_reps(t, x, y, z)
        self.assertEqual(det.count, 0)
        self.assertLess(det.snr, 0.5)


class TestPartialRepetitions(unittest.TestCase):
    """Lifting the stack part of the way and setting it back down is not a repetition."""

    def test_partials_are_rejected(self):
        s = make_set(machine="LEG PRESS", reps=10, partials={2: 0.30, 6: 0.45},
                     rng=np.random.default_rng(42))
        self.assertEqual(s.count, 8)                       # ground truth excludes them
        self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az).count, 8)

    def test_gate_off_counts_them(self):
        s = make_set(machine="LEG PRESS", reps=10, partials={2: 0.30, 6: 0.45},
                     rng=np.random.default_rng(42))
        self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az, min_rom_frac=0).count, 10)

    def test_full_range_sets_are_untouched(self):
        for machine in ("CHEST PRESS", "LEG PRESS", "ABDUCTOR"):
            s = make_set(machine=machine, reps=12, rng=np.random.default_rng(9))
            with self.subTest(machine):
                self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az).count, 12)


class TestTempoRobustness(unittest.TestCase):
    def test_all_machines_all_tempos(self):
        from repper.synth import MACHINE_TIMING
        rng = np.random.default_rng(3)
        for tempo in (0.55, 1.0, 2.5):
            errors = 0
            for machine in MACHINE_TIMING:
                s = make_set(machine=machine, reps=10, tempo_scale=tempo,
                             rng=np.random.default_rng(rng.integers(1 << 31)))
                det = detect_reps(s.t, s.ax, s.ay, s.az)
                errors += abs(det.count - s.count)
            with self.subTest(tempo=tempo):
                self.assertEqual(errors, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

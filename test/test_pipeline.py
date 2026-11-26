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
from repper.pipeline import (GRAVITY, auto_detrend_order,       # noqa: E402
                             detect_reps, find_peaks, hampel, magnitude,
                             resample_uniform)
from repper.synth import make_set                              # noqa: E402

FIX = ROOT / "test" / "fixtures"
REAL = ROOT / "test" / "real"


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

    # The two fixtures built from partial repetitions are covered by TestKnownLimits:
    # this detector counts those movements, and the fixture records what it gets.
    TRICK_SETS = {"partial_reps", "setup_and_fade"}

    def test_clean_sets_match_ground_truth(self):
        for name, exp in self.expected.items():
            if name in self.TRICK_SETS:
                continue
            with self.subTest(name):
                t, x, y, z = load(FIX / f"{name}.csv")
                self.assertEqual(detect_reps(t, x, y, z).count, exp["true_reps"])

    def test_counts_stay_what_the_fixtures_recorded(self):
        for name, exp in self.expected.items():
            with self.subTest(name):
                t, x, y, z = load(FIX / f"{name}.csv")
                self.assertEqual(detect_reps(t, x, y, z).count, exp["python_reps"])

    def test_idle_recording_counts_nothing(self):
        t, x, y, z = load(FIX / "idle_phone.csv")
        det = detect_reps(t, x, y, z)
        self.assertEqual(det.count, 0)
        self.assertLess(det.snr, 0.5)


class TestKnownLimits(unittest.TestCase):
    """What this detector does not do, written down rather than left to be rediscovered.

    Every movement that clears the peak detector counts — lifting the stack into the
    starting position counts, and so does a repetition that only makes it half way.
    Telling those apart needs the range of motion of the set, which is what the work on
    the other branches is about.
    """

    def test_partial_repetitions_are_counted_too(self):
        s = make_set(machine="LEG PRESS", reps=10, partials={2: 0.30, 6: 0.45},
                     rng=np.random.default_rng(42))
        self.assertEqual(s.count, 8)                        # two of them are not real
        self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az).count, 10)

    def test_setup_lift_is_counted_too(self):
        s = make_set(machine="LEG PRESS", reps=12, partials={0: 0.25, 11: 0.50},
                     rng=np.random.default_rng(42))
        self.assertEqual(s.count, 10)
        self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az).count, 12)


class TestDriftOverLongSets(unittest.TestCase):
    """A whole set goes into the offline pipeline at once; the live counter sees 60 s.

    Found on a real 189 s set with 52 repetitions: order 2 counted 49, because over three
    minutes the parabola cannot follow the integration drift and the repetitions in the
    last third lose their prominence to the residual slope. The same last third, run
    alone, counted all of its repetitions.
    """

    def test_order_follows_the_length_of_the_recording(self):
        self.assertEqual(auto_detrend_order(8.0), 2)        # short set: as before
        self.assertEqual(auto_detrend_order(59.0), 2)       # live counter's window
        self.assertEqual(auto_detrend_order(60.0), 2)
        self.assertEqual(auto_detrend_order(102.0), 3)
        self.assertEqual(auto_detrend_order(189.0), 6)      # the set that found this
        self.assertEqual(auto_detrend_order(3600.0), 8)     # capped

    def test_pinned_order_is_honoured_and_reported(self):
        s = make_set(machine="LEG PRESS", reps=6, rng=np.random.default_rng(1))
        self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az, detrend_order=5).detrend_order, 5)
        self.assertEqual(detect_reps(s.t, s.ax, s.ay, s.az).detrend_order, 2)

    def test_long_set_with_tilt_drift_still_counts(self):
        """Phone tilting slowly over the set: a baseline the order-2 fit cannot absorb."""
        s = make_set(machine="LEG PRESS", reps=40, rng=np.random.default_rng(7))
        drift = 0.8 * np.sin(2 * np.pi * np.asarray(s.t) / (2.2 * s.t[-1]))
        az = np.asarray(s.az) + drift
        self.assertGreater(s.t[-1], 120.0)                  # long enough for order >= 4
        det = detect_reps(s.t, s.ax, s.ay, az)
        self.assertGreaterEqual(det.detrend_order, 4)
        self.assertEqual(det.count, s.count)


class TestRealRecording(unittest.TestCase):
    """The set that found the drift problem, kept as a recording rather than a story.

    189 s, 52 repetitions, cadence from 1.75 s to 12.25 s, counted by hand during the set
    (`true_times` are the taps). Quantized to 3 decimals and gzipped to keep it at 187 KB;
    the count is unchanged by that, and `TestDriftOverLongSets` covers the mechanism
    synthetically if this file ever has to go.
    """

    @classmethod
    def setUpClass(cls):
        cls.expected = json.loads((REAL / "expected.json").read_text())

    def test_counts_match_what_was_tapped_in(self):
        for name, exp in self.expected.items():
            with self.subTest(name):
                t, x, y, z = load(REAL / f"{name}.csv.gz")
                det = detect_reps(t, x, y, z)
                self.assertEqual(det.detrend_order, exp["python_detrend_order"])
                self.assertEqual(det.count, exp["true_reps"])

    def test_order_two_still_loses_the_last_third(self):
        """The regression itself: pin the old default and the set comes up short."""
        for name, exp in self.expected.items():
            with self.subTest(name):
                t, x, y, z = load(REAL / f"{name}.csv.gz")
                det = detect_reps(t, x, y, z, detrend_order=2)
                self.assertEqual(det.count, exp["python_reps_order2"])
                self.assertLess(det.count, exp["true_reps"])

    def test_repetitions_land_near_the_taps(self):
        """A right total can still be a miss plus an invention; match them in time."""
        for name, exp in self.expected.items():
            with self.subTest(name):
                t, x, y, z = load(REAL / f"{name}.csv.gz")
                found = list(detect_reps(t, x, y, z).rep_times)
                taps = exp["true_times"]
                # the detector marks the velocity peak, the tap lands where the lifter
                # felt the repetition, and this set runs up to 12 s per repetition.
                # 48 of 52 match at 2.5 s (44 at 1.5 s), so the bar leaves two to spare.
                matched = sum(1 for tap in taps
                              if any(abs(f - tap) < 2.5 for f in found))
                self.assertGreaterEqual(matched, int(0.9 * len(taps)))


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

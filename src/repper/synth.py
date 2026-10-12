"""Synthetic weight-stack accelerometer signals with known ground truth.

The published datasets (doi:10.7910/DVN/R3ZKYH, doi:10.7910/DVN/A6QHLF) contain
only per-phase durations, not raw signals, so the algorithm cannot be validated
against real traces at the desk. This module closes that gap: it generates
signals whose phase durations are drawn from the real video-rater distributions
of those datasets, so threshold tuning happens against realistic cadences.

What it does NOT reproduce is real sensor and machine behaviour (cable slack,
stack rattle spectra, body sway). Numbers from here bound the algorithm's
*logic*, not its field accuracy.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .pipeline import GRAVITY

# Median / spread of video-rater phase durations per machine, in seconds,
# computed from doi:10.7910/DVN/R3ZKYH (22 participants, 60 % 1RM, self-paced).
# (con_median, con_p05, ecc_median, ecc_p05)
# Empirical envelope of the same two datasets: nothing outside this was ever
# observed on a real machine, so drawn durations are clamped into it. Without the
# clamp the lognormal tail produces 13 s eccentric phases that no reference set
# contains, and tuning the detector against those is tuning against fiction.
PHASE_LIMITS = {"con": (0.46, 6.36), "ecc": (0.56, 8.97), "rep": (0.84, 11.36)}

MACHINE_TIMING = {
    "ABDUCTOR":          (0.945, 0.56, 1.985, 1.23),
    "ADDUCTOR":          (1.005, 0.67, 1.930, 1.07),
    "CHEST PRESS":       (1.390, 0.87, 2.445, 1.10),
    "LEG CURL":          (1.455, 0.96, 2.530, 1.42),
    "LEG EXTENSION":     (1.170, 0.84, 2.195, 1.22),
    "LEG PRESS":         (1.230, 0.85, 2.170, 1.31),
    "LOWER BACK":        (1.480, 0.98, 2.250, 1.43),
    "TOTAL ABDOMINAL":   (1.330, 0.78, 2.170, 1.17),
    "VERTICAL TRACTION": (1.370, 0.94, 2.460, 1.43),
}


@dataclass
class SyntheticSet:
    t: np.ndarray            # timestamps [s], jittered, possibly duplicated
    ax: np.ndarray
    ay: np.ndarray
    az: np.ndarray           # specific force incl. gravity [m/s^2]
    rep_times: np.ndarray    # true concentric velocity peak of each rep [s]
    concentric: list         # (start, end) [s]
    eccentric: list          # (start, end) [s]

    @property
    def count(self) -> int:
        return len(self.rep_times)


def _half_sine(n: int, amplitude: float) -> np.ndarray:
    return amplitude * np.sin(np.linspace(0.0, np.pi, n, endpoint=False))


def make_set(
    machine: str = "LEG PRESS",
    reps: int = 10,
    fs: float = 100.0,
    stroke_m: float = 0.35,
    noise_sd: float = 0.15,
    bias_drift: float = 0.08,
    pause_s: float = 0.15,
    shocks_per_s: float = 0.2,
    jitter_frac: float = 0.15,
    drop_frac: float = 0.01,
    duplicate_frac: float = 0.005,
    tempo_scale: float = 1.0,
    partials: dict[int, float] | None = None,
    rng: np.random.Generator | None = None,
) -> SyntheticSet:
    """One set of `reps` repetitions on `machine`, with ground truth attached.

    `partials` maps a repetition index (0-based) to the fraction of the full stroke
    that repetition covers, e.g. `{3: 0.35}` for "pushed a third of the way on the
    fourth rep, then set it back down". Partial repetitions are NOT counted in the
    ground truth: they are exactly what the detector is supposed to reject.
    """
    rng = rng or np.random.default_rng(0)
    con_med, con_p05, ecc_med, ecc_p05 = MACHINE_TIMING[machine.upper()]
    # lognormal spread matched so that the 5th percentile lands on the real p05
    con_sigma = max(0.05, np.log(con_med / con_p05) / 1.645)
    ecc_sigma = max(0.05, np.log(ecc_med / ecc_p05) / 1.645)

    v_parts, peaks, con_iv, ecc_iv = [], [], [], []
    clock = 0.0

    lead = int(round(0.8 * fs)) if reps else int(round(20.0 * fs))
    v_parts.append(np.zeros(lead))
    clock += lead / fs

    lo_con, hi_con = PHASE_LIMITS["con"]
    lo_ecc, hi_ecc = PHASE_LIMITS["ecc"]
    lo_rep, hi_rep = PHASE_LIMITS["rep"]

    partials = partials or {}

    for rep_index in range(reps):
        stroke_frac = partials.get(rep_index, 1.0)
        con = float(np.clip(rng.lognormal(np.log(con_med), con_sigma) * tempo_scale, lo_con, hi_con))
        ecc = float(np.clip(rng.lognormal(np.log(ecc_med), ecc_sigma) * tempo_scale, lo_ecc, hi_ecc))
        total = con + ecc
        if total > hi_rep:
            con, ecc = con * hi_rep / total, ecc * hi_rep / total
        elif total < lo_rep:
            con, ecc = con * lo_rep / total, ecc * lo_rep / total
        # a partial repetition covers less distance in less time, at a similar speed
        con *= stroke_frac
        ecc *= stroke_frac
        stroke = stroke_m * stroke_frac
        n_con, n_ecc = max(4, int(round(con * fs))), max(4, int(round(ecc * fs)))
        # equal stroke in both directions: mean(|v|) * duration = stroke
        amp_con = stroke / (2.0 / np.pi) / (n_con / fs)
        amp_ecc = stroke / (2.0 / np.pi) / (n_ecc / fs)

        n_pause = max(0, int(round(pause_s * rng.uniform(0.4, 1.8) * fs)))
        con_start = clock
        v_parts.append(_half_sine(n_con, amp_con))
        if stroke_frac == 1.0:
            peaks.append(con_start + (n_con / 2) / fs)
        clock += n_con / fs
        if stroke_frac == 1.0:
            con_iv.append((con_start, clock))

        v_parts.append(np.zeros(n_pause))
        clock += n_pause / fs

        ecc_start = clock
        v_parts.append(-_half_sine(n_ecc, amp_ecc))
        clock += n_ecc / fs
        if stroke_frac == 1.0:
            ecc_iv.append((ecc_start, clock))

        n_rest = max(0, int(round(rng.uniform(0.0, 0.4) * fs)))
        v_parts.append(np.zeros(n_rest))
        clock += n_rest / fs

    v_parts.append(np.zeros(int(round(0.8 * fs))))
    v = np.concatenate(v_parts)
    n = len(v)
    t = np.arange(n) / fs

    a_axis = np.gradient(v, 1.0 / fs)

    # specific force along the stack axis, rotated into an arbitrary phone pose:
    # |f| == GRAVITY + a_axis for any rotation, which is what the pipeline exploits
    f_mag = GRAVITY + a_axis
    axis = rng.normal(size=3)
    axis /= np.linalg.norm(axis)
    f = f_mag[:, None] * axis[None, :]

    f += rng.normal(0.0, noise_sd, size=f.shape)
    drift = bias_drift * np.column_stack([
        np.linspace(0, rng.normal(), n),
        np.linspace(0, rng.normal(), n),
        np.linspace(0, rng.normal(), n),
    ])
    f += drift

    # stack-impact transients for the Hampel filter to deal with
    shocks = rng.random(n) < shocks_per_s / fs
    f[shocks] += rng.normal(0.0, 8.0, size=(shocks.sum(), 3))

    # sampling reality: timestamp jitter, dropouts, duplicated timestamps
    t = t + rng.normal(0.0, jitter_frac / fs, size=n)
    t = np.maximum.accumulate(t)
    if duplicate_frac > 0:
        dup = rng.random(n) < duplicate_frac
        t[dup] = t[np.clip(np.flatnonzero(dup) - 1, 0, None)]
    keep = rng.random(n) >= drop_frac
    keep[0] = keep[-1] = True

    return SyntheticSet(
        t=t[keep], ax=f[keep, 0], ay=f[keep, 1], az=f[keep, 2],
        rep_times=np.array(peaks), concentric=con_iv, eccentric=ecc_iv,
    )

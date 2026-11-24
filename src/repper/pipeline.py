"""Repetition detection from a smartphone accelerometer on a machine weight stack.

Implements the velocity-domain pipeline described in Viecelli et al. 2020
(PLoS ONE 15(7): e0235156), adapted for iOS sampling rates (~60-100 Hz).

Pure numpy, no scipy dependency.

Signal convention
-----------------
The pipeline expects RAW acceleration INCLUDING gravity (the accelerometer's
specific force). The vector magnitude of that signal minus the gravity offset
recovers the signed acceleration along the stack axis, which is what makes the
method orientation-independent:

    f = a_device - g_vec  ->  |f| = g + a_axis   (a_axis collinear with gravity)

Feeding gravity-free acceleration (Core Motion's `userAcceleration`,
DeviceMotionEvent's `acceleration`) into the magnitude step destroys the sign of
the movement direction, and the integral then ramps monotonically instead of
oscillating. Use `accelerationIncludingGravity` / `CMAccelerometerData`.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

GRAVITY = 9.80665


# --------------------------------------------------------------------------
# Step 1-4: conditioning
# --------------------------------------------------------------------------

def magnitude(ax, ay, az) -> np.ndarray:
    """Vector length over all three axes -> phone orientation no longer matters."""
    a = np.asarray(np.column_stack([ax, ay, az]), dtype=float)
    return np.sqrt((a ** 2).sum(axis=1))


def _rolling_view(x: np.ndarray, win: int) -> np.ndarray:
    pad = win // 2
    padded = np.pad(x, (pad, pad), mode="edge")
    return np.lib.stride_tricks.sliding_window_view(padded, win)[: len(x)]


def hampel(x: np.ndarray, win: int = 11, n_sigma: float = 3.0) -> np.ndarray:
    """Robust outlier removal: replace samples > n_sigma robust-SD from the rolling median."""
    win = max(3, win | 1)  # odd
    w = _rolling_view(np.asarray(x, dtype=float), win)
    med = np.median(w, axis=1)
    mad = np.median(np.abs(w - med[:, None]), axis=1)
    sigma = 1.4826 * mad
    out = np.array(x, dtype=float, copy=True)
    dev = np.abs(out - med)
    # sigma == 0 means the whole window is identical: any deviation is an outlier
    bad = np.where(sigma > 0, dev > n_sigma * sigma, dev > 0)
    out[bad] = med[bad]
    return out


def resample_uniform(t: np.ndarray, x: np.ndarray, fs: float):
    """Drop non-unique/non-monotonic timestamps, then interpolate onto an equidistant grid.

    `t` in seconds. Returns (t_uniform, x_uniform).
    """
    t = np.asarray(t, dtype=float)
    x = np.asarray(x, dtype=float)
    order = np.argsort(t, kind="stable")
    t, x = t[order], x[order]
    keep = np.concatenate([[True], np.diff(t) > 0])
    t, x = t[keep], x[keep]
    if len(t) < 2:
        raise ValueError("need at least two distinct timestamps")
    grid = np.arange(t[0], t[-1], 1.0 / fs)
    return grid, np.interp(grid, t, x)


def remove_gravity(mag: np.ndarray, fs: float, baseline_s: float | None = None) -> np.ndarray:
    """Subtract the gravity offset from the magnitude signal.

    Default is a constant robust offset (the median): drift is dealt with later,
    in the velocity domain, by the polynomial fit. A moving-average baseline is
    available via `baseline_s` for very long sets with real tilt change, but it
    is a high-pass filter -- at `baseline_s=4` it eats slow repetitions
    (8 s/rep sets lose ~37 % F-score to ripple-induced false peaks), so keep the
    window at 15 s or more if you use it at all.
    """
    if baseline_s is None:
        return mag - np.median(mag)
    win = max(3, int(round(baseline_s * fs)) | 1)
    if win >= len(mag):
        return mag - np.median(mag)
    return mag - moving_average(mag, win)


# --------------------------------------------------------------------------
# Step 5-7: velocity domain
# --------------------------------------------------------------------------

def integrate(a: np.ndarray, fs: float) -> np.ndarray:
    """Cumulative trapezoidal integration -> velocity (arbitrary units, drifting)."""
    dt = 1.0 / fs
    v = np.concatenate([[0.0], np.cumsum((a[1:] + a[:-1]) * 0.5 * dt)])
    return v


def detrend_poly(v: np.ndarray, order: int = 3) -> np.ndarray:
    """Polynomial fit over the integrated signal, subtracted -> drift compensation."""
    n = len(v)
    if n <= order + 1:
        return v - v.mean()
    idx = np.linspace(-1.0, 1.0, n)
    coef = np.polyfit(idx, v, order)
    return v - np.polyval(coef, idx)


def moving_average(x: np.ndarray, win: int) -> np.ndarray:
    win = max(1, int(win))
    if win <= 1:
        return np.asarray(x, dtype=float)
    pad = win // 2
    padded = np.pad(np.asarray(x, dtype=float), (pad, win - 1 - pad), mode="edge")
    kernel = np.ones(win) / win
    return np.convolve(padded, kernel, mode="valid")


# --------------------------------------------------------------------------
# Step 8: peak detection (scipy-free, distance + prominence)
# --------------------------------------------------------------------------

def _local_maxima(x: np.ndarray) -> np.ndarray:
    """Indices of local maxima, plateau-aware (returns the plateau midpoint)."""
    peaks = []
    n = len(x)
    i = 1
    while i < n - 1:
        if x[i] > x[i - 1]:
            j = i
            while j < n - 1 and x[j + 1] == x[i]:
                j += 1
            if j < n - 1 and x[j + 1] < x[i]:
                peaks.append((i + j) // 2)
            i = j + 1
        else:
            i += 1
    return np.array(peaks, dtype=int)


def _prominences(x: np.ndarray, peaks: np.ndarray) -> np.ndarray:
    """Topographic prominence of each peak (same definition as scipy.signal)."""
    prom = np.empty(len(peaks), dtype=float)
    for k, p in enumerate(peaks):
        height = x[p]
        i = p
        left_min = height
        while i > 0 and x[i] <= height:
            i -= 1
            left_min = min(left_min, x[i])
        i = p
        right_min = height
        while i < len(x) - 1 and x[i] <= height:
            i += 1
            right_min = min(right_min, x[i])
        prom[k] = height - max(left_min, right_min)
    return prom


def find_peaks(x: np.ndarray, min_distance: int = 1, min_prominence: float = 0.0):
    """Return (indices, prominences), highest-first greedy distance filtering."""
    peaks = _local_maxima(np.asarray(x, dtype=float))
    if len(peaks) == 0:
        return np.array([], dtype=int), np.array([])
    prom = _prominences(x, peaks)
    keep_mask = prom >= min_prominence
    peaks, prom = peaks[keep_mask], prom[keep_mask]
    if len(peaks) == 0:
        return peaks, prom
    order = np.argsort(x[peaks])[::-1]
    kept = []
    for idx in order:
        p = peaks[idx]
        if all(abs(p - peaks[k]) >= min_distance for k in kept):
            kept.append(idx)
    kept = np.array(sorted(kept, key=lambda k: peaks[k]), dtype=int)
    return peaks[kept], prom[kept]


# --------------------------------------------------------------------------
# Step 9: contraction phases from zero crossings
# --------------------------------------------------------------------------

def _zero_crossings(v: np.ndarray):
    """Indices i where the sign changes between i and i+1."""
    s = np.sign(v)
    s[s == 0] = 1
    return np.flatnonzero(np.diff(s) != 0)


@dataclass
class RepDetection:
    fs: float
    t: np.ndarray                       # uniform time grid [s]
    accel: np.ndarray                   # conditioned acceleration [m/s^2]
    velocity: np.ndarray                # detrended, smoothed velocity [m/s]
    peaks: np.ndarray                   # sample index of each concentric peak
    prominences: np.ndarray
    snr: float = float("inf")           # movement band vs. noise; low = nothing happened
    concentric: list = field(default_factory=list)   # (t_start, t_end) per rep [s]
    eccentric: list = field(default_factory=list)    # (t_start, t_end) per rep [s]

    @property
    def count(self) -> int:
        return len(self.peaks)

    @property
    def rep_times(self) -> np.ndarray:
        return self.t[self.peaks]

    @property
    def tut(self) -> float:
        """Time under tension: first concentric start to last eccentric end [s]."""
        if not self.concentric or not self.eccentric:
            return 0.0
        return self.eccentric[-1][1] - self.concentric[0][0]

    def summary(self) -> str:
        con = [b - a for a, b in self.concentric]
        ecc = [b - a for a, b in self.eccentric]
        lines = [f"reps={self.count}  TUT={self.tut:.1f}s"]
        if con:
            lines.append(f"  con median {np.median(con):.2f}s  ecc median {np.median(ecc):.2f}s")
        return "\n".join(lines)


def detect_reps(
    t,
    ax,
    ay,
    az,
    fs: float = 100.0,
    min_rep_s: float = 0.6,
    prominence_frac: float = 0.30,
    smooth_s: float = 0.25,
    hampel_s: float = 0.10,
    baseline_s: float | None = None,
    detrend_order: int = 3,
    min_snr: float = 0.5,
    gravity_removed: bool = False,
) -> RepDetection:
    """Full pipeline: raw tri-axial acceleration -> repetition count and phases.

    Parameters
    ----------
    t : timestamps in seconds (may be jittery / non-equidistant)
    ax, ay, az : acceleration INCLUDING gravity, m/s^2 (see module docstring)
    fs : target resampling rate
    min_rep_s : minimum time between two repetitions. Video ground truth puts the
        fastest observed repetition at 1.44 s in the 2020 study (9 machines,
        60 % 1RM, self-paced) and at 0.84 s in the 2021 tempo study (deliberately
        fast cadence). 0.6 s keeps a margin below the fastest real repetition.
    prominence_frac : peak prominence threshold as a fraction of the 90th
        percentile of |velocity|. Scale-free, so it survives different machines
        and loads without recalibration.
    gravity_removed : set True only if you must feed `userAcceleration`-style
        data. The axis with the largest excursion is then used instead of the
        vector magnitude, because the magnitude of a gravity-free vector has no
        sign. Orientation independence is lost in that mode.
    """
    t = np.asarray(t, dtype=float)

    if gravity_removed:
        a = np.column_stack([np.asarray(v, dtype=float) for v in (ax, ay, az)])
        dominant = int(np.argmax(a.std(axis=0)))
        raw = a[:, dominant]
    else:
        raw = magnitude(ax, ay, az)

    raw = hampel(raw, win=max(3, int(round(hampel_s * _median_rate(t)))))
    tt, sig = resample_uniform(t, raw, fs)
    accel = remove_gravity(sig, fs, baseline_s=baseline_s) if not gravity_removed else sig - sig.mean()

    v = integrate(accel, fs)
    v = detrend_poly(v, order=detrend_order)
    v = moving_average(v, max(1, int(round(smooth_s * fs))))

    band = moving_average(accel, max(1, int(round(0.3 * fs))))
    resid = accel - band
    snr = float(band.std() / resid.std()) if resid.std() > 0 else np.inf

    if snr < min_snr:
        peaks, prom = np.array([], dtype=int), np.array([])
    else:
        scale = np.percentile(np.abs(v), 90)
        peaks, prom = find_peaks(
            v,
            min_distance=max(1, int(round(min_rep_s * fs))),
            min_prominence=prominence_frac * scale if scale > 0 else 0.0,
        )

    det = RepDetection(fs=fs, t=tt, accel=accel, velocity=v, peaks=peaks,
                       prominences=prom, snr=snr)
    _assign_phases(det)
    return det


def _median_rate(t: np.ndarray) -> float:
    d = np.diff(np.asarray(t, dtype=float))
    d = d[d > 0]
    return 1.0 / np.median(d) if len(d) else 100.0


def _assign_phases(det: RepDetection) -> None:
    """Concentric = positive lobe around each peak, eccentric = following negative lobe."""
    v, t = det.velocity, det.t
    zc = _zero_crossings(v)
    for p in det.peaks:
        before = zc[zc < p]
        after = zc[zc > p]
        c_start = t[before[-1]] if len(before) else t[0]
        c_end = t[after[0]] if len(after) else t[-1]
        e_start = c_end
        e_end = t[after[1]] if len(after) > 1 else t[-1]
        det.concentric.append((float(c_start), float(c_end)))
        det.eccentric.append((float(e_start), float(e_end)))

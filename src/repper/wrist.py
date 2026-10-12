"""Counting from a wrist-worn device: world frame, then speed.

The stack detector rests on the movement running along gravity — `|f| - g` recovers the
axis acceleration only then. At the wrist that assumption breaks as soon as the movement
tilts away from vertical: for a horizontal movement `|f| = sqrt(g^2 + a^2) ~ g + a^2/2g`,
which is the signal squared, rectified and shrunk by a factor of twenty.

What survives instead:

1. take the gravity-free acceleration **and the attitude** the device reports
2. rotate the acceleration into the reference frame, so "up" stays up however the wrist
   is turned
3. integrate per axis into a 3-D velocity, remove the drift of each axis
4. work with the magnitude of that velocity — the speed

Speed has no sign, so one repetition shows up as two humps, out and back. They are paired
again through the direction of the velocity vector: two consecutive humps pointing against
each other are one repetition.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .pipeline import (classify_by_travel, detrend_poly, find_peaks, hampel, integrate,
                       moving_average, resample_uniform)

COLUMNS = ["t", "ax", "ay", "az", "qw", "qx", "qy", "qz", "rx", "ry", "rz"]


@dataclass
class WristDetection:
    t: np.ndarray                 # uniform time grid [s]
    velocity: np.ndarray          # world-frame velocity, N x 3 [m/s]
    speed: np.ndarray             # |velocity| [m/s]
    humps: np.ndarray             # sample index of every movement kept
    reps: np.ndarray              # time of each counted repetition [s]
    peak_speed: np.ndarray        # top speed of each repetition [m/s]

    @property
    def count(self) -> int:
        return len(self.reps)


def load(path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Read a recording written by the watch: (t, acceleration N x 3, quaternion N x 4)."""
    raw = np.genfromtxt(path, delimiter=",", names=True)
    missing = [c for c in COLUMNS[:8] if c not in (raw.dtype.names or ())]
    if missing:
        raise ValueError(f"Spalten fehlen: {missing}")
    t = np.asarray(raw["t"], dtype=float)
    acc = np.column_stack([raw["ax"], raw["ay"], raw["az"]]).astype(float)
    quat = np.column_stack([raw["qw"], raw["qx"], raw["qy"], raw["qz"]]).astype(float)
    return t, acc, quat


def rotation_matrices(quat: np.ndarray) -> np.ndarray:
    """Quaternions (w, x, y, z) to rotation matrices that map device -> reference frame."""
    q = quat / (np.linalg.norm(quat, axis=1, keepdims=True) + 1e-12)
    w, x, y, z = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    r = np.empty((len(q), 3, 3))
    r[:, 0, 0] = 1 - 2 * (y * y + z * z)
    r[:, 0, 1] = 2 * (x * y - z * w)
    r[:, 0, 2] = 2 * (x * z + y * w)
    r[:, 1, 0] = 2 * (x * y + z * w)
    r[:, 1, 1] = 1 - 2 * (x * x + z * z)
    r[:, 1, 2] = 2 * (y * z - x * w)
    r[:, 2, 0] = 2 * (x * z - y * w)
    r[:, 2, 1] = 2 * (y * z + x * w)
    r[:, 2, 2] = 1 - 2 * (x * x + y * y)
    return r


def world_velocity(t: np.ndarray, acc: np.ndarray, quat: np.ndarray, fs: float = 100.0):
    """Acceleration in the device frame plus attitude -> velocity in the reference frame."""
    rot = rotation_matrices(quat)
    world = np.einsum("nij,nj->ni", rot, acc)
    grid = None
    axes = []
    for k in range(3):
        cleaned = hampel(world[:, k], win=11)
        grid, resampled = resample_uniform(t, cleaned, fs)
        v = detrend_poly(integrate(resampled, fs), 3)
        axes.append(moving_average(v, max(1, int(0.25 * fs))))
    return grid, np.column_stack(axes)


def detect_reps(t, acc, quat, fs: float = 100.0, min_move_s: float = 0.35,
                prominence_frac: float = 0.30, min_rom_frac: float = 0.65,
                pair_cos: float = -0.3) -> WristDetection:
    """Count repetitions from a wrist recording.

    min_rom_frac works exactly as on the stack: the distance covered by a movement,
    measured against the median of the set, so a twitch never counts and the scale comes
    from the exercise being done rather than from a constant.
    """
    grid, vel = world_velocity(t, acc, quat, fs)
    speed = np.linalg.norm(vel, axis=1)
    empty = np.array([], dtype=int)
    if len(speed) < int(2 * fs):
        return WristDetection(grid, vel, speed, empty, np.array([]), np.array([]))

    scale = float(np.percentile(speed, 90))
    peaks, _ = find_peaks(speed, min_distance=max(1, int(min_move_s * fs)),
                          min_prominence=prominence_frac * scale)
    if len(peaks) < 2:
        return WristDetection(grid, vel, speed, empty, np.array([]), np.array([]))

    # distance covered per movement: the range of motion, in metres along the path
    travels = []
    for p in peaks:
        floor = 0.25 * speed[p]
        a = b = int(p)
        while a > 0 and speed[a] > floor:
            a -= 1
        while b < len(speed) - 1 and speed[b] > floor:
            b += 1
        travels.append(float(np.trapezoid(speed[a:b + 1], dx=1 / fs)))
    keep = classify_by_travel(np.array(travels), min_rom_frac)
    humps = peaks[keep]
    if len(humps) < 2:
        return WristDetection(grid, vel, speed, humps, np.array([]), np.array([]))

    # out and back belong together: consecutive humps pointing against each other
    direction = vel[humps] / (np.linalg.norm(vel[humps], axis=1, keepdims=True) + 1e-9)
    reps, tops = [], []
    used = np.zeros(len(humps), dtype=bool)
    for i in range(len(humps) - 1):
        if used[i]:
            continue
        if float(direction[i] @ direction[i + 1]) < pair_cos:
            reps.append(float(grid[humps[i]]))
            tops.append(float(speed[humps[i]]))
            used[i] = used[i + 1] = True
    return WristDetection(grid, vel, speed, humps, np.array(reps), np.array(tops))

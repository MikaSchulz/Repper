#!/usr/bin/env python3
"""Does the counter survive at the wrist, and does a speed-based approach do better?

Simulates a curl-like movement: the hand travels on an arc around the elbow while the
forearm — and with it the watch — rotates through the same angle. That breaks the
assumption the stack-based counter rests on (one fixed axis, aligned with gravity).

Two detectors are compared:

  current   |a| - g on the raw signal, the pipeline that counts on the weight stack
  world     rotate the gravity-free acceleration into the world frame with the attitude,
            integrate to a 3-D velocity, and work with its magnitude — the "just use
            speed" idea

    python3 scripts/wrist_prototype.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from repper.pipeline import (GRAVITY, classify_by_travel, detect_reps,  # noqa: E402
                             detrend_poly, find_peaks, hampel, integrate,
                             moving_average)

FS = 100.0


def rotation_y(angle: np.ndarray) -> np.ndarray:
    """Stack of rotations about the y axis, one per sample."""
    c, s = np.cos(angle), np.sin(angle)
    r = np.zeros((len(angle), 3, 3))
    r[:, 0, 0] = c
    r[:, 0, 2] = s
    r[:, 1, 1] = 1
    r[:, 2, 0] = -s
    r[:, 2, 2] = c
    return r


def make_wrist_set(reps: int = 10, radius: float = 0.32, sweep_deg: float = 95.0,
                   partials: dict[int, float] | None = None, tilt_deg: float = 0.0,
                   noise: float = 0.12, rng=None):
    """Hand on an arc, watch rotating with the forearm.

    `tilt_deg` tilts the plane the arc lies in: 0 is a curl, straight up and down against
    gravity; 90 is a movement in the horizontal plane, where nothing happens along the
    gravity axis at all. That angle is the interesting variable — not the rotation of the
    watch, which the magnitude of the acceleration is blind to anyway.

    Returns the raw signal a stack counter would see, the gravity-free acceleration and
    attitude a watch reports, and the true repetition times.
    """
    rng = rng or np.random.default_rng(0)
    partials = partials or {}
    angle = [np.zeros(int(0.8 * FS))]
    peaks: list[float] = []
    clock = 0.8

    for i in range(reps):
        frac = partials.get(i, 1.0)
        con = float(np.clip(rng.normal(1.3, 0.2), 0.7, 3.0)) * frac
        ecc = float(np.clip(rng.normal(2.0, 0.3), 0.9, 4.0)) * frac
        sweep = np.deg2rad(sweep_deg) * frac
        n_con, n_ecc = int(con * FS), int(ecc * FS)
        up = sweep * 0.5 * (1 - np.cos(np.linspace(0, np.pi, n_con)))
        down = sweep * 0.5 * (1 + np.cos(np.linspace(0, np.pi, n_ecc)))
        pause = np.full(int(0.15 * FS), sweep)
        rest = np.zeros(int(rng.uniform(0.2, 0.5) * FS))
        angle += [up, pause, down, rest]
        if frac == 1.0:
            peaks.append(clock + con / 2)
        clock += (n_con + len(pause) + n_ecc + len(rest)) / FS

    angle += [np.zeros(int(1.0 * FS))]
    theta = np.concatenate(angle)
    n = len(theta)
    t = np.arange(n) / FS

    # hand position on the arc, in the world frame, in a plane tilted away from vertical
    tilt = np.deg2rad(tilt_deg)
    along = radius * np.sin(theta)
    lift = -radius * np.cos(theta)
    pos = np.column_stack([along,
                           lift * np.sin(tilt),
                           lift * np.cos(tilt)])
    accel_world = np.gradient(np.gradient(pos, 1 / FS, axis=0), 1 / FS, axis=0)

    # the watch rotates with the forearm, plus a slow twist of the wrist
    twist = 0.25 * np.sin(2 * np.pi * t / 7.0)
    rot = rotation_y(theta + twist)                     # device -> world

    # what the sensors report, in the device frame
    user_device = np.einsum("nji,nj->ni", rot, accel_world)          # R^T a_world
    gravity_world = np.array([0.0, 0.0, GRAVITY])
    raw_device = np.einsum("nji,nj->ni", rot, accel_world + gravity_world)

    user_device += rng.normal(0, noise, user_device.shape)
    raw_device += rng.normal(0, noise, raw_device.shape)
    return t, raw_device, user_device, rot, np.array(peaks)


def speed_counter(t, user_device, rot, min_rom_frac: float = 0.65):
    """The 'just use speed' detector.

    Rotate into the world frame, integrate to velocity, then work with the magnitude of
    that velocity. Direction no longer matters, which is the whole point at the wrist —
    but each repetition now shows up as *two* speed humps, up and down, so they have to
    be paired again.
    """
    world = np.einsum("nij,nj->ni", rot, user_device)     # R a_device
    vel = np.column_stack([
        moving_average(detrend_poly(integrate(hampel(world[:, k], win=11), FS), 3),
                       int(0.25 * FS))
        for k in range(3)
    ])
    speed = np.linalg.norm(vel, axis=1)

    peaks, _ = find_peaks(speed, min_distance=int(0.35 * FS),
                          min_prominence=0.30 * np.percentile(speed, 90))
    if len(peaks) < 2:
        return np.array([]), speed, vel

    # distance covered around each hump: that is the range of motion, and it is what
    # separates a repetition from a twitch
    travels = []
    for p in peaks:
        a, b = p, p
        floor = 0.25 * speed[p]
        while a > 0 and speed[a] > floor:
            a -= 1
        while b < len(speed) - 1 and speed[b] > floor:
            b += 1
        travels.append(np.trapezoid(speed[a:b + 1], dx=1 / FS))
    travels = np.array(travels)
    keep = classify_by_travel(travels, min_rom_frac)
    humps = peaks[keep]

    # up and down of one repetition: pair consecutive humps, count the pairs
    direction = vel[humps] / (np.linalg.norm(vel[humps], axis=1, keepdims=True) + 1e-9)
    reps = []
    used = np.zeros(len(humps), dtype=bool)
    for i in range(len(humps) - 1):
        if used[i]:
            continue
        if float(direction[i] @ direction[i + 1]) < -0.3:      # opposite directions
            reps.append(t[humps[i]])
            used[i] = used[i + 1] = True
    return np.array(reps), speed, vel


def match(true_t, det_t, tol=0.8):
    used = np.zeros(len(det_t), dtype=bool)
    tp = 0
    for tt in true_t:
        if not len(det_t):
            break
        d = np.abs(det_t - tt)
        d[used] = np.inf
        k = int(np.argmin(d))
        if d[k] <= tol:
            used[k] = True
            tp += 1
    return tp, int((~used).sum()), len(true_t) - tp


def main() -> None:
    print("Handgelenk-Simulation: Arm auf Kreisbahn, Uhr dreht mit\n")
    print(f"{'Fall':<34} {'wahr':>5} {'Stack-Zähler':>14} {'Speed-Zähler':>14}")
    cases = [
        ("senkrecht (Curl)", 0.0, {}, 10),
        ("45 Grad schräg", 45.0, {}, 10),
        ("75 Grad schräg", 75.0, {}, 10),
        ("waagerecht (z. B. Fly)", 90.0, {}, 10),
        ("waagerecht + 2 Teilwdh.", 90.0, {3: 0.4, 7: 0.45}, 8),
    ]
    for i, (name, tilt, partials, truth) in enumerate(cases):
        t, raw, user, rot, true_t = make_wrist_set(
            reps=10, tilt_deg=tilt, partials=partials, rng=np.random.default_rng(5 + i))
        stack = detect_reps(t, raw[:, 0], raw[:, 1], raw[:, 2], fs=FS)
        reps, _, _ = speed_counter(t, user, rot)
        print(f"{name:<34} {truth:>5} {stack.count:>14} {len(reps):>14}")

    # what falls out on the side: peak speed per repetition, i.e. loss of force
    t, raw, user, rot, true_t = make_wrist_set(reps=10, rng=np.random.default_rng(3))
    reps, speed, _ = speed_counter(t, user, rot)
    peaks_per_rep = [speed[np.argmin(np.abs(t - r)):
                           np.argmin(np.abs(t - r)) + int(0.6 * FS)].max() for r in reps]
    print("\nSpitzengeschwindigkeit je Wiederholung [m/s]:",
          " ".join(f"{v:.2f}" for v in peaks_per_rep))


if __name__ == "__main__":
    main()

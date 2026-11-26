# Real recordings with hand-tapped ground truth

Ten sets recorded with the app on 24 and 26 November 2026, phone held upright and moved
up and down by hand at varying tempo. Every set carries a tap at the top and at the
bottom of each repetition, put in while moving: 230 marked repetitions in all.

These are the first recordings in this project that are neither synthetic nor
out-of-domain. Everything before them was generated from the published phase-duration
tables, which is circular — tuning a detector against a generator measures the
generator. A threshold that survives these files has met something the generator did
not produce.

## Files

`index.json` holds one record per set: what the detector counted (`count`), the
repetition times it committed (`repTimes`), the taps (`manualMarks` at the top,
`manualBottoms` at the bottom), and `trueReps`, which follows the top taps. Each record
names its raw signal in `rawFile`.

The CSVs are `t,x,y,z` — raw accelerometer including gravity, in m/s², at 100 Hz, with
timestamps relative to the first sample of that recording.

## What they show

| recorded | truth | counted | cadence | length | label |
|---|---|---|---|---|---|
| 11-24 09:58 | 3 | 3 | 1.4 s | 8 s | — |
| 11-24 10:26 | 4 | 4 | 2.0 s | 9 s | — |
| 11-24 10:30 | 48 | 48 | 2.0 s | 102 s | Handy hochkant, hoch und run |
| 11-24 10:32 | 4 | 4 | 2.0 s | 9 s | Handy hochkant, hoch und run |
| 11-24 10:33 | 5 | 5 | 4.5 s | 22 s | Handy hochkant, hoch und run |
| 11-26 16:36 | 22 | 22 | 2.5 s | 69 s | Handy hochkant, hoch und run |
| 11-26 16:40 | 52 | 53 | 2.7 s | 189 s | Handy hochkant, hoch und run |
| 11-26 17:24 | 54 | 54 | 2.3 s | 211 s | Handy hochkant, hoch und run |
| 11-26 17:25 | 13 | **30** | 5.6 s | 72 s | Handy hochkant, hoch und run |
| 11-26 17:26 | 25 | 25 | 2.4 s | 72 s | Handy hochkant, hoch und run |
| 11-26 17:44 | 8 | **15** | 6.5 s | 50 s | Langsam und kurz |
| 11-26 17:47 | 23 | **28** | 5.2 s | 123 s | Langsam und lang |
| 11-26 17:49 | 13 | **50** | 8.0 s | 110 s | Sehr langsam und lang |

Every failure is a slow set, and only a slow set. The three recorded last are
deliberate: same tempo above and below the 60 s analysis window, to separate slowness
from the window. Both break, so it is the tempo.

The mechanism, measured on the 8 s set: 47 peaks for 13 repetitions, median peak spacing
1.85 s against a true cadence of 8.0 s, two to six peaks inside a single repetition. A
slow repetition has a broad, flat velocity lobe, and the ripples on it clear a minimum
spacing that sits at 0.6 s.

What does survive on these recordings is the sign of the velocity: 27 zero crossings for
13 repetitions, almost exactly two each. The ripples ride on one flank without crossing
zero. Cadence read from zero crossings lands within 10 % on every failing set, while the
peak count is out by two to four times -- which is what any fix here should be built on,
not on the peaks it is trying to correct.

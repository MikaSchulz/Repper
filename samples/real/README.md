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
| 11-24 10:30 | 48 | 48 | 2.0 s | 102 s | Handy hochkant, hoch und r |
| 11-24 10:32 | 4 | 4 | 2.0 s | 9 s | Handy hochkant, hoch und r |
| 11-24 10:33 | 5 | 5 | 4.5 s | 22 s | Handy hochkant, hoch und r |
| 11-26 16:36 | 22 | 22 | 2.5 s | 69 s | Handy hochkant, hoch und r |
| 11-26 16:40 | 52 | 53 | 2.7 s | 189 s | Handy hochkant, hoch und r |
| 11-26 17:24 | 54 | 54 | 2.3 s | 211 s | Handy hochkant, hoch und r |
| 11-26 17:25 | 13 | **30** | 5.6 s | 72 s | Handy hochkant, hoch und r |
| 11-26 17:26 | 25 | 25 | 2.4 s | 72 s | Handy hochkant, hoch und r |
| 11-26 17:44 | 8 | **15** | 6.5 s | 50 s | Langsam und kurz |
| 11-26 17:47 | 23 | **28** | 5.2 s | 123 s | Langsam und lang |
| 11-26 17:49 | 13 | **50** | 8.0 s | 110 s | Sehr langsam und lang |
| 11-26 17:56 | 14 | **21** | 0.0 s | 70 s | Sehr langsam und lang |
| 11-26 18:09 | 5 | 5 | 2.5 s | 13 s | Sehr langsam und lang |
| 11-26 18:10 | 15 | **11** | 3.5 s | 53 s | Sehr langsam und lang |

The last three are on a weight stack, the rest hand-held. `18:10` has no cadence
because its taps carry no timing — it was counted by hand afterwards.

Two separate failures, and both come from constants this project added rather than from
the published method.

**Slow repetitions split.** On the 8 s set the detector finds 47 peaks for 13
repetitions, median peak spacing 1.85 s, two to six peaks inside one repetition. A slow
repetition has a broad velocity lobe and the ripples on it clear a minimum spacing that
sits at a fixed 0.6 s. Recorded above and below the 60 s analysis window at the same
tempo: both break, so it is the tempo and not the window.

**The idle guard closes on real sets.** It compares movement-band energy against
residual energy, measured on acceleration — and slow movement has little acceleration by
its nature. Its threshold is 0.5; the stack set at 18:10 measures 0.44 and is dropped
entirely, while three further genuine sets sit at 0.57, 0.68 and 0.74. A rattling stack
raises the denominator and pushes it further.

Cadence read from zero crossings, which is within 10 % on every hand-held failure, does
not survive the stack: 18:10 gives 2.5 crossings per repetition and 17:56 gives 4.0,
against the 2.0 a clean reversal produces. Stack ring crosses zero. Any cadence estimate
built on it has to be checked here first.

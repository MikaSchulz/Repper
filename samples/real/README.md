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

`counted` is what the app on the phone did at the time of recording, all of it under the
peak-counting rule. Bold marks an error of more than one.

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
| 11-26 18:17 | 0 | **16** | 0.0 s | 102 s | Still keine Bewegung |
| 11-26 18:29 | 15 | 15 | 2.5 s | 39 s | Sehr langsam und lang |
| 11-26 18:47 | 0 | 0 | 0.0 s | 101 s | Still |
| 11-26 18:48 | 24 | 24 | 2.7 s | 67 s | Handy flach, Stack |
| 11-26 18:49 | 18 | 18 | 2.5 s | 46 s | Handy flach, Stack |
| 11-26 18:51 | 24 | **28** | 1.3 s | 38 s | Sehr kurze Wiederholungen |
| 11-26 18:51 | 26 | 26 | 1.2 s | 32 s | Sehr kurze Wiederholungen |
| 11-26 18:52 | 11 | 11 | 1.4 s | 17 s | Sehr kurze Wiederholungen |
| 11-26 18:53 | 29 | **36** | 1.7 s | 51 s | Schnell, kurvig |
| 11-26 18:53 | 18 | **23** | 2.2 s | 40 s | Schnell, kurvig |
| 11-26 18:56 | 70 | **81** | 2.0 s | 149 s | Schnell, lange Bewegung |
| 11-26 18:57 | 28 | 28 | 1.5 s | 41 s | Schnell, kurvig |
| 11-26 18:58 | 25 | 24 | 1.7 s | 41 s | Schnell, kurvig |

Twenty-nine sets, 596 tapped repetitions, two of them a phone left motionless. Three
distinct failures showed up here, in this order, each one only visible because the
recording before it had ruled something out.

**Slow repetitions split.** On the 8 s set the peak detector returns 47 peaks for 13
repetitions, median spacing 1.85 s. Recorded above and below the 60 s analysis window at
the same tempo: both break, so it is the tempo, not the window.

**The idle guard ran backwards.** It compared movement-band energy to residual energy on
acceleration, and slow movement has little acceleration by its nature. A genuine stack
set scored 0.44 and was dropped whole; a phone untouched for 102 s scored 0.66 and
counted 16. Velocity separates the same two by a factor of 18.

**Fast repetitions merge.** Counting lobes instead of peaks fixed the slow sets and then
cost 27 repetitions on a 149 s set of 70 fast ones -- 54 lobes for 70 repetitions,
because the residual offset left by the polynomial detrend held consecutive repetitions
above zero so they never separated. Re-centring the velocity on a 20 s moving average
restores the crossings.

Total error across all of it, against what was tapped: 122 for the peak rule the phone
was running, 39 for what the repository holds now. The sets recorded last were a holdout
-- they existed before the fix was measured against them, and they are what caught the
merging.

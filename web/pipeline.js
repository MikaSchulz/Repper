/* Velocity-domain repetition detection — JS port of src/repper/pipeline.py.
 * Pure functions plus a streaming RepCounter. No DOM access, so it can be
 * unit-tested under node (see test/js_parity.mjs).
 *
 * Input must be acceleration INCLUDING gravity: the vector magnitude minus the
 * gravity offset recovers the signed axis acceleration. Gravity-free input
 * (DeviceMotionEvent.acceleration) loses the sign and the integral ramps away.
 */

export const DEFAULTS = {
  fs: 100,            // resampling grid [Hz]
  windowS: 60,        // trailing analysis window [s]; must span several reps
  minRepS: 0.6,       // minimum distance between repetitions
  promFrac: 0.30,     // peak prominence as fraction of p90(|v|)
  smoothS: 0.25,
  hampelS: 0.10,
  detrendOrder: 2,
  confirmLagS: 0.35,  // a peak is only counted once this much newer data exists
  sightings: 2,       // a peak must survive this many consecutive analyses
  minWindowS: 4.0,    // do not judge a window shorter than this
  minRomFrac: 0.55,   // reject peaks whose stack travel falls below this share of the median
  romWarmup: 2,       // repetitions accepted before the range-of-motion gate starts
  romMaxCadenceS: 5.0,// above this cadence the displacement estimate is too noisy to gate on
  romSettleS: 1.0,    // how far inside the window a lobe must sit before it is measured
  minPasses: 8,       // passes a candidate must have sat in the window before it is judged
  minHitRate: 0.4,    // share of those passes it has to be re-detected in to survive
  minSnr: 0.5,        // movement band vs. sensor noise; below this the window is idle
  minActivity: 0.12,  // local movement vs. the window's own peak level; below this: standing still
  // The detector as the paper describes it, without anything added here: no
  // range-of-motion gate, no local idle guard, and nothing is ever withdrawn once
  // counted. The version that was in the gym first; kept switchable so the additions
  // can be judged against it on the same set.
  legacy: false,
};

export function hampel(x, win) {
  win = Math.max(3, win | 1);
  const half = win >> 1, out = x.slice(), buf = new Float64Array(win);
  for (let i = 0; i < x.length; i++) {
    for (let k = 0; k < win; k++) buf[k] = x[Math.min(x.length - 1, Math.max(0, i - half + k))];
    const med = Float64Array.from(buf).sort()[half];
    for (let k = 0; k < win; k++) buf[k] = Math.abs(buf[k] - med);
    const mad = Float64Array.from(buf).sort()[half] * 1.4826;
    const dev = Math.abs(x[i] - med);
    // mad === 0 means the whole window is identical: any deviation is an outlier
    if (mad > 0 ? dev > 3 * mad : dev > 0) out[i] = med;
  }
  return out;
}

export function resample(t, x, fs) {
  const grid = [], out = [];
  let j = 0;
  for (let g = t[0]; g <= t[t.length - 1]; g += 1 / fs) {
    while (j < t.length - 2 && t[j + 1] < g) j++;
    const dt = t[j + 1] - t[j];
    const f = dt > 0 ? (g - t[j]) / dt : 0;
    grid.push(g);
    out.push(x[j] + f * (x[j + 1] - x[j]));
  }
  return [grid, out];
}

export function median(a) {
  const s = Float64Array.from(a).sort(), n = s.length;
  return n % 2 ? s[(n - 1) >> 1] : 0.5 * (s[n / 2 - 1] + s[n / 2]);
}

export function percentile(x, p) {
  if (!x.length) return 0;
  const s = Float64Array.from(x).sort();
  return s[Math.floor(p * (s.length - 1))];
}

export function std(x) {
  let m = 0;
  for (const v of x) m += v;
  m /= x.length;
  let s = 0;
  for (const v of x) s += (v - m) * (v - m);
  return Math.sqrt(s / Math.max(1, x.length - 1));
}

export function integrate(a, fs) {
  const v = new Float64Array(a.length), dt = 1 / fs;
  for (let i = 1; i < a.length; i++) v[i] = v[i - 1] + 0.5 * (a[i] + a[i - 1]) * dt;
  return v;
}

export function detrendPoly(v, order) {
  const n = v.length, m = order + 1;
  if (n <= m) return v;
  const A = Array.from({length: m}, () => new Float64Array(m)), b = new Float64Array(m);
  const pow = new Float64Array(m);
  for (let i = 0; i < n; i++) {
    const u = 2 * i / (n - 1) - 1;
    pow[0] = 1;
    for (let k = 1; k < m; k++) pow[k] = pow[k - 1] * u;
    for (let r = 0; r < m; r++) {
      b[r] += pow[r] * v[i];
      for (let c = 0; c < m; c++) A[r][c] += pow[r] * pow[c];
    }
  }
  for (let c = 0; c < m; c++) {                       // Gauss-Jordan
    let p = c;
    for (let r = c + 1; r < m; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
    [A[c], A[p]] = [A[p], A[c]];
    [b[c], b[p]] = [b[p], b[c]];
    if (Math.abs(A[c][c]) < 1e-12) continue;
    for (let r = 0; r < m; r++) {
      if (r === c) continue;
      const f = A[r][c] / A[c][c];
      for (let k = c; k < m; k++) A[r][k] -= f * A[c][k];
      b[r] -= f * b[c];
    }
  }
  const coef = Array.from(b, (bi, i) => Math.abs(A[i][i]) < 1e-12 ? 0 : bi / A[i][i]);
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const u = 2 * i / (n - 1) - 1;
    let fit = 0, p = 1;
    for (let k = 0; k < m; k++) { fit += coef[k] * p; p *= u; }
    out[i] = v[i] - fit;
  }
  return out;
}

export function movingAverage(x, win) {
  if (win <= 1) return x;
  const n = x.length, out = new Float64Array(n), half = win >> 1;
  const at = i => x[Math.min(n - 1, Math.max(0, i))];
  let sum = 0;
  for (let k = -half; k < win - half; k++) sum += at(k);
  for (let i = 0; i < n; i++) { out[i] = sum / win; sum += at(i + win - half) - at(i - half); }
  return out;
}

export function findPeaks(x, minDist, minProm) {
  const cand = [];
  for (let i = 1; i < x.length - 1; i++) {
    if (!(x[i] > x[i - 1] && x[i] >= x[i + 1])) continue;
    let l = x[i], r = x[i], j = i;
    while (j > 0 && x[j] <= x[i]) { j--; l = Math.min(l, x[j]); }
    j = i;
    while (j < x.length - 1 && x[j] <= x[i]) { j++; r = Math.min(r, x[j]); }
    const prom = x[i] - Math.max(l, r);
    if (prom >= minProm) cand.push(i);
  }
  cand.sort((a, b) => x[b] - x[a]);
  const kept = [];
  for (const i of cand) if (kept.every(k => Math.abs(k - i) >= minDist)) kept.push(i);
  return kept.sort((a, b) => a - b);
}

/** Zero crossings bracketing the positive velocity lobe that contains `peak`. */
export function lobeBounds(v, peak) {
  let a = peak;
  while (a > 0 && v[a] > 0) a--;
  let b = peak;
  while (b < v.length - 1 && v[b] > 0) b++;
  return [a, b];
}

/** Distance the stack travelled during one concentric phase: the area under the
 *  positive velocity lobe. This is what separates a full repetition from one that was
 *  only started — a short jerk reaches nearly the same peak velocity but covers far
 *  less ground.
 *
 *  Only meaningful once the lobe sits a little inside the window (see romSettleS):
 *  measured right at the trailing edge, the polynomial detrend shifts the zero
 *  crossings and the same stroke scatters by a factor of three. */
export function lobeDisplacement(v, peak, fs) {
  const [a, b] = lobeBounds(v, peak);
  if (b <= a) return 0;
  let area = 0;
  for (let i = a; i < b; i++) area += 0.5 * (v[i] + v[i + 1]) / fs;
  return area;
}

/** Which candidates are full repetitions, judged against the set's own range of motion.
 *
 *  Every exercise has a different stroke, so the reference has to come from the set
 *  itself. It is found by iteration: start from the median of all candidates, keep those
 *  within `minFrac` of it, recompute the median from those, repeat. Two or three real
 *  repetitions pin it down, after which the small movements — lifting the stack into the
 *  starting position, a last repetition that only makes it half way — drop out.
 *
 *  Because this re-runs over every candidate on every pass, a repetition counted earlier
 *  can be withdrawn later, once the set has shown what a full repetition looks like.
 */
export function classifyByTravel(travels, minFrac, iterations = 4) {
  if (!travels.length) return [];
  let accepted = travels.map(() => true);
  for (let k = 0; k < iterations; k++) {
    const kept = travels.filter((_, i) => accepted[i]);
    const reference = median(kept.length ? kept : travels);
    if (!(reference > 0)) return travels.map(() => true);
    const updated = travels.map(t => t >= minFrac * reference);
    if (!updated.some(Boolean)) return accepted;
    if (updated.every((v, i) => v === accepted[i])) break;
    accepted = updated;
  }
  return accepted;
}

/** One pass over a window of samples: [[t, x, y, z], ...] -> conditioned signals + peaks. */
export function analyseWindow(samples, opt = {}) {
  const o = {...DEFAULTS, ...opt};
  const t = [], mag = [];
  let prev = -Infinity;
  for (const s of samples) {
    if (s[0] <= prev) continue;                       // non-unique timestamps
    prev = s[0];
    t.push(s[0]);
    mag.push(Math.hypot(s[1], s[2], s[3]));
  }
  if (t.length < 20) return null;

  const rate = (t.length - 1) / (t[t.length - 1] - t[0]);
  const clean = hampel(mag, Math.round(o.hampelS * rate));
  const [tg, sig] = resample(t, clean, o.fs);
  const g = median(sig);
  const acc = sig.map(v => v - g);
  let vel = detrendPoly(integrate(acc, o.fs), o.detrendOrder);
  vel = movingAverage(vel, Math.round(o.smoothS * o.fs));

  const abs = Float64Array.from(vel, Math.abs).sort();
  const scale = abs[Math.floor(0.9 * (abs.length - 1))];

  // Idle-window guard. The prominence threshold is relative to the window's own
  // amplitude, so a window holding nothing but sensor noise would have that
  // noise rescaled into "repetitions". Movement lives well below ~3 Hz, sensor
  // noise does not, so the ratio of the smoothed component to the residual
  // separates the two independently of how slow or light the set is.
  const band = movingAverage(acc, Math.round(0.3 * o.fs));
  const resid = acc.map((a, i) => a - band[i]);
  const snr = std(band) / (std(resid) || 1e-9);
  const quiet = snr < o.minSnr || (tg[tg.length - 1] - tg[0]) < o.minWindowS;

  // How much movement there is *right now*, measured against how much this window sees
  // at its busiest. The window-wide ratio above cannot answer that: while it still holds
  // the set that just ended it looks busy, so a peak the detrend invents in the standing
  // still afterwards would be counted and would spoil the set. Comparing local amplitude
  // against the window's own amplitude works at any tempo — a slow repetition is weak in
  // absolute terms but not weak compared to the rest of its own set.
  const activity = movingAverage(acc.map(Math.abs), Math.round(1.0 * o.fs));
  const activityScale = percentile(activity, 0.9) || 1e-9;
  const localActivity = activity.map(a => a / activityScale);

  const found = quiet ? [] : findPeaks(vel, Math.round(o.minRepS * o.fs), o.promFrac * scale);
  const peaks = o.legacy ? found : found.filter(p => localActivity[p] >= o.minActivity);

  const tailFrom = Math.max(0, localActivity.length - Math.round(2.0 * o.fs));
  const tail = localActivity.slice(tailFrom);
  const tailIdle = tail.length > 0
    && tail.reduce((a, b) => a + b, 0) / tail.length < o.minActivity;

  return {tg, acc, vel, peaks, rate, snr, quiet, localActivity, tailIdle};
}

/** Streaming counter.
 *
 *  Peaks become candidates; candidates are re-judged on every pass against the range of
 *  motion of the set so far. The count may therefore correct itself — the lift that puts
 *  the stack into the starting position looks like a repetition until two real ones have
 *  set the scale, and then it disappears from both the number and the curve.
 */
export class RepCounter {
  constructor(opt = {}) {
    this.o = {...DEFAULTS, ...opt};
    this.samples = [];
    this.candidates = [];       // {t, travel, sightings, passes}
    this.lastSampleCount = -1;
    this.reps = [];             // accepted candidate times [s]
    this.phases = [];           // [con, ecc] per accepted rep, or null
    this.last = null;
  }

  push(t, x, y, z) { this.samples.push([t, x, y, z]); }

  get count() { return this.reps.length; }

  reset() {
    this.samples.length = 0;
    this.candidates = [];
    this.reps = [];
    this.phases = [];
    this.lastSampleCount = -1;
    this.last = null;
  }

  /** Median spacing of a list of times, 0 if there are fewer than two. */
  static medianGap(times) {
    if (times.length < 2) return 0;
    const gaps = [];
    for (let i = 1; i < times.length; i++) gaps.push(times[i] - times[i - 1]);
    gaps.sort((a, b) => a - b);
    return gaps[gaps.length >> 1];
  }

  /** How far a re-detected peak may wander between passes without being taken for a new
   *  one: half the observed cadence, floored at the minimum repetition distance.
   *  Measured on the candidates, not on the accepted repetitions — the gate must not
   *  influence the geometry it is judged with. */
  get mergeTolerance() {
    const gap = RepCounter.medianGap(this.candidates.map(c => c.t));
    return gap > 0 ? Math.max(this.o.minRepS, 0.45 * gap) : this.o.minRepS;
  }

  /** Above this cadence the travel estimate scatters too much to judge by. Derived from
   *  the candidates for the same reason: deriving it from the accepted repetitions would
   *  be circular — a gate that wrongly rejects would keep itself switched on. */
  gateActiveFor(times) {
    if (this.o.minRomFrac <= 0) return false;
    const gap = RepCounter.medianGap(times);
    return gap === 0 || gap <= this.o.romMaxCadenceS;
  }

  update() {
    if (this.samples.length < this.o.fs / 2) return null;
    // Without new samples there is nothing to re-judge, and running anyway would inflate
    // every candidate's pass count and skew the hit-rate filter — a counter refreshed
    // often would then behave differently from the same signal replayed.
    if (this.samples.length === this.lastSampleCount) return this.last;
    this.lastSampleCount = this.samples.length;
    const tNow = this.samples[this.samples.length - 1][0];
    const from = tNow - this.o.windowS;
    while (this.samples.length > 4 && this.samples[0][0] < from - 1) this.samples.shift();
    const win = this.samples.filter(s => s[0] >= from);

    const r = analyseWindow(win, this.o);
    this.last = r;
    if (!r) return null;

    const tol = this.mergeTolerance;
    const windowStart = r.tg[0];
    const seenNow = new Set();

    for (const p of r.peaks) {
      const tp = r.tg[p];
      if (tp > tNow - this.o.confirmLagS) continue;        // too fresh to be stable
      const [la, lb] = lobeBounds(r.vel, p);
      const settled = (r.tg[r.tg.length - 1] - r.tg[lb]) >= this.o.romSettleS;
      const complete = lb < r.vel.length - 1 && settled;

      let cand = this.candidates.find(c => Math.abs(c.t - tp) < tol);
      if (!cand) {
        cand = {t: tp, travel: null, sightings: 0, passes: 0};
        this.candidates.push(cand);
      }
      cand.sightings++;
      cand.t = tp;
      if (complete) cand.travel = lobeDisplacement(r.vel, p, this.o.fs);
      seenNow.add(cand);
    }

    // A single missed pass means nothing: peak prominence is relative to the window's own
    // amplitude and fluctuates as the window slides, and a repetition deleted by mistake
    // could never come back once the window has moved past it. What separates a real
    // repetition from an artefact is how *reliably* it is re-detected while it sits in
    // the window — a real one shows up in nearly every pass, a transient in a few.
    for (const c of this.candidates) {
      if (c.t >= windowStart && c.t <= tNow - this.o.confirmLagS) c.passes = (c.passes || 0) + 1;
    }
    if (!this.o.legacy) {
      this.candidates = this.candidates.filter(c =>
        (c.passes || 0) < this.o.minPasses || c.sightings / c.passes >= this.o.minHitRate);
    }

    this.candidates.sort((a, b) => a.t - b.t);
    const judged = this.candidates.filter(c => c.sightings >= this.o.sightings
                                            && c.travel !== null);
    // In legacy mode a repetition stays counted once it is counted: no re-judging, and
    // therefore no withdrawal either.
    const accepted = (!this.o.legacy && this.gateActiveFor(judged.map(c => c.t)))
      ? classifyByTravel(judged.map(c => c.travel), this.o.minRomFrac)
      : judged.map(() => true);

    const previous = this.phases;
    const previousReps = this.reps;
    this.reps = judged.filter((_, i) => accepted[i]).map(c => c.t);
    this.phases = this.reps.map(t => {
      const i = previousReps.findIndex(p => Math.abs(p - t) < 1e-6);
      return i >= 0 ? previous[i] : null;
    });
    this.resolvePhases(r);
    return r;
  }

  /** Fill in concentric/eccentric durations for repetitions whose eccentric lobe has
   *  since arrived. A repetition is placed at its velocity peak, so its eccentric phase
   *  is usually still outside the window at that moment. */
  resolvePhases(r) {
    const end = r.vel.length - 1;
    for (let i = 0; i < this.reps.length; i++) {
      if (this.phases[i]) continue;
      const t = this.reps[i];
      if (t < r.tg[0] || t > r.tg[end]) continue;
      let p = Math.round((t - r.tg[0]) * this.o.fs);
      p = Math.min(end, Math.max(0, p));
      let a = p; while (a > 0 && r.vel[a] > 0) a--;
      let b = p; while (b < end && r.vel[b] > 0) b++;
      let c = b; while (c < end && r.vel[c] <= 0) c++;
      if (a === 0 || b === end || c === end) continue;      // lobe not fully inside
      this.phases[i] = [r.tg[b] - r.tg[a], r.tg[c] - r.tg[b]];
    }
  }
}

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
  minSnr: 0.5,        // movement band vs. sensor noise; below this the window is idle
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

  const peaks = quiet ? [] : findPeaks(vel, Math.round(o.minRepS * o.fs), o.promFrac * scale);

  return {tg, acc, vel, peaks, rate, snr, quiet};
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
    this.reps = [];             // confirmed repetition times [s]
    this.phases = [];           // [con, ecc] per repetition, filled in once it is known
    this.last = null;
    this.frontier = -Infinity;  // nothing at or before this time can be counted again
    this.pending = [];          // [time, sightings] awaiting confirmation
  }

  push(t, x, y, z) { this.samples.push([t, x, y, z]); }

  get count() { return this.reps.length; }

  reset() {
    this.samples.length = 0;
    this.reps = [];
    this.phases = [];
    this.pending = [];
    this.frontier = -Infinity;
    this.last = null;
  }

  /** Half the observed cadence, floored at minRepS: how far a re-detected peak may
   *  wander between passes without being taken for a second repetition. */
  get mergeTolerance() {
    if (this.reps.length < 2) return this.o.minRepS;
    const gaps = [];
    for (let i = 1; i < this.reps.length; i++) gaps.push(this.reps[i] - this.reps[i - 1]);
    gaps.sort((a, b) => a - b);
    return Math.max(this.o.minRepS, 0.45 * gaps[gaps.length >> 1]);
  }

  /** Re-analyse the trailing window and confirm any new repetitions. */
  update() {
    if (this.samples.length < this.o.fs / 2) return null;
    const tNow = this.samples[this.samples.length - 1][0];
    const from = tNow - this.o.windowS;
    while (this.samples.length > 4 && this.samples[0][0] < from - 1) this.samples.shift();
    const win = this.samples.filter(s => s[0] >= from);

    const r = analyseWindow(win, this.o);
    this.last = r;
    if (!r) return null;

    // Bootstrap: the cadence is unknown, and a detrend over roughly one repetition can
    // split that repetition in two. Commit nothing until the window covers at least
    // three apparent repetition periods.
    if (this.reps.length === 0) {
      if (r.peaks.length < 2) return r;
      const gaps = [];
      for (let i = 1; i < r.peaks.length; i++) gaps.push((r.peaks[i] - r.peaks[i - 1]) / this.o.fs);
      gaps.sort((a, b) => a - b);
      const span = r.tg[r.tg.length - 1] - r.tg[0];
      if (span < 3 * gaps[gaps.length >> 1]) return r;
    }

    // A peak has to show up in consecutive analyses before it counts. A single knock
    // against the stack can look like a repetition in one window; it does not survive
    // the next one.
    const tol = this.mergeTolerance;
    const seen = [];
    for (const p of r.peaks) {
      const tp = r.tg[p];
      if (tp > tNow - this.o.confirmLagS) continue;      // too fresh to be stable
      if (tp <= this.frontier + tol) continue;           // same repetition, shifted
      const prev = this.pending.find(q => Math.abs(q[0] - tp) < tol);
      const entry = prev ? [tp, prev[1] + 1] : [tp, 1];
      seen.push(entry);
      if (entry[1] >= this.o.sightings) {
        this.reps.push(tp);
        this.phases.push(null);     // resolved once the eccentric lobe is complete
        this.frontier = tp;
      }
    }
    this.pending = seen.filter(e => e[1] < this.o.sightings);

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

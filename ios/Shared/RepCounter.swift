import Foundation

/// Tuning constants. Identical to `web/pipeline.js` DEFAULTS.
struct RepConfig: Equatable {
    var fs = 100.0              // resampling grid [Hz]
    var windowS = 60.0          // trailing analysis window [s]; must span several reps
    var minRepS = 0.6           // minimum distance between repetitions
    var travelFrac = 0.30       // a lobe counts at this fraction of its neighbours' travel
    var edgeFrac = 0.70         // a lobe cut off by the window edge has to show more
    var travelWindow = 9        // how many neighbouring lobes set the yardstick
    var minFullLobes = 2        // complete lobes needed before anything is committed
    var smoothS = 0.25
    var hampelS = 0.10
    var detrendOrder = 2
    var confirmLagS = 0.35      // a peak is only counted once this much newer data exists
    var sightings = 2           // a peak must survive this many consecutive analyses
    var minWindowS = 4.0        // do not judge a window shorter than this
    var minVelocity = 0.02      // p90(|v|) below this [m/s]: nothing is moving

    static let `default` = RepConfig()
}

struct Analysis {
    var t: [Double]             // uniform time grid [s]
    var acc: [Double]           // conditioned acceleration [m/s^2]
    var vel: [Double]           // detrended, smoothed velocity [m/s]
    var peaks: [Int]
    var rate: Double            // measured input sampling rate [Hz]
    var snr: Double
    var quiet: Bool
    var fullLobes: Int          // lobes the window did not cut off
}

/// One sample of specific force (acceleration INCLUDING gravity), in m/s^2.
struct MotionSample {
    var t: Double
    var x: Double
    var y: Double
    var z: Double

    var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Streaming repetition counter, the method as published.
///
/// Feed it accelerometer samples that still contain gravity: the vector magnitude minus
/// the gravity offset is the signed acceleration along the stack axis, which is why the
/// phone can lie on the stack in any orientation. Gravity-free data (`userAcceleration`)
/// loses the sign of the movement direction and does not work here.
///
/// A peak in the velocity is a repetition. Nothing is weighed up beyond that: whatever
/// clears the peak detector counts, including lifting the stack into the starting
/// position and a repetition that only makes it half way. That is the behaviour this
/// branch is for.
final class RepCounter {

    private(set) var reps: [Double] = []            // confirmed repetition times [s]
    private(set) var phases: [(con: Double, ecc: Double)?] = []
    private(set) var last: Analysis?

    private var samples: [MotionSample] = []
    private var frontier = -Double.infinity
    private var pending: [(t: Double, seen: Int)] = []
    private let cfg: RepConfig

    init(config: RepConfig = .default) { cfg = config }

    var count: Int { reps.count }

    var medianPhases: (con: Double, ecc: Double)? {
        let done = phases.compactMap { $0 }
        guard !done.isEmpty else { return nil }
        let con = done.map(\.con).sorted()
        let ecc = done.map(\.ecc).sorted()
        return (con[con.count / 2], ecc[ecc.count / 2])
    }

    /// Span from the first to the last counted repetition.
    var tut: Double {
        guard let first = reps.first, let lastRep = reps.last else { return 0 }
        return lastRep - first
    }

    func reset() {
        samples.removeAll()
        reps.removeAll()
        phases.removeAll()
        pending.removeAll()
        frontier = -.infinity
        last = nil
    }

    func push(_ s: MotionSample) { samples.append(s) }

    /// Re-analyse the trailing window and confirm any new repetitions.
    @discardableResult
    func update() -> Analysis? {
        guard samples.count >= Int(cfg.fs / 2) else { return nil }
        let tNow = samples[samples.count - 1].t
        let from = tNow - cfg.windowS
        while samples.count > 4 && samples[0].t < from - 1 { samples.removeFirst() }
        let win = samples.filter { $0.t >= from }

        guard let r = Self.analyse(win, cfg: cfg) else { return nil }
        last = r

        // A lobe is judged against the travel of its neighbours, and a window at the
        // start of a set holds mostly lobes its own edges cut off -- with no complete
        // ones to compare against, anything passes, and the frontier never takes a
        // commit back. On a slow set that put two phantom repetitions into the first
        // seven seconds.
        if r.fullLobes < cfg.minFullLobes { return r }

        // Bootstrap: the cadence is unknown, and a detrend over roughly one repetition
        // can split that repetition in two. Commit nothing until the window covers at
        // least three apparent repetition periods.
        if reps.isEmpty {
            guard r.peaks.count >= 2 else { return r }
            var gaps: [Double] = []
            for i in 1..<r.peaks.count {
                gaps.append(Double(r.peaks[i] - r.peaks[i - 1]) / cfg.fs)
            }
            gaps.sort()
            let span = r.t[r.t.count - 1] - r.t[0]
            if span < 3 * gaps[gaps.count / 2] { return r }
        }

        // A peak has to show up in consecutive analyses before it counts. A single knock
        // against the stack can look like a repetition in one window; it does not
        // survive the next one.
        let tol = mergeTolerance
        var seen: [(t: Double, seen: Int)] = []
        for p in r.peaks {
            let tp = r.t[p]
            if tp > tNow - cfg.confirmLagS { continue }     // too fresh to be stable
            if tp <= frontier + tol { continue }            // same repetition, shifted
            let prior = pending.first { abs($0.t - tp) < tol }
            let entry = (t: tp, seen: (prior?.seen ?? 0) + 1)
            seen.append(entry)
            if entry.seen >= cfg.sightings {
                reps.append(tp)
                phases.append(nil)                          // resolved once the ecc lands
                frontier = tp
            }
        }
        pending = seen.filter { $0.seen < cfg.sightings }

        resolvePhases(r)
        return r
    }

    /// Half the observed cadence, floored at minRepS: how far a re-detected peak may
    /// wander between passes without being taken for a second repetition.
    private var mergeTolerance: Double {
        guard reps.count >= 2 else { return cfg.minRepS }
        var gaps: [Double] = []
        for i in 1..<reps.count { gaps.append(reps[i] - reps[i - 1]) }
        gaps.sort()
        return max(cfg.minRepS, 0.45 * gaps[gaps.count / 2])
    }

    /// Fill in concentric/eccentric durations for repetitions whose eccentric lobe has
    /// since arrived. A repetition is placed at its velocity peak, so its eccentric
    /// phase is usually still outside the window at that moment.
    private func resolvePhases(_ r: Analysis) {
        let end = r.vel.count - 1
        guard end > 0 else { return }
        for i in 0..<reps.count where phases[i] == nil {
            let t = reps[i]
            guard t >= r.t[0], t <= r.t[end] else { continue }
            var p = Int(((t - r.t[0]) * cfg.fs).rounded())
            p = min(end, max(0, p))
            var a = p
            while a > 0 && r.vel[a] > 0 { a -= 1 }
            var b = p
            while b < end && r.vel[b] > 0 { b += 1 }
            var c = b
            while c < end && r.vel[c] <= 0 { c += 1 }
            if a == 0 || b == end || c == end { continue }  // lobe not fully inside
            phases[i] = (con: r.t[b] - r.t[a], ecc: r.t[c] - r.t[b])
        }
    }

    /// The pipeline itself: magnitude -> Hampel -> resample -> gravity offset ->
    /// integrate -> detrend -> smooth -> peaks.
    static func analyse(_ samples: [MotionSample], cfg: RepConfig = .default) -> Analysis? {
        var t: [Double] = []
        var mag: [Double] = []
        var prev = -Double.infinity
        for s in samples where s.t > prev {
            prev = s.t
            t.append(s.t)
            mag.append(s.magnitude)
        }
        guard t.count >= 20 else { return nil }

        let rate = Double(t.count - 1) / (t[t.count - 1] - t[0])
        let clean = Signal.hampel(mag, window: Int((cfg.hampelS * rate).rounded()))
        let (tg, sig) = Signal.resample(t, clean, fs: cfg.fs)
        guard tg.count > 4 else { return nil }

        let g = Signal.median(sig)
        let acc = sig.map { $0 - g }
        var vel = Signal.detrendPoly(Signal.integrate(acc, fs: cfg.fs), order: cfg.detrendOrder)
        vel = Signal.movingAverage(vel, window: Int((cfg.smoothS * cfg.fs).rounded()))

        // Idle guard. The prominence threshold is a fraction of the window's own
        // amplitude, so a window holding nothing but sensor noise would have that noise
        // rescaled into "repetitions". The scale is its own guard: a phone lying still
        // integrates to a velocity that no real movement comes near.
        //
        // This used to compare movement-band energy against residual energy on
        // acceleration. That measure is not merely tight here, it is backwards: slow
        // movement has little acceleration by its nature, so a genuine set on a weight
        // stack read 0.44 and was dropped, while a phone left untouched for 102 s read
        // 0.66 and was let through to count 16 repetitions. Velocity separates those
        // two by a factor of 18.
        let scale = Signal.percentile(vel.map(abs), 0.9)
        let quiet = scale < cfg.minVelocity || (tg[tg.count - 1] - tg[0]) < cfg.minWindowS

        let band = Signal.movingAverage(acc, window: Int((0.3 * cfg.fs).rounded()))
        var resid = [Double](repeating: 0, count: acc.count)
        for i in 0..<acc.count { resid[i] = acc[i] - band[i] }
        let residSd = Signal.std(resid)
        let snr = residSd > 0 ? Signal.std(band) / residSd : .infinity   // diagnostics only

        var peaks: [Int] = []
        var fullLobes = 0
        if !quiet {
            let lobes = Signal.positiveLobes(vel, fs: cfg.fs)
            fullLobes = lobes.atEdge.filter { !$0 }.count
            let reference = Signal.localMedian(lobes.travel, window: cfg.travelWindow)
            for k in 0..<lobes.peaks.count {
                // A lobe cut off by the end of the window shows only part of its
                // travel, so the same bar would let a sliver through.
                let need = (lobes.atEdge[k] ? cfg.edgeFrac : cfg.travelFrac) * reference[k]
                if lobes.travel[k] >= need { peaks.append(lobes.peaks[k]) }
            }
        }

        return Analysis(t: tg, acc: acc, vel: vel, peaks: peaks, rate: rate, snr: snr,
                        quiet: quiet, fullLobes: fullLobes)
    }
}

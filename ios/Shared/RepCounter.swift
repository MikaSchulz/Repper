import Foundation

/// Tuning constants. Identical to `web/pipeline.js` DEFAULTS.
///
/// Codable so that variants edited in the app survive a restart. Decoding falls back to
/// the default for any field a stored payload does not carry, which keeps older saved
/// settings usable when a parameter is added.
struct RepConfig: Codable, Equatable {
    var fs = 100.0              // resampling grid [Hz]
    var windowS = 60.0          // trailing analysis window [s]; must span several reps
    var minRepS = 0.6           // minimum distance between repetitions
    var promFrac = 0.30         // peak prominence as fraction of p90(|v|)
    var smoothS = 0.25
    var hampelS = 0.10
    var detrendOrder = 2
    var confirmLagS = 0.35      // a peak is only counted once this much newer data exists
    var sightings = 2           // a peak must survive this many consecutive analyses
    var minWindowS = 4.0        // do not judge a window shorter than this
    var minSnr = 0.5            // movement band vs. sensor noise over the window: idle
    var minActivity = 0.12      // local movement vs. the window's own level: standing still
    /// The detector as the paper describes it, without anything added here: no
    /// range-of-motion gate, no local idle guard, and nothing is ever withdrawn once
    /// counted. The version that was in the gym first; kept switchable so the additions
    /// can be judged against it on the same set.
    var legacy = false
    var minRomFrac = 0.65       // reject peaks whose stack travel falls below this share
    var romMaxCadenceS = 5.0    // slower than this, the travel estimate is too noisy to gate
    var romSettleS = 1.0        // how far inside the window a lobe must sit before judging
    var minPasses = 8           // passes in the window before a candidate is held to account
    var minHitRate = 0.4        // share of those passes it must be re-detected in

    static let `default` = RepConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RepConfig.default
        fs = try c.decodeIfPresent(Double.self, forKey: .fs) ?? d.fs
        windowS = try c.decodeIfPresent(Double.self, forKey: .windowS) ?? d.windowS
        minRepS = try c.decodeIfPresent(Double.self, forKey: .minRepS) ?? d.minRepS
        promFrac = try c.decodeIfPresent(Double.self, forKey: .promFrac) ?? d.promFrac
        smoothS = try c.decodeIfPresent(Double.self, forKey: .smoothS) ?? d.smoothS
        hampelS = try c.decodeIfPresent(Double.self, forKey: .hampelS) ?? d.hampelS
        detrendOrder = try c.decodeIfPresent(Int.self, forKey: .detrendOrder) ?? d.detrendOrder
        confirmLagS = try c.decodeIfPresent(Double.self, forKey: .confirmLagS) ?? d.confirmLagS
        sightings = try c.decodeIfPresent(Int.self, forKey: .sightings) ?? d.sightings
        minWindowS = try c.decodeIfPresent(Double.self, forKey: .minWindowS) ?? d.minWindowS
        minSnr = try c.decodeIfPresent(Double.self, forKey: .minSnr) ?? d.minSnr
        minRomFrac = try c.decodeIfPresent(Double.self, forKey: .minRomFrac) ?? d.minRomFrac
        romMaxCadenceS = try c.decodeIfPresent(Double.self, forKey: .romMaxCadenceS)
            ?? d.romMaxCadenceS
        romSettleS = try c.decodeIfPresent(Double.self, forKey: .romSettleS) ?? d.romSettleS
        minPasses = try c.decodeIfPresent(Int.self, forKey: .minPasses) ?? d.minPasses
        minHitRate = try c.decodeIfPresent(Double.self, forKey: .minHitRate) ?? d.minHitRate
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? d.legacy
    }
}

struct Analysis {
    var t: [Double]             // uniform time grid [s]
    var acc: [Double]           // conditioned acceleration [m/s^2]
    var vel: [Double]           // detrended, smoothed velocity [m/s]
    var peaks: [Int]
    var rate: Double            // measured input sampling rate [Hz]
    var snr: Double
    var quiet: Bool
    /// Nothing has moved for the last couple of seconds. The set is over even though the
    /// window still holds it, so the display can be frozen instead of drifting on.
    var tailIdle: Bool
}

/// One sample of specific force (acceleration INCLUDING gravity), in m/s^2.
struct MotionSample {
    var t: Double
    var x: Double
    var y: Double
    var z: Double

    var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Streaming repetition counter.
///
/// Feed it accelerometer samples that still contain gravity: the vector magnitude minus
/// the gravity offset is the signed acceleration along the stack axis, which is why the
/// phone can lie on the stack in any orientation. Gravity-free data (`userAcceleration`)
/// loses the sign of the movement direction and does not work here.
final class RepCounter {

    private(set) var reps: [Double] = []            // confirmed peak times [s]
    private(set) var phases: [(con: Double, ecc: Double)?] = []
    private(set) var last: Analysis?

    private var samples: [MotionSample] = []
    /// A detected peak, kept and re-judged on every pass.
    private final class Candidate {
        var t: Double
        var travel: Double?          // nil until its lobe is complete and has settled
        var sightings = 0
        var passes = 0
        var phases: (con: Double, ecc: Double)?

        init(t: Double) { self.t = t }
    }

    private var candidates: [Candidate] = []
    private var lastSampleCount = -1
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

    /// First concentric start to last eccentric end is not tracked in streaming mode;
    /// this is the span from first to last counted repetition.
    var tut: Double {
        guard let first = reps.first, let lastRep = reps.last else { return 0 }
        return lastRep - first
    }

    func reset() {
        samples.removeAll()
        reps.removeAll()
        phases.removeAll()
        candidates.removeAll()
        lastSampleCount = -1
        last = nil
    }

    func push(_ s: MotionSample) { samples.append(s) }

    /// Re-analyse the trailing window and re-judge every candidate.
    ///
    /// Nothing is committed for good: the range of motion of a set is only known once a
    /// few real repetitions are in, so a movement counted early — lifting the stack into
    /// the starting position — is withdrawn again once the scale is set. The count and
    /// the marks on the curve always show the same, currently best answer.
    @discardableResult
    func update() -> Analysis? {
        guard samples.count >= Int(cfg.fs / 2) else { return nil }
        // Without new samples there is nothing to re-judge, and running anyway would
        // inflate every candidate's pass count and skew the hit-rate filter — a counter
        // refreshed often would then behave differently from the same signal replayed.
        guard samples.count != lastSampleCount else { return last }
        lastSampleCount = samples.count
        let tNow = samples[samples.count - 1].t
        let from = tNow - cfg.windowS
        while samples.count > 4 && samples[0].t < from - 1 { samples.removeFirst() }
        let win = samples.filter { $0.t >= from }

        guard let r = Self.analyse(win, cfg: cfg) else { return nil }
        last = r

        let tol = mergeTolerance
        let windowStart = r.t[0]
        var seenNow = Set<ObjectIdentifier>()

        for p in r.peaks {
            let tp = r.t[p]
            if tp > tNow - cfg.confirmLagS { continue }        // too fresh to be stable
            let (_, lb) = Self.lobeBounds(r.vel, peak: p)
            let settled = (r.t[r.t.count - 1] - r.t[lb]) >= cfg.romSettleS
            let complete = lb < r.vel.count - 1 && settled

            let candidate: Candidate
            if let existing = candidates.first(where: { abs($0.t - tp) < tol }) {
                candidate = existing
            } else {
                candidate = Candidate(t: tp)
                candidates.append(candidate)
            }
            candidate.sightings += 1
            candidate.t = tp
            if complete {
                candidate.travel = Self.lobeDisplacement(r.vel, peak: p, fs: cfg.fs)
            }
            seenNow.insert(ObjectIdentifier(candidate))
        }

        // A single missed pass means nothing: peak prominence is relative to the window's
        // own amplitude and fluctuates as the window slides, and a repetition deleted by
        // mistake could never come back once the window has moved past it. What separates
        // a real repetition from an artefact is how *reliably* it is re-detected while it
        // sits in the window — a real one shows up in nearly every pass, a knock in few.
        for c in candidates where c.t >= windowStart && c.t <= tNow - cfg.confirmLagS {
            c.passes += 1
        }
        if !cfg.legacy {
            candidates.removeAll { c in
                c.passes >= cfg.minPasses
                    && Double(c.sightings) / Double(c.passes) < cfg.minHitRate
            }
        }
        candidates.sort { $0.t < $1.t }

        let judged = candidates.filter { $0.sightings >= cfg.sightings && $0.travel != nil }
        // In legacy mode a repetition stays counted once it is counted: no re-judging,
        // and therefore no withdrawal either.
        let accepted: [Bool]
        if !cfg.legacy && gateActive(for: judged.map(\.t)) {
            accepted = Signal.classifyByTravel(judged.map { $0.travel ?? 0 },
                                               minFrac: cfg.minRomFrac)
        } else {
            accepted = judged.map { _ in true }
        }

        let kept = zip(judged, accepted).filter { $0.1 }.map { $0.0 }
        reps = kept.map(\.t)
        phases = kept.map(\.phases)
        resolvePhases(r, kept: kept)
        return r
    }

    /// Zero crossings bracketing the positive velocity lobe that contains `peak`.
    static func lobeBounds(_ v: [Double], peak: Int) -> (Int, Int) {
        var a = peak
        while a > 0 && v[a] > 0 { a -= 1 }
        var b = peak
        while b < v.count - 1 && v[b] > 0 { b += 1 }
        return (a, b)
    }

    /// Distance the stack travelled during one concentric phase: the area under the
    /// positive velocity lobe. A short jerk reaches nearly the same peak velocity as a
    /// full repetition but covers far less ground, so this — not the peak height — is
    /// what separates a real repetition from one that was only started.
    static func lobeDisplacement(_ v: [Double], peak: Int, fs: Double) -> Double {
        let (a, b) = lobeBounds(v, peak: peak)
        guard b > a else { return 0 }
        var area = 0.0
        for i in a..<b { area += 0.5 * (v[i] + v[i + 1]) / fs }
        return area
    }

    /// Median spacing of a list of times, 0 for fewer than two.
    private static func medianGap(_ times: [Double]) -> Double {
        guard times.count >= 2 else { return 0 }
        var gaps: [Double] = []
        for i in 1..<times.count { gaps.append(times[i] - times[i - 1]) }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// How far a re-detected peak may wander between passes without being taken for a new
    /// one. Measured on the candidates, not on the accepted repetitions: the gate must not
    /// influence the geometry it is judged with.
    private var mergeTolerance: Double {
        let gap = Self.medianGap(candidates.map(\.t))
        return gap > 0 ? max(cfg.minRepS, 0.45 * gap) : cfg.minRepS
    }

    /// Above this cadence the travel estimate scatters too much to judge by. Derived from
    /// the candidates for the same reason: deriving it from the accepted repetitions would
    /// be circular — a gate that wrongly rejects would keep itself switched on.
    private func gateActive(for times: [Double]) -> Bool {
        guard cfg.minRomFrac > 0 else { return false }
        let gap = Self.medianGap(times)
        return gap == 0 || gap <= cfg.romMaxCadenceS
    }

    /// Fill in concentric/eccentric durations for repetitions whose eccentric lobe has
    /// since arrived. A repetition is placed at its velocity peak, so its eccentric phase
    /// is usually still outside the window at that moment.
    private func resolvePhases(_ r: Analysis, kept: [Candidate]) {
        let end = r.vel.count - 1
        guard end > 0 else { return }
        for (i, candidate) in kept.enumerated() where candidate.phases == nil {
            let t = candidate.t
            guard t >= r.t[0], t <= r.t[end] else { continue }
            var p = Int(((t - r.t[0]) * cfg.fs).rounded())
            p = min(end, max(0, p))
            var a = p
            while a > 0 && r.vel[a] > 0 { a -= 1 }
            var b = p
            while b < end && r.vel[b] > 0 { b += 1 }
            var c = b
            while c < end && r.vel[c] <= 0 { c += 1 }
            if a == 0 || b == end || c == end { continue }     // lobe not fully inside
            candidate.phases = (con: r.t[b] - r.t[a], ecc: r.t[c] - r.t[b])
            phases[i] = candidate.phases
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

        // Idle guard. The prominence threshold is relative to the window's own amplitude,
        // so a window holding nothing but sensor noise would have that noise rescaled into
        // "repetitions". Movement lives well below ~3 Hz, sensor noise does not.
        let band = Signal.movingAverage(acc, window: Int((0.3 * cfg.fs).rounded()))
        var resid = [Double](repeating: 0, count: acc.count)
        for i in 0..<acc.count { resid[i] = acc[i] - band[i] }
        let residSd = Signal.std(resid)
        let snr = residSd > 0 ? Signal.std(band) / residSd : .infinity
        let quiet = snr < cfg.minSnr || (tg[tg.count - 1] - tg[0]) < cfg.minWindowS

        // How much movement there is *right now*, measured against the busiest part of
        // this window. The window-wide ratio above cannot tell that nothing is moving
        // while the window still holds the set that just ended — and a peak the detrend
        // invents in the standing still afterwards would be counted and would spoil a
        // finished set. Relative to the window's own level, so it holds at any tempo.
        let activity = Signal.movingAverage(acc.map(abs),
                                            window: Int((1.0 * cfg.fs).rounded()))
        let activityScale = max(Signal.percentile(activity, 0.9), 1e-9)

        let scale = Signal.percentile(vel.map(abs), 0.9)
        let found = quiet ? [] : Signal.findPeaks(vel,
                                                  minDistance: Int((cfg.minRepS * cfg.fs).rounded()),
                                                  minProminence: cfg.promFrac * scale)
        let peaks = cfg.legacy ? found
                               : found.filter { activity[$0] / activityScale >= cfg.minActivity }

        let tailStart = max(0, activity.count - Int((2.0 * cfg.fs).rounded()))
        let tail = activity[tailStart...]
        let tailIdle = !tail.isEmpty
            && (tail.reduce(0, +) / Double(tail.count)) / activityScale < cfg.minActivity

        return Analysis(t: tg, acc: acc, vel: vel, peaks: peaks, rate: rate, snr: snr,
                        quiet: quiet, tailIdle: tailIdle)
    }
}

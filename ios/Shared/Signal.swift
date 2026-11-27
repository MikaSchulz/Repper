import Foundation

/// Signal-processing building blocks for the velocity-domain repetition detector.
/// Direct port of `src/repper/pipeline.py` / `web/pipeline.js` — the three stay in sync,
/// and `ios/Tests/run_parity.swift` checks this one against the shared fixtures.
enum Signal {

    static let gravity = 9.80665

    /// Robust outlier removal: samples further than 3 robust SD from the rolling median
    /// are replaced by it. Stack impacts are single-sample spikes and die here.
    static func hampel(_ x: [Double], window: Int) -> [Double] {
        let win = max(3, window | 1)
        let half = win / 2
        var out = x
        var buf = [Double](repeating: 0, count: win)
        for i in 0..<x.count {
            for k in 0..<win {
                buf[k] = x[min(x.count - 1, max(0, i - half + k))]
            }
            let med = buf.sorted()[half]
            for k in 0..<win { buf[k] = abs(buf[k] - med) }
            let mad = buf.sorted()[half] * 1.4826
            let dev = abs(x[i] - med)
            // mad == 0 means the whole window is identical: any deviation is an outlier
            if mad > 0 ? dev > 3 * mad : dev > 0 { out[i] = med }
        }
        return out
    }

    /// Interpolate onto an equidistant grid. Input timestamps must be strictly increasing.
    static func resample(_ t: [Double], _ x: [Double], fs: Double) -> (t: [Double], x: [Double]) {
        guard t.count > 1 else { return (t, x) }
        var grid: [Double] = []
        var out: [Double] = []
        var j = 0
        var g = t[0]
        let end = t[t.count - 1]
        let step = 1.0 / fs
        while g <= end {
            while j < t.count - 2 && t[j + 1] < g { j += 1 }
            let dt = t[j + 1] - t[j]
            let f = dt > 0 ? (g - t[j]) / dt : 0
            grid.append(g)
            out.append(x[j] + f * (x[j + 1] - x[j]))
            g += step
        }
        return (grid, out)
    }

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        let n = s.count
        return n % 2 == 1 ? s[(n - 1) / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    static func std(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        let ss = x.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / Double(x.count - 1)).squareRoot()
    }

    /// Cumulative trapezoidal integration: acceleration -> velocity.
    static func integrate(_ a: [Double], fs: Double) -> [Double] {
        var v = [Double](repeating: 0, count: a.count)
        let dt = 1.0 / fs
        for i in 1..<max(1, a.count) {
            v[i] = v[i - 1] + 0.5 * (a[i] + a[i - 1]) * dt
        }
        return v
    }

    /// Least-squares polynomial fit over the signal, subtracted -> drift compensation.
    static func detrendPoly(_ v: [Double], order: Int) -> [Double] {
        let n = v.count
        let m = order + 1
        guard n > m else { return v }
        var A = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        var b = [Double](repeating: 0, count: m)
        var pow = [Double](repeating: 0, count: m)
        for i in 0..<n {
            let u = 2 * Double(i) / Double(n - 1) - 1
            pow[0] = 1
            for k in 1..<m { pow[k] = pow[k - 1] * u }
            for r in 0..<m {
                b[r] += pow[r] * v[i]
                for c in 0..<m { A[r][c] += pow[r] * pow[c] }
            }
        }
        for c in 0..<m {                                    // Gauss-Jordan
            var p = c
            for r in (c + 1)..<m where abs(A[r][c]) > abs(A[p][c]) { p = r }
            A.swapAt(c, p)
            b.swapAt(c, p)
            if abs(A[c][c]) < 1e-12 { continue }
            for r in 0..<m where r != c {
                let f = A[r][c] / A[c][c]
                for k in c..<m { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        var coef = [Double](repeating: 0, count: m)
        for i in 0..<m { coef[i] = abs(A[i][i]) < 1e-12 ? 0 : b[i] / A[i][i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let u = 2 * Double(i) / Double(n - 1) - 1
            var fit = 0.0
            var p = 1.0
            for k in 0..<m { fit += coef[k] * p; p *= u }
            out[i] = v[i] - fit
        }
        return out
    }

    static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        guard window > 1, !x.isEmpty else { return x }
        let n = x.count
        let half = window / 2
        func at(_ i: Int) -> Double { x[min(n - 1, max(0, i))] }
        var out = [Double](repeating: 0, count: n)
        var sum = 0.0
        for k in -half..<(window - half) { sum += at(k) }
        for i in 0..<n {
            out[i] = sum / Double(window)
            sum += at(i + window - half) - at(i - half)
        }
        return out
    }

    /// Local maxima filtered by topographic prominence, then greedily thinned so that
    /// no two kept peaks are closer than `minDistance` samples (highest wins).
    static func findPeaks(_ x: [Double], minDistance: Int, minProminence: Double) -> [Int] {
        guard x.count > 2 else { return [] }
        var cand: [Int] = []
        for i in 1..<(x.count - 1) where x[i] > x[i - 1] && x[i] >= x[i + 1] {
            var l = x[i], r = x[i], j = i
            while j > 0 && x[j] <= x[i] { j -= 1; l = Swift.min(l, x[j]) }
            j = i
            while j < x.count - 1 && x[j] <= x[i] { j += 1; r = Swift.min(r, x[j]) }
            if x[i] - Swift.max(l, r) >= minProminence { cand.append(i) }
        }
        cand.sort { x[$0] > x[$1] }
        var kept: [Int] = []
        for i in cand where kept.allSatisfy({ abs($0 - i) >= minDistance }) {
            kept.append(i)
        }
        return kept.sorted()
    }

    /// Subtract a slow moving average, so the zero line follows the movement locally
    /// rather than being wherever the polynomial detrend happened to leave it.
    static func recentre(_ v: [Double], fs: Double, spanS: Double) -> [Double] {
        guard spanS > 0 else { return v }
        let base = movingAverage(v, window: Swift.max(1, Int((spanS * fs).rounded())))
        return (0..<v.count).map { v[$0] - base[$0] }
    }

    /// Split the velocity into concentric lobes: the peak inside each one, how far the
    /// load travelled over it, and whether the window cut it off.
    ///
    /// A repetition is one positive lobe bounded by zero crossings — the concentric
    /// phase, read off the same crossings the contraction phases are. Counting the lobe
    /// rather than the peaks inside it is what makes slow repetitions work: a slow lobe
    /// is broad and flat, and the ripples riding on it clear any fixed minimum spacing
    /// several times over while never crossing zero themselves. On real 8 s repetitions
    /// the peak detector returned 47 peaks for 13 repetitions.
    static func positiveLobes(_ v: [Double], fs: Double)
        -> (peaks: [Int], travel: [Double], atEdge: [Bool], bounds: [(Int, Int)]) {
        guard v.count > 3 else { return ([], [], [], []) }
        var starts: [Int] = []
        var ends: [Int] = []
        for i in 1..<v.count {
            if v[i] > 0 && v[i - 1] <= 0 { starts.append(i) }
            if v[i] <= 0 && v[i - 1] > 0 { ends.append(i) }
        }
        // A window that already starts inside a concentric phase has no rising crossing
        // before it, and one that stops inside one has no falling crossing after it.
        if v[0] > 0 { starts.insert(0, at: 0) }
        if v[v.count - 1] > 0 { ends.append(v.count) }
        guard !starts.isEmpty, !ends.isEmpty else { return ([], [], [], []) }
        if ends[0] < starts[0] { ends.removeFirst() }

        var peaks: [Int] = []
        var travel: [Double] = []
        var atEdge: [Bool] = []
        var bounds: [(Int, Int)] = []
        for k in 0..<Swift.min(starts.count, ends.count) {
            let a = starts[k], b = ends[k]
            if b - a < 3 { continue }
            var best = a
            for i in a..<b where v[i] > v[best] { best = i }
            // Trapezoid, matching the offline reference: with rectangles the two ports
            // drifted apart on a lobe that sat exactly on the threshold.
            var sum = 0.0
            if b - a > 1 {
                for i in a..<(b - 1) { sum += 0.5 * (v[i] + v[i + 1]) }
            }
            peaks.append(best)
            travel.append(sum / fs)
            atEdge.append(a == 0 || b >= v.count)
            bounds.append((a, b))
        }
        return (peaks, travel, atEdge, bounds)
    }

    /// Topographic prominence of one peak: how far it rises above the higher of the
    /// two valleys flanking it. The same measure `findPeaks` thresholds on, exposed
    /// so a confirmed repetition can record how pronounced it actually was.
    static func prominence(_ x: [Double], at i: Int) -> Double {
        guard i > 0, i < x.count - 1 else { return 0 }
        var l = x[i], r = x[i], j = i
        while j > 0 && x[j] <= x[i] { j -= 1; l = Swift.min(l, x[j]) }
        j = i
        while j < x.count - 1 && x[j] <= x[i] { j += 1; r = Swift.min(r, x[j]) }
        return x[i] - Swift.max(l, r)
    }

    static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s[Int(p * Double(s.count - 1))]
    }
}

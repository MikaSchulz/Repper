import Foundation

/// A synthetic set, fed through the same code path as real sensor data.
///
/// Used by the Demo button on the phone and by the watch whenever no accelerometer is
/// available (Simulator). The sequence is deliberately awkward: first the stack is lifted
/// into the starting position, then ten full repetitions with one that is only started
/// half way, and finally a repetition that no longer makes it up. A correct counter ends
/// at 10 — and gets there by withdrawing the opening lift once the set has shown what a
/// full repetition looks like.
enum DemoSignal {

    /// Stroke of each movement as a fraction of a full repetition.
    static let defaultStrokes: [Double] =
        [0.22] + Array(repeating: 1.0, count: 5) + [0.35]
        + Array(repeating: 1.0, count: 5) + [0.50]

    static func set(strokes: [Double] = defaultStrokes, fs: Double = 100.0)
        -> [MotionSample] {
        var v: [Double] = Array(repeating: 0, count: Int(0.8 * fs))

        func lobe(_ duration: Double, _ sign: Double, _ stroke: Double) {
            let n = Int(duration * fs)
            let amp = stroke / (2 / Double.pi) / duration
            for i in 0..<n { v.append(sign * amp * sin(Double.pi * Double(i) / Double(n))) }
        }

        for frac in strokes {
            lobe(1.2 * frac, 1, 0.35 * frac)                 // 0.35 m full stroke
            v.append(contentsOf: Array(repeating: 0, count: Int(0.15 * fs)))
            lobe(2.2 * frac, -1, 0.35 * frac)
            v.append(contentsOf: Array(repeating: 0, count: Int(0.20 * fs)))
        }
        // The set is followed by standing still, because that is where the counter used
        // to invent repetitions: the window still holds the set, so it does not look idle
        // as a whole, while the detrend drifts a bump into the quiet part.
        v.append(contentsOf: Array(repeating: 0, count: Int(20.0 * fs)))

        // specific force along an arbitrary phone pose: |f| == g + a_axis for any rotation
        let axis = (x: 0.30, y: -0.60, z: 0.74)
        return (0..<v.count).map { i in
            let a = (v[min(v.count - 1, i + 1)] - v[max(0, i - 1)]) * fs / 2
            let m = Signal.gravity + a
            let noise = { Double.random(in: -0.1...0.1) }
            return MotionSample(t: Double(i) / fs,
                                x: m * axis.x + noise(),
                                y: m * axis.y + noise(),
                                z: m * axis.z + noise())
        }
    }
}

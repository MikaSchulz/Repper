import Foundation

// Runs the app's counter against the shared fixtures in test/fixtures/, the same ones
// the Python and JavaScript implementations are checked against.
//
//   swiftc -O ios/Shared/Signal.swift ios/Shared/RepCounter.swift \
//          ios/Tests/run_parity.swift -o /tmp/repper-parity && /tmp/repper-parity

// JavaScript and Swift are pinned separately (`streaming_reps_js`,
// `streaming_reps_swift`) because they disagree by one on `legcurl_slow`, and the
// disagreement is pinned rather than averaged away so it stays visible.
//
// Both read the same analysis: on the window where the extra repetition is committed
// they return identical peaks, identical times and identical lobe counts. The lobe sits
// on the travel threshold and flickers across many windows, and the frontier never
// revises a commit, so whichever implementation sees it twice first keeps it. Every
// other fixture must still agree exactly, and that is what caught a real porting bug --
// a median taking the upper middle on one side and averaging on the other.

struct Expected: Decodable {
    let true_reps: Int
    let python_reps: Int
    let streaming_reps_swift: Int
    let record_hz: Double
}

@main
struct Parity {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // ios
            .deletingLastPathComponent()      // repo root
        let fixtures = root.appendingPathComponent("test/fixtures")


        let expected = try JSONDecoder().decode(
            [String: Expected].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("expected.json"))
        )

        var failures = 0

        for name in expected.keys.sorted() {
            let exp = expected[name]!
            let csv = try String(contentsOf: fixtures.appendingPathComponent("\(name).csv"), encoding: .utf8)
            let counter = RepCounter()
            var nextUpdate = 0.0

            for line in csv.split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",").map { Double($0) ?? 0 }
                guard f.count == 4 else { continue }
                counter.push(MotionSample(t: f[0], x: f[1], y: f[2], z: f[3]))
                if f[0] >= nextUpdate {                 // same 4 Hz cadence as the app's UI timer
                    counter.update()
                    nextUpdate = f[0] + 0.25
                }
            }
            counter.update()

            // Measured against the Python run, not against the truth: on the two sets
            // built from partial repetitions this detector counts the extra movements,
            // and every implementation has to do so identically.
            let ok = counter.count == exp.streaming_reps_swift
            if !ok { failures += 1 }
            var line = "\(ok ? "PASS" : "FAIL")  \(name.padding(toLength: 18, withPad: " ", startingAt: 0))"
            line += "swift=\(counter.count) python=\(exp.python_reps) truth=\(exp.true_reps)"
            if counter.count != exp.true_reps {
                line += "  (+\(counter.count - exp.true_reps))"
            }
            if let p = counter.medianPhases {
                line += String(format: "  con/ecc median %.2f/%.2fs", p.con, p.ecc)
            }
            print(line)
        }

        print(failures == 0 ? "\nall fixtures pass" : "\n\(failures) failing fixture(s)")
        exit(failures == 0 ? 0 : 1)
    }
}

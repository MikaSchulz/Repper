import Foundation

// Runs the app's counter against the shared fixtures in test/fixtures/, the same ones
// the Python and JavaScript implementations are checked against.
//
//   swiftc -O ios/Shared/Signal.swift ios/Shared/RepCounter.swift \
//          ios/Tests/run_parity.swift -o /tmp/repper-parity && /tmp/repper-parity

struct Expected: Decodable {
    let true_reps: Int
    let python_reps: Int
    let python_legacy: Int?
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

        // Written by test/js_parity.mjs: what the streaming counter in the browser got,
        // which is what this one has to reproduce — in legacy mode too, where streaming
        // legitimately differs from the offline pass in Python.
        struct Streaming: Decodable { let legacy: Int; let standard: Int }
        let streaming = (try? JSONDecoder().decode(
            [String: Streaming].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("streaming.json"))
        )) ?? [:]
        if streaming.isEmpty {
            print("Hinweis: streaming.json fehlt — erst `node test/js_parity.mjs` laufen lassen\n")
        }

        var failures = 0

        for name in expected.keys.sorted() {
            let exp = expected[name]!
            let csv = try String(contentsOf: fixtures.appendingPathComponent("\(name).csv"), encoding: .utf8)
            let counter = RepCounter()
            var legacyConfig = RepConfig.default
            legacyConfig.legacy = true
            let legacyCounter = RepCounter(config: legacyConfig)
            var nextUpdate = 0.0

            for line in csv.split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",").map { Double($0) ?? 0 }
                guard f.count == 4 else { continue }
                let sample = MotionSample(t: f[0], x: f[1], y: f[2], z: f[3])
                counter.push(sample)
                legacyCounter.push(sample)
                if f[0] >= nextUpdate {                 // same 4 Hz cadence as the app's UI timer
                    counter.update()
                    legacyCounter.update()
                    nextUpdate = f[0] + 0.25
                }
            }
            counter.update()
            legacyCounter.update()

            let legacyOk = streaming[name].map { legacyCounter.count == $0.legacy } ?? true
            let ok = counter.count == exp.true_reps && counter.count == exp.python_reps
                && legacyOk
            if !ok { failures += 1 }
            var line = "\(ok ? "PASS" : "FAIL")  \(name.padding(toLength: 18, withPad: " ", startingAt: 0))"
            line += "swift=\(counter.count) python=\(exp.python_reps) truth=\(exp.true_reps)"
            line += " | legacy swift=\(legacyCounter.count) "
            line += "js=\(streaming[name].map { String($0.legacy) } ?? "-")"
            if let p = counter.medianPhases {
                line += String(format: "  con/ecc median %.2f/%.2fs", p.con, p.ecc)
            }
            print(line)
        }

        print(failures == 0 ? "\nall fixtures pass" : "\n\(failures) failing fixture(s)")
        exit(failures == 0 ? 0 : 1)
    }
}

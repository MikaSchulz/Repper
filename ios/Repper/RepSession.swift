import Combine
import CoreMotion
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Owns the accelerometer stream and the counter, and publishes what the UI shows.
///
/// Tapping the screen during a set records what actually happened, so a recorded set
/// carries both the detector's answer and the reference to judge it by.
@MainActor
final class RepSession: ObservableObject {

    @Published private(set) var count = 0
    @Published private(set) var isRunning = false
    @Published private(set) var countdown: Int?               // nil unless the timer runs
    @Published private(set) var sampleCount = 0
    @Published private(set) var duration = 0.0
    @Published private(set) var measuredRate = 0.0
    @Published private(set) var phaseLabel = "—"
    @Published private(set) var phaseValue = 0                // -1 ecc, 0 pause, 1 con
    @Published private(set) var medianCon: Double?
    @Published private(set) var medianEcc: Double?
    @Published private(set) var velocity: [Double] = []        // for the live plot
    @Published private(set) var peaks: [Int] = []
    @Published private(set) var message: String?
    @Published private(set) var watchStatus = "—"

    /// Taps on the upper half of the screen: the top of a repetition.
    @Published private(set) var manualMarks: [Double] = []
    /// Taps on the lower half: the bottom, where the load is lowest and the next
    /// repetition begins. The two together bracket every repetition.
    @Published private(set) var manualBottoms: [Double] = []

    /// What this measurement series is: how the phone is held or placed, which machine,
    /// which tempo. Stamped onto every set recorded while it is set, so a run of twenty
    /// sets does not have to be labelled twenty times. Survives a restart.
    @Published var seriesLabel: String {
        didSet { UserDefaults.standard.set(seriesLabel, forKey: Self.labelKey) }
    }

    /// Seconds between tapping Start and the first sample, like a camera self-timer:
    /// time to put the phone on the stack and get into position.
    @Published var startDelay: Int {
        didSet { UserDefaults.standard.set(startDelay, forKey: Self.delayKey) }
    }

    let store = SetStore()

    private static let delayKey = "startDelaySeconds"
    private static let labelKey = "seriesLabel"

    private let motion = CMMotionManager()
    private let counter = RepCounter()
    private var recorded: [MotionSample] = []                  // full resolution, for export
    private var t0: Double?
    private var timer: Timer?
    private var demoTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var archived = true                                // current data already stored?
    private let link = PhoneLink()

    init() {
        startDelay = UserDefaults.standard.integer(forKey: Self.delayKey)
        seriesLabel = UserDefaults.standard.string(forKey: Self.labelKey) ?? ""
        link.onCommand = { [weak self] cmd in
            guard let self else { return }
            switch cmd {
            case "start": self.start()
            case "stop": self.stop()
            case "reset": self.reset()
            default: break
            }
        }
        link.onRecording = { [weak self] url, metadata in
            self?.storeWristRecording(url, metadata)
        }
        link.activate()
    }

    /// A recording handed over by the watch: raw motion including attitude, plus the two
    /// numbers typed in there. Nothing is counted — that happens later, off the device.
    private func storeWristRecording(_ url: URL, _ metadata: [String: Any]) {
        let name = "wrist_" + UUID().uuidString.prefix(8) + ".csv"
        let record = SetRecord(
            id: UUID(),
            date: Date(),
            duration: metadata[WristRecordingFile.Key.duration] as? Double ?? 0,
            sampleCount: metadata[WristRecordingFile.Key.sampleCount] as? Int ?? 0,
            measuredRate: 100,
            count: 0,
            repTimes: [],
            medianCon: nil,
            medianEcc: nil,
            trueReps: metadata[WristRecordingFile.Key.trueReps] as? Int,
            note: nil,
            rawFile: String(name),
            kind: "wrist",
            machine: metadata[WristRecordingFile.Key.machine] as? String
        )
        store.importFile(at: url, record: record)
        message = "Aufnahme von der Uhr empfangen: \(record.machine ?? "—")"
    }

    var hasRecording: Bool { !recorded.isEmpty }


    /// Re-checks the watch link. The counterpart app may have launched after this one.
    func refreshWatchLink() {
        link.activate()
        link.refreshStatus()
        watchStatus = link.linkStatus
    }

    // MARK: - Marking repetitions by hand

    /// One tap, one repetition. Recorded with the timestamp of the newest sample, so the
    /// mark sits on the same clock as the signal and can be matched against what the
    /// detector found — per repetition, not just as a total.
    enum MarkKind { case top, bottom }

    func mark(_ kind: MarkKind) {
        // Also during the demo, so the tapping can be tried out without a machine.
        guard isRunning || demoTask != nil, let t = recorded.last?.t else { return }
        switch kind {
        case .top: manualMarks.append(t)
        case .bottom: manualBottoms.append(t)
        }
        #if canImport(UIKit)
        // Distinct feel per half, so the right one can be hit without looking.
        UIImpactFeedbackGenerator(style: kind == .top ? .medium : .rigid).impactOccurred()
        #endif
    }

    /// Takes back the most recent tap, whichever half it was.
    func undoMark() {
        let lastTop = manualMarks.last ?? -.infinity
        let lastBottom = manualBottoms.last ?? -.infinity
        guard lastTop > -.infinity || lastBottom > -.infinity else { return }
        if lastTop >= lastBottom { manualMarks.removeLast() } else { manualBottoms.removeLast() }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    var manualBottomIndices: [Int] { indices(of: manualBottoms) }

    /// Indices into the displayed curve, so the taps can be drawn next to what the
    /// algorithm made of the same moment.
    var manualMarkIndices: [Int] { indices(of: manualMarks) }

    private func indices(of marks: [Double]) -> [Int] {
        guard let r = counter.last, let first = r.t.first,
              let last = r.t.last, !velocity.isEmpty else { return [] }
        let factor = max(1, r.vel.count / 400)
        let fs = RepConfig.default.fs
        return marks.compactMap { t in
            guard t >= first, t <= last else { return nil }
            return min(velocity.count - 1, Int(((t - first) * fs).rounded()) / factor)
        }
    }

    // MARK: - Control

    func start() {
        guard !isRunning, countdown == nil else { return }
        guard startDelay > 0 else {
            beginRecording()
            return
        }
        message = nil
        countdown = startDelay
        countdownTask = Task { @MainActor [weak self] in
            while let self, let value = self.countdown, value > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.countdown = value - 1
            }
            guard let self, !Task.isCancelled else { return }
            self.countdown = nil
            self.beginRecording()
        }
    }

    private func beginRecording() {
        guard motion.isAccelerometerAvailable else {
            message = "Kein Beschleunigungssensor verfügbar (Simulator?). Demo-Knopf nutzen."
            return
        }
        archiveIfNeeded()          // a previous set must not be overwritten silently
        clearCounters()
        manualMarks.removeAll()
        manualBottoms.removeAll()
        message = nil
        isRunning = true
        archived = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true       // display must stay on
        #endif

        // Raw accelerometer, NOT deviceMotion.userAcceleration: the counter needs the
        // gravity component. |a| - g is the signed acceleration along the stack axis,
        // which is what makes the phone's orientation on the stack irrelevant.
        motion.accelerometerUpdateInterval = 1.0 / 100.0
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            MainActor.assumeIsolated { self.ingest(d) }        // delivered on the main queue
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdown = nil
        demoTask?.cancel()
        guard isRunning else { return }
        motion.stopAccelerometerUpdates()
        timer?.invalidate()
        timer = nil
        isRunning = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        refresh()
        archiveIfNeeded()
    }

    func reset() {
        stop()
        archiveIfNeeded()          // Reset never throws a set away
        clearCounters()
        recorded.removeAll()
        manualMarks.removeAll()
        manualBottoms.removeAll()
        t0 = nil
        count = 0
        sampleCount = 0
        duration = 0
        measuredRate = 0
        phaseLabel = "—"
        phaseValue = 0
        medianCon = nil
        medianEcc = nil
        velocity = []
        peaks = []
        message = nil
        archived = true
    }

    private func clearCounters() {
        counter.reset()
        recorded.removeAll()
        t0 = nil
        count = 0
    }

    // MARK: - Recording

    /// One accelerometer sample: G units incl. gravity -> m/s^2, timestamps relative
    /// to the first sample of this recording.
    private func ingest(_ d: CMAccelerometerData) {
        let g = Signal.gravity
        if t0 == nil { t0 = d.timestamp }
        let sample = MotionSample(t: d.timestamp - (t0 ?? d.timestamp),
                                  x: d.acceleration.x * g,
                                  y: d.acceleration.y * g,
                                  z: d.acceleration.z * g)
        push(sample)
    }

    private func push(_ sample: MotionSample) {
        counter.push(sample)
        recorded.append(sample)
    }

    private func refresh() {
        let analysis = isRunning || demoTask != nil ? counter.update() : counter.last
        count = counter.count
        sampleCount = recorded.count
        duration = recorded.last?.t ?? 0

        if let r = analysis {
            measuredRate = r.rate
            velocity = Self.thin(r.vel, to: 400)
            let factor = max(1, r.vel.count / 400)
            peaks = counter.reps.compactMap { t in
                guard let first = r.t.first, let last = r.t.last, t >= first, t <= last
                else { return nil }
                return min(velocity.count - 1,
                           Int(((t - first) * RepConfig.default.fs).rounded()) / factor)
            }
            if let v = r.vel.last {
                let quiet = r.quiet || abs(v) < 0.02
                phaseValue = quiet ? 0 : (v > 0 ? 1 : -1)
                phaseLabel = quiet ? "pause" : (v > 0 ? "konzentrisch" : "exzentrisch")
            }
        }
        if let p = counter.medianPhases {
            medianCon = p.con
            medianEcc = p.ecc
        }
        link.publish(count: count, running: isRunning, phase: phaseValue)
        watchStatus = link.linkStatus
    }

    private static func thin(_ x: [Double], to maxCount: Int) -> [Double] {
        guard x.count > maxCount else { return x }
        let step = x.count / maxCount
        return stride(from: 0, to: x.count, by: step).map { x[$0] }
    }

    // MARK: - History

    /// Files the current set into the store. Called on Stop and before anything that
    /// would clear the buffers, so a mis-tapped Reset costs nothing.
    private func archiveIfNeeded() {
        guard !archived, recorded.count > Int(RepConfig.default.fs) else { return }
        archived = true
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "set_" + stamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "") + ".csv"
        let record = SetRecord(
            id: UUID(),
            date: Date(),
            duration: recorded.last?.t ?? 0,
            sampleCount: recorded.count,
            measuredRate: measuredRate,
            count: counter.count,
            repTimes: counter.reps.map { ($0 * 1000).rounded() / 1000 },
            medianCon: medianCon,
            medianEcc: medianEcc,
            trueReps: manualMarks.isEmpty ? nil : manualMarks.count,
            note: seriesLabel.isEmpty ? nil : seriesLabel,
            rawFile: name,
            manualMarks: manualMarks.map { ($0 * 1000).rounded() / 1000 },
            manualBottoms: manualBottoms.map { ($0 * 1000).rounded() / 1000 }
        )
        store.add(record, samples: recorded)
        message = "Satz gespeichert: \(record.count) Wdh."
    }

    // MARK: - Demo

    /// Replays `DemoSignal` at the same 4 Hz analysis cadence as a live set. Runs as a
    /// task that yields between chunks, so the counter visibly ticks up instead of
    /// freezing the UI — in a Debug build the analysis passes take a few seconds.
    func runDemo() {
        reset()
        message = "Demo läuft …"
        archived = false
        let samples = DemoSignal.set()
        demoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let chunk = Int(RepConfig.default.fs / 4)          // one analysis per 0.25 s
            for (i, sample) in samples.enumerated() {
                if Task.isCancelled { return }
                self.push(sample)
                if i % chunk == 0 {
                    self.refresh()
                    await Task.yield()                          // let SwiftUI draw
                }
            }
            self.refresh()
            self.archiveIfNeeded()
            self.message = "Demo: Hochnehmen + 10 volle + 2 halbe — erwartet: 10"
        }
    }

    // MARK: - Export of the set currently in memory

    func exportCSV() -> URL? {
        guard !recorded.isEmpty else { return nil }
        var text = "t,x,y,z\n"
        for s in recorded {
            text += String(format: "%.5f,%.5f,%.5f,%.5f\n", s.t, s.x, s.y, s.z)
        }
        let name = String(format: "repper_%.0fs_%dreps.csv", duration, count)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            message = "Export fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
    }
}

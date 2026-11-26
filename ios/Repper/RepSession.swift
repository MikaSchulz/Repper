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

    /// A tap on the taptic engine per counted repetition, so the count is readable
    /// without looking at a phone that is lying on a weight stack.
    @Published var vibrateOnRep: Bool {
        didSet {
            UserDefaults.standard.set(vibrateOnRep, forKey: Self.vibrateKey)
            feedback.vibrate = vibrateOnRep
        }
    }

    /// The count spoken aloud. Off by default: useful alone in a gym, less so otherwise.
    @Published var speakCount: Bool {
        didSet {
            UserDefaults.standard.set(speakCount, forKey: Self.speakKey)
            feedback.speak = speakCount
            if speakCount { feedback.prepare() } else { feedback.release() }
        }
    }

    /// Measurement mode shows the two tap zones; training mode is the plain counter.
    /// Sets are archived either way -- the history exists so a mis-tap on Reset costs
    /// nothing, and that is true in both modes. So is the label.
    @Published var isMeasuring: Bool {
        didSet { UserDefaults.standard.set(isMeasuring, forKey: Self.measureKey) }
    }

    /// What this measurement series is: how the phone is held or placed, which machine,
    /// which tempo. Stamped onto every set recorded while it is set, so a run of twenty
    /// sets does not have to be labelled twenty times. Survives a restart.
    @Published var seriesLabel: String {
        didSet { UserDefaults.standard.set(seriesLabel, forKey: Self.labelKey) }
    }

    /// The same thing for training: which exercise, what weight. Kept apart from
    /// `seriesLabel` because the two describe different things and the mode switch is
    /// one tap -- a shared field would stamp "Handy flach auf Stack" onto an evening of
    /// squats, and a wrong label is worse than none.
    @Published var exerciseLabel: String {
        didSet { UserDefaults.standard.set(exerciseLabel, forKey: Self.exerciseKey) }
    }

    /// Whichever of the two the current mode writes and stamps.
    var activeLabel: String {
        get { isMeasuring ? seriesLabel : exerciseLabel }
        set {
            if isMeasuring { seriesLabel = newValue } else { exerciseLabel = newValue }
        }
    }

    /// Seconds between tapping Start and the first sample, like a camera self-timer:
    /// time to put the phone on the stack and get into position.
    @Published var startDelay: Int {
        didSet { UserDefaults.standard.set(startDelay, forKey: Self.delayKey) }
    }

    let store = SetStore()

    private static let delayKey = "startDelaySeconds"
    private static let labelKey = "seriesLabel"
    private static let exerciseKey = "exerciseLabel"
    private static let measureKey = "isMeasuring"
    private static let vibrateKey = "vibrateOnRep"
    private static let speakKey = "speakCount"

    private let motion = CMMotionManager()
    private let counter = RepCounter()

    /// Sensor delivery runs off the main thread. At 100 Hz on the main queue every
    /// sample competes with SwiftUI redrawing the live plot, and a delayed callback
    /// carries a delayed timestamp -- the very error source the published study names
    /// for its own recordings. Samples land in `inbox` on the sensor queue and are
    /// drained on the main actor by the 0.25 s timer, in order.
    private let sensorQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "repper.accelerometer"
        q.maxConcurrentOperationCount = 1          // keep samples in order
        q.qualityOfService = .userInitiated
        return q
    }()
    private let inboxLock = NSLock()
    private nonisolated(unsafe) var inbox: [MotionSample] = []
    private var recorded: [MotionSample] = []                  // full resolution, for export
    /// Timestamp of the first sample of this recording. Written on the sensor queue,
    /// cleared on the main actor, so every access goes through `inboxLock`.
    private nonisolated(unsafe) var t0Raw: Double?
    private var timer: Timer?
    private var demoTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var archived = true                                // current data already stored?
    private let link = PhoneLink()
    private let feedback = Feedback()
    private var announced = 0              // repetitions already signalled

    init() {
        startDelay = UserDefaults.standard.integer(forKey: Self.delayKey)
        seriesLabel = UserDefaults.standard.string(forKey: Self.labelKey) ?? ""
        exerciseLabel = UserDefaults.standard.string(forKey: Self.exerciseKey) ?? ""
        isMeasuring = UserDefaults.standard.bool(forKey: Self.measureKey)
        // Absent means first launch, where the tap should be on.
        vibrateOnRep = UserDefaults.standard.object(forKey: Self.vibrateKey) as? Bool ?? true
        speakCount = UserDefaults.standard.bool(forKey: Self.speakKey)
        feedback.vibrate = vibrateOnRep
        feedback.speak = speakCount
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
        announced = 0
        feedback.prepare()

        // Raw accelerometer, NOT deviceMotion.userAcceleration: the counter needs the
        // gravity component. |a| - g is the signed acceleration along the stack axis,
        // which is what makes the phone's orientation on the stack irrelevant.
        motion.accelerometerUpdateInterval = 1.0 / 100.0
        motion.startAccelerometerUpdates(to: sensorQueue) { [weak self] data, _ in
            guard let self, let d = data else { return }
            self.buffer(d)
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
        feedback.release()
        archiveIfNeeded()
    }

    func reset() {
        stop()
        archiveIfNeeded()          // Reset never throws a set away
        clearCounters()
        recorded.removeAll()
        manualMarks.removeAll()
        manualBottoms.removeAll()
        clearInbox()
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
        clearInbox()
        count = 0
        announced = 0
    }

    private func clearInbox() {
        inboxLock.lock()
        inbox.removeAll(keepingCapacity: true)
        t0Raw = nil
        inboxLock.unlock()
    }

    // MARK: - Recording

    /// One accelerometer sample: G units incl. gravity -> m/s^2, timestamps relative
    /// to the first sample of this recording. Runs on the sensor queue, so it only
    /// parks the sample; nothing here touches published state.
    private nonisolated func buffer(_ d: CMAccelerometerData) {
        let g = Signal.gravity
        inboxLock.lock()
        if t0Raw == nil { t0Raw = d.timestamp }
        let origin = t0Raw ?? d.timestamp
        inbox.append(MotionSample(t: d.timestamp - origin,
                                  x: d.acceleration.x * g,
                                  y: d.acceleration.y * g,
                                  z: d.acceleration.z * g))
        inboxLock.unlock()
    }

    /// Hands everything the sensor queue parked since the last pass to the counter.
    private func drainInbox() {
        inboxLock.lock()
        let batch = inbox
        inbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()
        for s in batch { push(s) }
    }

    private func push(_ sample: MotionSample) {
        counter.push(sample)
        recorded.append(sample)
    }

    private func refresh() {
        drainInbox()
        let analysis = isRunning || demoTask != nil ? counter.update() : counter.last
        count = counter.count
        if count > announced {
            // One signal per repetition, even when a pass confirms several at once.
            while announced < count {
                announced += 1
                feedback.counted(announced)
            }
        } else if count < announced {
            announced = count          // a reset or a withdrawn repetition
        }
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
            note: activeLabel.isEmpty ? nil : activeLabel,
            rawFile: name,
            manualMarks: manualMarks.map { ($0 * 1000).rounded() / 1000 },
            manualBottoms: manualBottoms.map { ($0 * 1000).rounded() / 1000 },
            purpose: isMeasuring ? "measurement" : "training"
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
}

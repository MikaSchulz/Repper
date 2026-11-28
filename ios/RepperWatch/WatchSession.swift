import Combine
import CoreMotion
import Foundation
import HealthKit
import WatchKit

/// Two ways to use the watch during a set:
/// - `.mirror`: the phone lies on the weight stack and counts, the watch shows the count.
/// - `.standalone`: the watch itself lies on the stack and counts, no phone involved.
enum WatchMode: String, CaseIterable, Identifiable {
    case mirror
    case standalone
    case record

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mirror: return "Handy zählt"
        case .standalone: return "Uhr auf Block"
        case .record: return "Aufnahme"
        }
    }

    var next: WatchMode {
        switch self {
        case .mirror: return .standalone
        case .standalone: return .record
        case .record: return .mirror
        }
    }
}

@MainActor
final class WatchSession: WatchLink {

    @Published var mode: WatchMode = .mirror
    @Published private(set) var count = 0
    @Published private(set) var isRunning = false
    @Published private(set) var phase = 0            // -1 eccentric, 0 pause, 1 concentric
    @Published private(set) var message: String?

    private let motion = CMMotionManager()
    private var counter = RepCounter()
    private var timer: Timer?
    private var demoTask: Task<Void, Never>?
    private var t0: Double?
    private var lastCount = 0

    private let healthStore = HKHealthStore()
    private var workout: HKWorkoutSession?

    // MARK: Recording mode

    /// Taps made while recording: the top of a repetition and the bottom. They travel
    /// with the file, so a wrist recording can be checked repetition by repetition
    /// rather than only against a total typed in afterwards.
    @Published private(set) var marks: [Double] = []
    @Published private(set) var bottoms: [Double] = []

    @Published private(set) var recordedSamples = 0
    @Published private(set) var recordedSeconds = 0.0
    /// Set once a recording is finished: the watch then asks for the true count and the
    /// machine before sending it over, because a recording without those is unusable.
    @Published var pendingRecording: [WristSample]?
    @Published var pendingReps = 10
    @Published var pendingMachine = WristRecordingFile.machines[0]

    private var samples: [WristSample] = []

    /// Recordings written to disk and queued for the phone. They stay here until the
    /// transfer is confirmed, so a set recorded with the phone in a locker is not lost.
    @Published private(set) var pendingTransfers = 0

    private var pendingDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Switches between "the phone on the stack counts" and "this watch counts".
    /// Stops whatever is running first, so the two modes never overlap.
    func toggleMode() {
        if isRunning { stop() }
        mode = mode.next
        counter.reset()
        count = 0
        lastCount = 0
        phase = 0
        message = nil
    }

    // MARK: - Mirror mode (phone counts)

    override func handle(_ payload: [String: Any]) {
        guard mode == .mirror else { return }
        if let c = payload[LinkKey.count] as? Int {
            if c > count { tick() }
            count = c
        }
        if let r = payload[LinkKey.running] as? Bool { isRunning = r }
        if let p = payload[LinkKey.phase] as? Int { phase = p }
    }

    func command(_ name: String) {
        send([LinkKey.command: name])
        if name == "reset" { count = 0 }
    }

    // MARK: - Standalone mode (watch counts)

    /// One tap, one boundary of a repetition. Stamped with the newest sample's time so
    /// the mark sits on the same clock as the signal it is marking.
    func mark(top: Bool) {
        guard isRunning, mode == .record else { return }
        let t = samples.last?.t ?? recordedSeconds
        if top { marks.append(t) } else { bottoms.append(t) }
        WKInterfaceDevice.current().play(.click)
    }

    func undoMark() {
        let lastTop = marks.last ?? -1
        let lastBottom = bottoms.last ?? -1
        if lastTop >= lastBottom, !marks.isEmpty { marks.removeLast() }
        else if !bottoms.isEmpty { bottoms.removeLast() }
    }

    func start() {
        switch mode {
        case .mirror:
            command("start")
        case .standalone:
            startCounting()
        case .record:
            startRecording()
        }
    }

    func stop() {
        switch mode {
        case .mirror:
            command("stop")
        case .standalone:
            stopCounting()
        case .record:
            stopRecording()
        }
    }

    func reset() {
        counter.reset()
        count = 0
        lastCount = 0
        phase = 0
        message = nil
        if mode == .mirror { command("reset") }
    }

    private func startCounting() {
        guard motion.isAccelerometerAvailable else {
            runDemo()                    // Simulator has no accelerometer
            return
        }
        beginWorkout()                       // keeps the app alive with the wrist down
        isRunning = true
        t0 = nil
        message = nil

        // Raw accelerometer, gravity included — the counter needs it, see RepCounter.
        motion.accelerometerUpdateInterval = 1.0 / 100.0
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            MainActor.assumeIsolated { self.ingest(d) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }    // timers fire on the main run loop
        }
    }

    private func stopCounting() {
        demoTask?.cancel()
        demoTask = nil
        motion.stopAccelerometerUpdates()
        timer?.invalidate()
        timer = nil
        isRunning = false
        endWorkout()
    }

    private func ingest(_ d: CMAccelerometerData) {
        let g = Signal.gravity
        if t0 == nil { t0 = d.timestamp }
        counter.push(MotionSample(t: d.timestamp - (t0 ?? d.timestamp),
                                  x: d.acceleration.x * g,
                                  y: d.acceleration.y * g,
                                  z: d.acceleration.z * g))
    }

    private func refresh() {
        let r = counter.update()
        count = counter.count
        if count > lastCount {
            lastCount = count
            tick()
        }
        if let v = r?.vel.last, let quiet = r?.quiet {
            phase = quiet || abs(v) < 0.02 ? 0 : (v > 0 ? 1 : -1)
        }
    }

    /// Without a sensor there is still something worth checking: that the counter on the
    /// watch behaves exactly like the one on the phone. Replays the shared demo set.
    private func runDemo() {
        counter.reset()
        count = 0
        lastCount = 0
        isRunning = true
        message = "Demo (kein Sensor)"
        let samples = DemoSignal.set()
        demoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let chunk = Int(RepConfig.default.fs / 4)
            for (i, sample) in samples.enumerated() {
                if Task.isCancelled { return }
                self.counter.push(sample)
                if i % chunk == 0 {
                    self.refresh()
                    await Task.yield()
                }
            }
            self.refresh()
            self.isRunning = false
            self.message = "Demo: erwartet 10"
        }
    }

    /// A short haptic per repetition, so the count can be felt without looking.
    private func tick() {
        WKInterfaceDevice.current().play(.click)
    }

    // MARK: - Recording mode

    /// Writes down everything the watch knows about its own motion — including the
    /// attitude, which is what the phone recording lacks and what any wrist-worn
    /// detection needs. Nothing is counted here; the counting happens later, on a Mac,
    /// as often as the algorithm changes.
    private func startRecording() {
        guard motion.isDeviceMotionAvailable else {
            recordSynthetic()                    // Simulator has no motion hardware
            return
        }
        beginWorkout()
        samples.removeAll()
        marks.removeAll()
        bottoms.removeAll()
        recordedSamples = 0
        recordedSeconds = 0
        pendingRecording = nil
        isRunning = true
        t0 = nil
        message = nil

        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            MainActor.assumeIsolated { self.append(d) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordedSamples = self.samples.count
                self.recordedSeconds = self.samples.last?.t ?? 0
            }
        }
    }

    private func append(_ d: CMDeviceMotion) {
        if t0 == nil { t0 = d.timestamp }
        let q = d.attitude.quaternion
        samples.append(WristSample(
            t: d.timestamp - (t0 ?? d.timestamp),
            acc: (d.userAcceleration.x * Signal.gravity,
                  d.userAcceleration.y * Signal.gravity,
                  d.userAcceleration.z * Signal.gravity),
            quat: (q.w, q.x, q.y, q.z),
            rot: (d.rotationRate.x, d.rotationRate.y, d.rotationRate.z)))
    }

    private func stopRecording() {
        motion.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
        isRunning = false
        endWorkout()
        recordedSamples = samples.count
        recordedSeconds = samples.last?.t ?? 0
        guard samples.count > 100 else {
            message = "Zu kurz — nichts gespeichert"
            samples.removeAll()
            return
        }
        // The taps already say how many repetitions there were; the stepper starts
        // there rather than at whatever it held last.
        if !marks.isEmpty { pendingReps = marks.count }
        pendingRecording = samples        // now the watch asks for count and machine
    }

    /// Hands the finished recording to the phone, together with the two numbers that make
    /// it useful: how many repetitions it really was, and on which machine.
    func sendPendingRecording() {
        guard let samples = pendingRecording else { return }
        let name = "wrist_\(Int(Date().timeIntervalSince1970)).csv"
        let url = pendingDir.appendingPathComponent(name)
        let metadata: [String: Any] = [
            WristRecordingFile.Key.kind: "wrist",
            WristRecordingFile.Key.trueReps: pendingReps,
            WristRecordingFile.Key.machine: pendingMachine,
            WristRecordingFile.Key.duration: samples.last?.t ?? 0,
            WristRecordingFile.Key.sampleCount: samples.count,
            WristRecordingFile.Key.marks: marks.map { ($0 * 1000).rounded() / 1000 },
            WristRecordingFile.Key.bottoms: bottoms.map { ($0 * 1000).rounded() / 1000 },
        ]
        do {
            try WristRecordingFile.csv(samples).write(to: url, atomically: true, encoding: .utf8)
            let sidecar = url.appendingPathExtension("meta")
            try JSONSerialization.data(withJSONObject: metadata).write(to: sidecar)
        } catch {
            message = "Schreiben fehlgeschlagen: \(error.localizedDescription)"
            return
        }
        pendingRecording = nil
        self.samples.removeAll()
        marks.removeAll()
        bottoms.removeAll()
        message = "Gespeichert — wird ans Handy übertragen"
        sendQueued()
    }

    /// Queues everything still lying in `pending`. Called after a recording and whenever
    /// the app comes up, so a transfer that failed while the phone was away is retried.
    func sendQueued() {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        let recordings = files.filter { $0.pathExtension == "csv" }
        pendingTransfers = recordings.count
        for url in recordings {
            let sidecar = url.appendingPathExtension("meta")
            let metadata = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)))
                as? [String: Any] ?? [WristRecordingFile.Key.kind: "wrist"]
            transfer(file: url, metadata: metadata)
        }
    }

    override func finishedTransfer(_ url: URL, error: Error?) {
        guard error == nil else {
            message = "Übertragung fehlgeschlagen — bleibt gespeichert"
            return
        }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("meta"))
        pendingTransfers = max(0, pendingTransfers - 1)
        message = pendingTransfers == 0 ? "An Handy übertragen"
                                        : "\(pendingTransfers) Aufnahmen noch offen"
    }

    func discardPendingRecording() {
        pendingRecording = nil
        samples.removeAll()
        message = "Aufnahme verworfen"
    }

    /// Simulator fallback: a synthetic curl so the transfer path can be exercised.
    private func recordSynthetic() {
        message = "Kein Sensor — synthetische Aufnahme"
        var out: [WristSample] = []
        let fs = 100.0
        var clock = 0.0
        for _ in 0..<8 {
            for phase in [(1.3, 1.0), (2.0, -1.0)] {
                let n = Int(phase.0 * fs)
                for i in 0..<n {
                    let u = Double(i) / Double(n)
                    let angle = Double.pi * 0.5 * (phase.1 > 0 ? u : 1 - u)
                    let a = phase.1 * 1.4 * sin(Double.pi * u)
                    out.append(WristSample(t: clock + Double(i) / fs,
                                           acc: (a * cos(angle), 0.05, a * sin(angle)),
                                           quat: (cos(angle / 2), 0, sin(angle / 2), 0),
                                           rot: (0, phase.1 * 1.2, 0)))
                }
                clock += Double(n) / fs
            }
        }
        samples = out
        recordedSamples = out.count
        recordedSeconds = clock
        pendingRecording = out
    }

    // MARK: - Workout session

    /// watchOS suspends an ordinary app as soon as the wrist drops. A workout session
    /// keeps sensor delivery and the run loop alive for the length of the set.
    private func beginWorkout() {
        guard HKHealthStore.isHealthDataAvailable(), workout == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session.startActivity(with: Date())
            workout = session
        } catch {
            message = "Workout-Session nicht möglich: \(error.localizedDescription)"
        }
    }

    private func endWorkout() {
        workout?.end()
        workout = nil
    }

    func requestHealthAccess() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { _, _ in }
    }
}

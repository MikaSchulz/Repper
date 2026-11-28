import Foundation
import WatchConnectivity

/// What the phone sends to the watch, and what the watch sends back.
///
/// Keys are kept short and the payload flat: WatchConnectivity messages are dictionaries
/// of property-list types, and this one is sent several times per second while a set runs.
enum LinkKey {
    static let count = "c"          // Int   - repetitions counted so far
    static let running = "r"        // Bool  - phone is recording
    static let phase = "p"          // Int   - -1 eccentric, 0 pause, 1 concentric
    static let command = "cmd"      // String - "start" / "stop" / "reset" from the watch
}

/// Shared plumbing for both sides of the link. Subclasses fill in `handle`.
///
/// The class is main-actor isolated because both sides drive SwiftUI state from it; the
/// WCSessionDelegate callbacks arrive on a background queue and hop over explicitly.
@MainActor
class WatchLink: NSObject, ObservableObject, WCSessionDelegate {

    @Published private(set) var reachable = false
    @Published private(set) var linkStatus = "nicht aktiviert"

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    /// The last payload that went out, and when. Live values are offered several times
    /// a second; sending an unchanged one is work the system may answer by throttling
    /// the channel, which is the opposite of what a reliable link needs.
    private var lastSent: NSDictionary?
    private var lastSentAt = Date.distantPast

    func activate() {
        guard let session else {
            linkStatus = "WatchConnectivity nicht unterstützt"
            return
        }
        session.delegate = self
        session.activate()
        refreshStatus()
    }

    /// Why the link is or is not up — the counterpart app has to be installed, and on the
    /// phone side a watch has to be paired at all. Without this the UI can only say
    /// "not reachable", which covers half a dozen different causes.
    func refreshStatus() {
        guard let session else { return }
        var parts: [String] = []
        switch session.activationState {
        case .activated: parts.append("aktiv")
        case .inactive: parts.append("inaktiv")
        case .notActivated: parts.append("nicht aktiviert")
        @unknown default: parts.append("?")
        }
        #if os(iOS)
        parts.append(session.isPaired ? "gekoppelt" : "keine Uhr gekoppelt")
        parts.append(session.isWatchAppInstalled ? "App auf Uhr" : "App fehlt auf Uhr")
        #else
        parts.append(session.isCompanionAppInstalled ? "App auf Handy" : "App fehlt auf Handy")
        #endif
        parts.append(session.isReachable ? "erreichbar" : "nicht erreichbar")
        // Only publish on an actual change: this runs on every send, and writing to a
        // @Published property rebuilds the views observing it whether or not the value
        // differs.
        let next = parts.joined(separator: " · ")
        if next != linkStatus { linkStatus = next }
        if session.isReachable != reachable { reachable = session.isReachable }
    }

    /// Live values go out as a message when the counterpart is reachable, and as
    /// application context otherwise — context survives the counterpart being asleep,
    /// but only the most recent one is kept, which is exactly right for a counter.
    func send(_ payload: [String: Any]) {
        guard let session, session.activationState == .activated else { return }

        // Unchanged values are repeated once every two seconds and otherwise skipped.
        // The heartbeat matters because a dropped message leaves the counterpart
        // showing a stale count with nothing to correct it; without it, deduplication
        // would make that permanent.
        let snapshot = payload as NSDictionary
        let stale = Date().timeIntervalSince(lastSentAt) > 2
        guard snapshot != lastSent || stale else { return }
        lastSent = snapshot
        lastSentAt = Date()

        if session.isReachable {
            // A message that fails is simply gone, and the error used to be discarded.
            // Application context survives a sleeping counterpart and keeps only the
            // newest value, which is exactly what a counter wants.
            session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.sendAsContext(payload) }
                }
            }
        } else {
            sendAsContext(payload)
        }
        refreshStatus()
    }

    private func sendAsContext(_ payload: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(payload)
    }

    func handle(_ payload: [String: Any]) {}

    /// Queues a file for the counterpart. Transfers survive the app being closed and are
    /// retried by the system, which matters for a recording made in a gym basement.
    @discardableResult
    func transfer(file url: URL, metadata: [String: Any]) -> Bool {
        guard let session, session.activationState == .activated else { return false }
        session.transferFile(url, metadata: metadata)
        return true
    }

    /// Overridden on the phone to file an arriving recording.
    func receive(file url: URL, metadata: [String: Any]) {}

    /// Overridden on the watch: a queued transfer finished, successfully or not.
    func finishedTransfer(_ url: URL, error: Error?) {}

    // MARK: WCSessionDelegate (callbacks arrive off the main actor)

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshStatus() } }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshStatus() } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(message) } }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext context: [String: Any]) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(context) } }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer,
                             error: Error?) {
        let url = fileTransfer.file.fileURL
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finishedTransfer(url, error: error) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted as soon as this returns, so it has to be copied out of the
        // inbox synchronously here rather than on the main actor later.
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox_" + file.fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: inbox)
        try? FileManager.default.copyItem(at: file.fileURL, to: inbox)
        let metadata = file.metadata ?? [:]
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.receive(file: inbox, metadata: metadata) }
        }
    }

    #if os(iOS)
    /// Pairing, unpairing and installing the watch app all land here. Without it the
    /// status line stayed as it was until something else happened to refresh it, so the
    /// app could keep claiming there was no watch well after one had been paired.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshStatus() } }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()          // re-activate for the next paired watch
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.lastSent = nil     // the next watch has seen nothing yet
                self.refreshStatus()
            }
        }
    }
    #endif
}

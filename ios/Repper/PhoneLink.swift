import Foundation

/// Phone side of the watch link: pushes the live count out, takes commands back.
@MainActor
final class PhoneLink: WatchLink {
    /// Called on the main actor with "start", "stop" or "reset".
    var onCommand: ((String) -> Void)?

    /// Called with a recording that arrived from the watch.
    var onRecording: ((URL, [String: Any]) -> Void)?

    override func handle(_ payload: [String: Any]) {
        if let cmd = payload[LinkKey.command] as? String { onCommand?(cmd) }
    }

    override func receive(file url: URL, metadata: [String: Any]) {
        onRecording?(url, metadata)
    }

    func publish(count: Int, running: Bool, phase: Int) {
        send([LinkKey.count: count, LinkKey.running: running, LinkKey.phase: phase])
    }
}

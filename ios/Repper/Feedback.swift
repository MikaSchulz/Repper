import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tells the lifter a repetition was counted without them having to look at the screen.
///
/// Two reasons this matters beyond convenience. Mid-set the phone is on the weight stack
/// or in a hand that is busy, so the number on screen is unread. And during a measurement
/// run, feeling the detector's answer against your own sense of the repetition is the
/// only way to notice a miscount while it is still happening.
@MainActor
final class Feedback {

    var vibrate = true
    var speak = false

    #if canImport(UIKit)
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    #endif
    private let voice = AVSpeechSynthesizer()
    private var sessionReady = false

    /// Warms up the taptic engine so the first repetition is not the sluggish one, and
    /// claims an audio session that mixes rather than interrupting whatever is playing.
    func prepare() {
        #if canImport(UIKit)
        impact.prepare()
        #endif
        guard speak, !sessionReady else { return }
        // .playback rather than .ambient: the count has to be audible with the ringer
        // switch off, which is how a phone lives in a gym bag.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                         options: [.mixWithOthers,
                                                                   .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        sessionReady = true
    }

    func release() {
        voice.stopSpeaking(at: .immediate)
        guard sessionReady else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options:
                                                        .notifyOthersOnDeactivation)
        sessionReady = false
    }

    /// One confirmed repetition.
    func counted(_ number: Int) {
        #if canImport(UIKit)
        if vibrate {
            impact.impactOccurred()
            impact.prepare()                      // ready for the next one
        }
        #endif
        guard speak else { return }
        prepare()
        // A fast set can confirm the next repetition before the previous number is
        // finished. The current count is what matters, so the stale one is cut off.
        voice.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "\(number)")
        utterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.15
        voice.speak(utterance)
    }
}

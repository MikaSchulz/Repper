import Foundation

/// A named parameter set for the counter. Several of them run side by side on the same
/// sample stream, so a recorded set can be compared across algorithms afterwards instead
/// of guessing which threshold would have been right.
struct CounterVariant: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    let config: RepConfig

    static let all: [CounterVariant] = [
        CounterVariant(id: "A", label: "A · Standard", detail: "aktuelle Voreinstellung",
                       config: .default),
        CounterVariant(id: "B", label: "B · Original (Paper)",
                       detail: "ohne alle späteren Zusätze",
                       config: {
                           var c = RepConfig.default
                           c.legacy = true
                           return c
                       }()),
        CounterVariant(id: "C", label: "C · ROM 0,70", detail: "strengerer Bewegungsumfang",
                       config: {
                           var c = RepConfig.default
                           c.minRomFrac = 0.70
                           return c
                       }()),
        CounterVariant(id: "D", label: "D · Prominenz 0,20", detail: "empfindlichere Peaks",
                       config: {
                           var c = RepConfig.default
                           c.promFrac = 0.20
                           return c
                       }()),
    ]

    /// The one whose count the big display and the watch show.
    static var primary: CounterVariant { all[0] }

    static func == (a: CounterVariant, b: CounterVariant) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

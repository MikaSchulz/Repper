import Foundation

/// The parameter sets currently in use, editable at run time and kept across restarts.
///
/// `CounterVariant.all` defines identity and starting point; this store holds whatever
/// the parameters have been tweaked to since.
///
/// It also remembers which definition a stored set came from. Without that, changing a
/// variant's definition in the source would have no effect on a device that had already
/// saved the old one — the app would keep running the previous definition forever, and
/// the only hint would be the "edited" marker on a variant nobody ever edited.
@MainActor
final class VariantStore: ObservableObject {

    static let shared = VariantStore()

    @Published private(set) var configs: [String: RepConfig] = [:]

    /// The definition each stored config was derived from, to tell a new definition
    /// apart from a hand-tuned value.
    private var bases: [String: RepConfig] = [:]

    private static let configsKey = "variantConfigs"
    private static let basesKey = "variantBases"

    private init() {
        let stored = Self.load(Self.configsKey)
        bases = Self.load(Self.basesKey)

        for variant in CounterVariant.all {
            let definition = variant.config
            guard let saved = stored[variant.id] else {
                configs[variant.id] = definition          // nothing stored yet
                bases[variant.id] = definition
                continue
            }
            if let base = bases[variant.id], saved != base {
                configs[variant.id] = saved               // hand-tuned: keep it
            } else {
                configs[variant.id] = definition          // untouched: follow the source
            }
            bases[variant.id] = definition
        }
        save()
    }

    func config(for id: String) -> RepConfig {
        configs[id] ?? CounterVariant.all.first { $0.id == id }?.config ?? .default
    }

    func update(_ config: RepConfig, for id: String) {
        configs[id] = config
        save()
    }

    /// Back to the value the variant is defined with in the source.
    func reset(_ id: String) {
        configs[id] = CounterVariant.all.first { $0.id == id }?.config ?? .default
        save()
    }

    func isModified(_ id: String) -> Bool {
        guard let original = CounterVariant.all.first(where: { $0.id == id })?.config
        else { return false }
        return config(for: id) != original
    }

    private static func load(_ key: String) -> [String: RepConfig] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: RepConfig].self, from: data)) ?? [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.configsKey)
        }
        if let data = try? JSONEncoder().encode(bases) {
            UserDefaults.standard.set(data, forKey: Self.basesKey)
        }
    }
}

import Foundation

/// The parameter sets currently in use, editable at run time and kept across restarts.
///
/// `CounterVariant.all` defines identity and starting point; this store holds whatever
/// the parameters have been tweaked to since.
@MainActor
final class VariantStore: ObservableObject {

    static let shared = VariantStore()

    @Published private(set) var configs: [String: RepConfig] = [:]

    private static let key = "variantConfigs"

    private init() {
        let stored = (try? JSONDecoder().decode(
            [String: RepConfig].self,
            from: UserDefaults.standard.data(forKey: Self.key) ?? Data())) ?? [:]
        configs = Dictionary(uniqueKeysWithValues: CounterVariant.all.map {
            ($0.id, stored[$0.id] ?? $0.config)
        })
    }

    func config(for id: String) -> RepConfig {
        configs[id] ?? CounterVariant.all.first { $0.id == id }?.config ?? .default
    }

    func update(_ config: RepConfig, for id: String) {
        configs[id] = config
        save()
    }

    /// Back to the value the variant was defined with.
    func reset(_ id: String) {
        configs[id] = CounterVariant.all.first { $0.id == id }?.config ?? .default
        save()
    }

    func isModified(_ id: String) -> Bool {
        guard let original = CounterVariant.all.first(where: { $0.id == id })?.config
        else { return false }
        return config(for: id) != original
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

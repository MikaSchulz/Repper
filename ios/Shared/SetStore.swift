import Foundation

/// Keeps the last `limit` sets on disk: metadata in one JSON file, raw samples one CSV
/// per set. Small enough to stay simple, durable enough to survive a mis-tap on Reset.
@MainActor
final class SetStore: ObservableObject {

    @Published private(set) var records: [SetRecord] = []      // newest first

    private let limit: Int
    private let dir: URL
    private let indexURL: URL

    init(limit: Int = 10) {
        self.limit = limit
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("recordings", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    func rawURL(for record: SetRecord) -> URL { dir.appendingPathComponent(record.rawFile) }

    // MARK: - Mutating

    func add(_ record: SetRecord, samples: [MotionSample]) {
        var text = "t,x,y,z\n"
        text.reserveCapacity(samples.count * 32)
        for s in samples {
            text += String(format: "%.5f,%.5f,%.5f,%.5f\n", s.t, s.x, s.y, s.z)
        }
        try? text.write(to: dir.appendingPathComponent(record.rawFile), atomically: true,
                        encoding: .utf8)
        records.insert(record, at: 0)
        trim()
        save()
    }

    /// Files a recording that was produced elsewhere — currently the watch, which writes
    /// attitude alongside acceleration and does no counting of its own.
    func importFile(at source: URL, record: SetRecord) {
        let destination = dir.appendingPathComponent(record.rawFile)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        records.insert(record, at: 0)
        trim()
        save()
    }

    func setTrueReps(_ value: Int?, for record: SetRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[i].trueReps = value
        save()
    }

    func delete(_ record: SetRecord) {
        try? FileManager.default.removeItem(at: rawURL(for: record))
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Raw CSV plus a summary of every variant, ready to hand to the analysis scripts.
    func exportURLs(for record: SetRecord) -> [URL] {
        var urls = [rawURL(for: record)]
        let summary = dir.appendingPathComponent("summary_\(record.rawFile).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record), (try? data.write(to: summary)) != nil {
            urls.append(summary)
        }
        return urls
    }

    // MARK: - Persistence

    private func trim() {
        while records.count > limit {
            if let dropped = records.popLast() {
                try? FileManager.default.removeItem(at: rawURL(for: dropped))
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let all = try? decoder.decode([SetRecord].self, from: data) {
            records = all
            return
        }
        // One unreadable entry must not take the rest of the history with it.
        let items = (try? decoder.decode([FailableRecord].self, from: data)) ?? []
        records = items.compactMap(\.value)
    }

    /// Decodes a record, or nothing, without failing the surrounding array.
    private struct FailableRecord: Decodable {
        let value: SetRecord?

        init(from decoder: Decoder) throws {
            value = try? SetRecord(from: decoder)
        }
    }
}

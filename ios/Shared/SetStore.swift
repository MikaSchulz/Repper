import Foundation

/// Keeps the last `limit` sets on disk: metadata in one JSON file, raw samples one CSV
/// per set. Small enough to stay simple, durable enough to survive a mis-tap on Reset.
@MainActor
final class SetStore: ObservableObject {

    @Published private(set) var records: [SetRecord] = []      // newest first

    private let limit: Int
    private let dir: URL
    private let indexURL: URL

    /// A measurement series runs to a few dozen sets. Ten was enough to survive a
    /// mis-tap on Reset but would drop the first half of a data-collection session.
    init(limit: Int = 50) {
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

    /// How the phone was moved for this set, typed in by hand. Without it an export is
    /// a pile of numbers that cannot be told apart.
    func setNote(_ value: String?, for record: SetRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        records[i].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    /// The raw signal of a stored set, back as samples, so a past set can be re-analysed
    /// and drawn without going through an export.
    func samples(for record: SetRecord) -> [MotionSample] {
        guard let text = try? String(contentsOf: rawURL(for: record), encoding: .utf8)
        else { return [] }
        var out: [MotionSample] = []
        out.reserveCapacity(record.sampleCount)
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",")
            guard f.count >= 4,
                  let t = Double(f[0]), let x = Double(f[1]),
                  let y = Double(f[2]), let z = Double(f[3]) else { continue }
            out.append(MotionSample(t: t, x: x, y: y, z: z))
        }
        return out
    }

    /// Marks corrected after the fact. Tapping while lifting is rough -- the hand is busy
    /// and the tap lands late -- so the stored times are a first pass, not the reference.
    /// `trueReps` follows the top marks, which is the rule the recording already used.
    func setMarks(tops: [Double], bottoms: [Double], for record: SetRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[i].manualMarks = tops.sorted().map { ($0 * 1000).rounded() / 1000 }
        records[i].manualBottoms = bottoms.sorted().map { ($0 * 1000).rounded() / 1000 }
        records[i].trueReps = tops.isEmpty ? nil : tops.count
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

    /// Wipes the whole history in one go. A data-collection session leaves dozens of
    /// sets behind, and swiping them away one row at a time is its own small chore.
    /// Clearing the directory rather than just the records also takes the
    /// `summary_*.json` files that single-set exports leave lying around.
    func deleteAll() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: nil)) ?? []
        for file in contents where file != indexURL {
            try? fm.removeItem(at: file)
        }
        records.removeAll()
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

    /// Everything in one file: every raw CSV plus a single index carrying the counts,
    /// notes, taps and mode. Two files per set means forty files for twenty sets, each
    /// one a chance to lose track of which recording was which -- one archive is a single
    /// AirDrop that cannot come apart.
    ///
    /// Zipping goes through NSFileCoordinator's `.forUploading`, which hands back a
    /// zipped copy of a directory; Foundation offers no other archiver on iOS.
    func exportArchiveURL() -> URL? {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Repper", isDirectory: true)
        try? fm.removeItem(at: staging)
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil
        else { return nil }

        for record in records {
            let source = rawURL(for: record)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.copyItem(at: source, to: staging.appendingPathComponent(record.rawFile))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let index = try? encoder.encode(records) else { return nil }
        try? index.write(to: staging.appendingPathComponent("index.json"))

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let destination = fm.temporaryDirectory
            .appendingPathComponent("repper-\(stamp.string(from: Date())).zip")
        try? fm.removeItem(at: destination)

        var failure: NSError?
        var result: URL?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading,
                                       error: &failure) { zipped in
            if (try? fm.copyItem(at: zipped, to: destination)) != nil { result = destination }
        }
        return result
    }

    /// Bytes the archive will hold, for showing what is about to be shared.
    var totalBytes: Int {
        records.reduce(0) { sum, record in
            let path = rawURL(for: record).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return sum + ((attributes?[.size] as? Int) ?? 0)
        }
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

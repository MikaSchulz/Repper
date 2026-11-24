import Foundation

/// One recorded set, kept so an accidental Reset does not lose it and so the raw signal
/// can be exported and re-analysed later.
struct SetRecord: Codable, Identifiable {
    var id: UUID
    var date: Date
    var duration: Double                 // [s]
    var sampleCount: Int
    var measuredRate: Double             // [Hz]
    var count: Int                       // repetitions counted
    var repTimes: [Double]               // time of each counted repetition [s]
    var medianCon: Double?
    var medianEcc: Double?
    /// What actually happened, typed in by hand after the set. The reference every
    /// threshold gets tuned against — without it the recordings are just numbers.
    var trueReps: Int?
    var note: String?
    var rawFile: String                  // file name inside the recordings directory
    /// "stack" for a phone recording on the weight stack, "wrist" for a watch recording
    /// carrying attitude as well. Decoding an older record without the field yields
    /// "stack", which is what those all were.
    var kind: String = "stack"
    var machine: String?
    /// Times at which the screen was tapped during the set — one tap per repetition, put
    /// in by hand while lifting. The reference the detector is measured against: not just
    /// how many, but when.
    var manualMarks: [Double] = []
    /// Taps at the bottom of the movement, where the load is lowest and the next
    /// repetition starts. Together with `manualMarks` these bracket each repetition:
    /// bottom to top is the concentric phase, top to bottom the eccentric one.
    var manualBottoms: [Double] = []

    /// "measurement" for a set recorded to tune the detector -- tapped along, labelled,
    /// meant for export -- against "training" for ordinary use. Older records predate the
    /// distinction and decode as training, which is what they were.
    var purpose: String = "training"

    var isWrist: Bool { kind == "wrist" }
    var isMeasurement: Bool { purpose == "measurement" }

    init(id: UUID, date: Date, duration: Double, sampleCount: Int, measuredRate: Double,
         count: Int, repTimes: [Double], medianCon: Double?,
         medianEcc: Double?, trueReps: Int?, note: String?, rawFile: String,
         kind: String = "stack", machine: String? = nil, manualMarks: [Double] = [],
         manualBottoms: [Double] = [], purpose: String = "training") {
        self.id = id
        self.date = date
        self.duration = duration
        self.sampleCount = sampleCount
        self.measuredRate = measuredRate
        self.count = count
        self.repTimes = repTimes
        self.medianCon = medianCon
        self.medianEcc = medianEcc
        self.trueReps = trueReps
        self.note = note
        self.rawFile = rawFile
        self.kind = kind
        self.machine = machine
        self.manualMarks = manualMarks
        self.manualBottoms = manualBottoms
        self.purpose = purpose
    }

    /// Decoding tolerates missing keys instead of throwing.
    ///
    /// The synthesized decoder does not fall back to a property's default value: it
    /// demands every non-optional key. Adding one field would therefore make every
    /// previously stored set undecodable, and the whole history would silently come up
    /// empty on the next launch. It did, once.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        measuredRate = try c.decodeIfPresent(Double.self, forKey: .measuredRate) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        repTimes = try c.decodeIfPresent([Double].self, forKey: .repTimes) ?? []
        medianCon = try c.decodeIfPresent(Double.self, forKey: .medianCon)
        medianEcc = try c.decodeIfPresent(Double.self, forKey: .medianEcc)
        trueReps = try c.decodeIfPresent(Int.self, forKey: .trueReps)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        rawFile = try c.decodeIfPresent(String.self, forKey: .rawFile) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "stack"
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        manualMarks = try c.decodeIfPresent([Double].self, forKey: .manualMarks) ?? []
        manualBottoms = try c.decodeIfPresent([Double].self, forKey: .manualBottoms) ?? []
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? "training"
    }

    var shortDate: String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        return f.string(from: date)
    }
}

import SwiftUI

/// The last ten sets: what each algorithm counted, what actually happened, and the raw
/// signal to export. The hand-typed count is the reference the thresholds get tuned to.
struct HistoryView: View {
    @ObservedObject var store: SetStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView("Noch keine Sätze",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Aufgezeichnete Sätze landen "
                                                             + "hier automatisch — auch wenn "
                                                             + "du danach Reset drückst."))
                } else {
                    List {
                        ForEach(store.records) { record in
                            SetRow(record: record, store: store)
                        }
                        .onDelete { indexSet in
                            indexSet.map { store.records[$0] }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Verlauf")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                if !store.records.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(items: store.records.flatMap { store.exportURLs(for: $0) }) {
                            Label("Alle exportieren", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

private struct SetRow: View {
    let record: SetRecord
    @ObservedObject var store: SetStore
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.shortDate).font(.subheadline).foregroundStyle(.secondary)
                if record.isWrist {
                    Text(record.machine ?? "Handgelenk")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.25))
                        .clipShape(Capsule())
                }
                if !record.manualMarks.isEmpty {
                    Text("\(record.manualMarks.count)× getippt")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.25))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(String(format: "%.0f s · %d Samples · %.0f Hz",
                            record.duration, record.sampleCount, record.measuredRate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Carried over from the series label when the set was recorded, editable
            // afterwards: a mislabelled recording is worse than an unlabelled one.
            TextField("Wie bewegt? (z. B. Handy flach, Arm 90°)", text: $note, axis: .vertical)
                .font(.caption)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .onAppear { note = record.note ?? "" }
                .onChange(of: record.note) { _, new in
                    if new ?? "" != note { note = new ?? "" }
                }
                // Saved on every keystroke, not on submit: tapping away from the field
                // is the normal way to leave it, and that must not drop the text.
                .onChange(of: note) { _, new in store.setNote(new, for: record) }
                .submitLabel(.done)

            if record.isWrist {
                Text("Rohaufnahme mit Lage — wird am Rechner ausgewertet, nicht hier gezählt.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("gezählt").font(.footnote).foregroundStyle(.secondary)
                    Text("\(record.count)")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(colorForCount)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Text("Tatsächlich").font(.footnote)

                // The value has to live outside the Stepper: labelsHidden() would hide it.
                Text(record.trueReps.map(String.init) ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: 26, alignment: .leading)
                    .foregroundStyle(record.trueReps == nil ? .secondary : .primary)

                Stepper("Tatsächlich", value: Binding(
                    get: { record.trueReps ?? record.count },
                    set: { store.setTrueReps($0, for: record) }
                ), in: 0...100)
                .labelsHidden()

                Spacer()

                ShareLink(items: store.exportURLs(for: record)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Green once the count matches what was tapped in, orange when it does not.
    private var colorForCount: Color {
        guard let truth = record.trueReps else { return .primary }
        return record.count == truth ? .green : .orange
    }
}

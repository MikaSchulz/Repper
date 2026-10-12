import SwiftUI

/// Live tuning for one algorithm variant. Every change re-runs that variant over the set
/// already recorded, so the effect shows up on the curve in front of you rather than on
/// the next set.
struct VariantSettingsView: View {
    let variantID: String
    @ObservedObject var session: RepSession
    @ObservedObject private var store = VariantStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var config = RepConfig.default

    private var variant: CounterVariant? {
        CounterVariant.all.first { $0.id == variantID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("gezählt")
                        Spacer()
                        Text("\(session.variantCounts[variantID] ?? 0)")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                        if session.isReanalysing {
                            ProgressView().padding(.leading, 6)
                        }
                    }
                } header: {
                    Text(variant?.label ?? variantID)
                } footer: {
                    Text("Änderungen werden sofort auf den aufgezeichneten Satz angewendet.")
                }

                Section("Wiederholung erkennen") {
                    slider("Mindestabstand", value: $config.minRepS, range: 0.3...2.0,
                           step: 0.05, unit: "s",
                           hint: "Kürzer als das kann keine Wiederholung sein. "
                               + "Schnellste gemessene: 0,84 s.")
                    slider("Peak-Prominenz", value: $config.promFrac, range: 0.05...0.60,
                           step: 0.01, unit: "×",
                           hint: "Anteil am 90er-Perzentil der Geschwindigkeit. "
                               + "Kleiner = empfindlicher.")
                }

                Section("Bewegungsumfang") {
                    slider("Mindest-Hub", value: $config.minRomFrac, range: 0.0...1.0,
                           step: 0.05, unit: "×",
                           hint: "Anteil am Median des Satzes. 0 schaltet die Prüfung ab — "
                               + "dann zählt auch das Hochnehmen mit.")
                    slider("Bewertung ab", value: $config.romSettleS, range: 0.0...3.0,
                           step: 0.25, unit: "s",
                           hint: "Wartezeit nach dem Hub, bevor der Weg gemessen wird. "
                               + "Kürzer = schnellere Anzeige, unruhigere Zahl.")
                    slider("Gate aus ab Kadenz", value: $config.romMaxCadenceS,
                           range: 2.0...15.0, step: 0.5, unit: "s",
                           hint: "Bei langsameren Sätzen wird der Hub nicht mehr geprüft.")
                }

                Section("Signal") {
                    slider("Analysefenster", value: $config.windowS, range: 20...120,
                           step: 5, unit: "s",
                           hint: "Muss mehrere Wiederholungen umfassen.")
                    slider("Ruhe-Schwelle", value: $config.minSnr, range: 0.1...1.5,
                           step: 0.05, unit: "×",
                           hint: "Darunter gilt das Fenster als bewegungslos.")
                    Stepper(value: $config.sightings, in: 1...5) {
                        HStack {
                            Text("Sichtungen")
                            Spacer()
                            Text("\(config.sightings)").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: config.sightings) { _, _ in apply() }
                }

                Section {
                    Button("Auf Voreinstellung zurücksetzen", role: .destructive) {
                        store.reset(variantID)
                        config = store.config(for: variantID)
                        session.reanalyse(variantID: variantID)
                    }
                    .disabled(!store.isModified(variantID))
                }
            }
            .navigationTitle("Parameter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear { config = store.config(for: variantID) }
        }
    }

    /// Value shown live while dragging; the set is re-analysed once the finger lifts —
    /// re-running the whole recording on every pixel of travel would stutter.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, unit: String,
                        hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 0.1 ? "%.2f %@" : "%.1f %@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing { apply() }
            }
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func apply() {
        store.update(config, for: variantID)
        session.reanalyse(variantID: variantID)
    }
}

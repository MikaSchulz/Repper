import SwiftUI

/// Everything that is not needed while a set is running: handing data over, the watch
/// link, and the demo. Keeping these off the main screen leaves the counter, the plot
/// and the two tap zones, which are the only things worth looking at mid-set.
struct SettingsView: View {
    @ObservedObject var session: RepSession
    /// The sheet stays open while "alle löschen" empties the history, and `RepSession`
    /// does not republish its store's changes — so the store is observed in its own
    /// right, or the counts here would keep showing what was deleted a moment ago.
    @ObservedObject var store: SetStore
    @Environment(\.dismiss) private var dismiss

    init(session: RepSession) {
        _session = ObservedObject(wrappedValue: session)
        _store = ObservedObject(wrappedValue: session.store)
    }

    /// Built when the sheet opens so the share button is a single tap rather than
    /// "prepare", then "share".
    @State private var archive: URL?
    @State private var building = true
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                feedbackSection
                exportSection
                deleteSection
                watchSection
                demoSection
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task {
                archive = store.exportArchiveURL()
                building = false
            }
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        Section {
            Toggle("Vibration", isOn: $session.vibrateOnRep)
            Toggle("Zahl ansagen", isOn: $session.speakCount)
        } header: {
            Text("Rückmeldung pro Wiederholung")
        } footer: {
            Text("Mit dem Handy auf dem Stapel liest niemand den Zähler. Die Ansage "
                 + "spielt auch bei stummgeschaltetem Klingelton und mischt sich unter "
                 + "laufende Musik. Beides meldet erst, wenn der Zähler bestätigt hat — "
                 + "etwa eine halbe Sekunde nach der Wiederholung.")
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        Section {
            if store.records.isEmpty {
                Text("Noch keine Aufnahmen.").foregroundStyle(.secondary)
            } else if let archive {
                ShareLink(item: archive) {
                    Label("Alle Aufnahmen teilen", systemImage: "square.and.arrow.up")
                }
            } else if building {
                HStack {
                    ProgressView()
                    Text("Archiv wird gepackt …").foregroundStyle(.secondary)
                }
            } else {
                Text("Archiv konnte nicht gepackt werden.").foregroundStyle(.orange)
            }
        } header: {
            Text("Export")
        } footer: {
            if store.records.isEmpty {
                Text("Aufgezeichnete Sätze lassen sich hier als eine Datei an den Mac "
                     + "geben.")
            } else {
                Text("\(store.records.count) Sätze, \(sizeText) — eine ZIP-Datei mit "
                     + "allen Rohsignalen und einer index.json, die Zählung, Beschreibung, "
                     + "Tipps und Modus je Satz enthält. Per AirDrop an den Mac.")
            }
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes),
                                  countStyle: .file)
    }

    // MARK: - Delete

    /// Sits under the export on purpose: the only safe order is share first, then clear.
    @ViewBuilder
    private var deleteSection: some View {
        if !store.records.isEmpty {
            Section {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label {
                        Text("Alle Aufnahmen löschen")
                    } icon: {
                        // `.destructive` reddens the title but leaves the icon on the
                        // accent colour, which reads as a blue button with red text.
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
                .confirmationDialog("Alle \(store.records.count) Sätze löschen?",
                                    isPresented: $confirmingDelete,
                                    titleVisibility: .visible) {
                    Button("Endgültig löschen", role: .destructive) { deleteAll() }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Die Rohsignale sind danach weg und lassen sich nicht "
                         + "wiederherstellen. Erst teilen, dann löschen.")
                }
            } header: {
                Text("Aufräumen")
            } footer: {
                Text("Löscht alle \(store.records.count) Sätze samt Rohsignalen "
                     + "vom Gerät. Nach einer Messreihe ist das ein Tap statt fünfzig "
                     + "Wischern im Verlauf.")
            }
        }
    }

    /// The prepared archive points at files that are about to stop existing, so it goes
    /// with them rather than staying behind as a share button that hands over nothing.
    private func deleteAll() {
        store.deleteAll()
        archive = nil
        building = false
    }

    // MARK: - Watch

    private var watchSection: some View {
        Section {
            LabeledContent("Status", value: session.watchStatus)
            Button("Verbindung prüfen") { session.refreshWatchLink() }
        } header: {
            Text("Apple Watch")
        }
    }

    // MARK: - Demo

    private var demoSection: some View {
        Section {
            Button("Demo-Satz abspielen") {
                dismiss()
                session.runDemo()
            }
        } header: {
            Text("Demo")
        } footer: {
            Text("Spielt ein aufgezeichnetes Signal ab, ohne den Sensor. Enthält absichtlich "
                 + "ein Hochnehmen am Anfang und eine halbe Wiederholung am Ende — beide "
                 + "zählt die veröffentlichte Methode mit.")
        }
    }
}

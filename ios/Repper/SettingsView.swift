import SwiftUI

/// Everything that is not needed while a set is running: handing data over, the watch
/// link, and the demo. Keeping these off the main screen leaves the counter, the plot
/// and the two tap zones, which are the only things worth looking at mid-set.
struct SettingsView: View {
    @ObservedObject var session: RepSession
    @Environment(\.dismiss) private var dismiss

    /// Built when the sheet opens so the share button is a single tap rather than
    /// "prepare", then "share".
    @State private var archive: URL?
    @State private var building = true

    var body: some View {
        NavigationStack {
            List {
                exportSection
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
                archive = session.store.exportArchiveURL()
                building = false
            }
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        Section {
            if session.store.records.isEmpty {
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
            Text("\(session.store.records.count) Sätze, \(sizeText) — eine ZIP-Datei mit "
                 + "allen Rohsignalen und einer index.json, die Zählung, Beschreibung, "
                 + "Tipps und Modus je Satz enthält. Per AirDrop an den Mac.")
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(session.store.totalBytes),
                                  countStyle: .file)
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

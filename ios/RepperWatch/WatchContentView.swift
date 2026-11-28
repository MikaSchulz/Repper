import SwiftUI

struct WatchContentView: View {
    @StateObject private var session = WatchSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if session.pendingRecording != nil {
            recordingForm
        } else {
            main
        }
    }

    /// After a recording the watch asks for the two things that make it usable: how many
    /// repetitions it really was, and which machine. Without them the file is just noise.
    private var recordingForm: some View {
        NavigationStack {
            recordingFormBody
        }
    }

    private var recordingFormBody: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Aufnahme fertig")
                    .font(.headline)
                Text(String(format: "%.0f s · %d Samples",
                            session.recordedSeconds, session.recordedSamples))
                    .font(.caption2).foregroundStyle(.secondary)

                Stepper(value: $session.pendingReps, in: 0...50) {
                    VStack(spacing: 0) {
                        Text("\(session.pendingReps)")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                        Text("Wiederholungen").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // A wheel picker would swallow the scroll gesture and bury the send
                // button; this style pushes a proper list instead.
                Picker("Maschine", selection: $session.pendingMachine) {
                    ForEach(WristRecordingFile.machines, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)

                Button("An Handy senden") { session.sendPendingRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                Button("Verwerfen", role: .destructive) { session.discardPendingRecording() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 4)
        }
    }

    private var main: some View {
        VStack(spacing: 6) {
            if session.mode == .record {
                if session.isRunning {
                    tapZones
                } else {
                    Text(String(format: "%.0f s", session.recordedSeconds))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("BEREIT").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("\(session.count)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    // No phase word underneath: whether this moment is the way up or
                    // the way down is something the lifter knows better than the watch.
                    // The colour is enough to show that the counter is following along.
                    .foregroundStyle(session.phase == 1 ? Color.green : Color.primary)
            }

            // A tap toggles the mode. A Picker would need the Digital Crown, which is
            // awkward with a barbell in the other hand.
            Button {
                session.toggleMode()
            } label: {
                Text(session.mode.label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(tintForMode)

            HStack(spacing: 6) {
                Button(session.isRunning ? "Stop" : "Start") {
                    session.isRunning ? session.stop() : session.start()
                }
                .tint(session.isRunning ? .gray : .green)

                Button("Reset") { session.reset() }
                    .tint(.gray)
            }
            .buttonStyle(.borderedProminent)

            if let m = session.message {
                Text(m).font(.caption2).foregroundStyle(.orange)
            } else if session.mode == .record {
                Text(session.pendingTransfers > 0
                     ? "\(session.pendingTransfers) Aufnahme(n) warten aufs Handy"
                     : "zeichnet Lage + Beschleunigung auf")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if session.mode == .mirror {
                Text(session.linkStatus)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(session.reachable ? Color.secondary : Color.orange)
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            session.activate()
            session.requestHealthAccess()
            session.sendQueued()            // retry anything the phone has not taken yet
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.refreshStatus() }
        }
    }

    private var tintForMode: Color {
        switch session.mode {
        case .mirror: return .gray
        case .standalone: return .blue
        case .record: return .red
        }
    }

    /// Two targets filling the screen while a recording runs: the top of a repetition
    /// and the bottom. A wrist recording could only ever be checked against a total
    /// typed in afterwards; tapped boundaries say when each repetition happened, which
    /// is what the detector has to be measured against.
    private var tapZones: some View {
        VStack(spacing: 4) {
            zone("OBEN", count: session.marks.count, tint: .blue) { session.mark(top: true) }
            zone("UNTEN", count: session.bottoms.count, tint: .orange) { session.mark(top: false) }
        }
        .overlay(alignment: .topTrailing) {
            if !(session.marks.isEmpty && session.bottoms.isEmpty) {
                Button { session.undoMark() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
    }

    private func zone(_ title: String, count: Int, tint: Color,
                      _ action: @escaping () -> Void) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(tint.opacity(0.25))
            .overlay {
                VStack(spacing: 0) {
                    Text("\(count)").font(.title3.weight(.bold)).monospacedDigit()
                    Text(title).font(.system(size: 10)).tracking(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

#Preview {
    WatchContentView()
}

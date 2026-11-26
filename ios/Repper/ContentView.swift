import SwiftUI

struct ContentView: View {
    @StateObject private var session = RepSession()
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showLabelEditor = false
    @State private var labelDraft = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 10) {
            modePicker

            // Measurement mode only: the upper zone marks the top of a repetition, the
            // lower one the bottom where the load is lowest and the next begins. Two taps
            // bracket a repetition, which is what makes the count checkable at all.
            // Training mode drops both -- with the phone on the stack they cannot be
            // reached anyway, and the plot gets the room.
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    counter
                    VelocityPlot(values: session.velocity, peaks: session.peaks,
                                 manualMarks: session.manualMarkIndices,
                                 manualBottoms: session.manualBottomIndices)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) { markBadge }
                        .overlay(alignment: .bottom) {
                            if session.isMeasuring { zoneHint }
                        }
                }
                .contentShape(Rectangle())
                .onTapGesture { if session.isMeasuring { session.mark(.top) } }

                if session.isMeasuring {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.orange.opacity(session.isRunning ? 0.20 : 0.07))
                        .frame(height: 190)
                        .overlay { zoneLabel("UNTEN", "arrow.down.to.line", .orange) }
                        .contentShape(Rectangle())
                        .onTapGesture { session.mark(.bottom) }
                        .padding(.top, 6)
                }
            }

            if let message = session.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            stats
            seriesStrip
            secondaryControls
            startButton
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHistory) { HistoryView(store: session.store) }
        .sheet(isPresented: $showSettings) { SettingsView(session: session) }
        .alert(session.isMeasuring ? "Messreihe" : "Übung",
               isPresented: $showLabelEditor) {
            TextField(session.isMeasuring ? "z. B. Handy flach auf Stack, langsam"
                                          : "z. B. Lat Pulldown 60 kg",
                      text: $labelDraft)
            Button("Sichern") { session.activeLabel = labelDraft }
            Button("Leeren", role: .destructive) { session.activeLabel = "" }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text(session.isMeasuring
                 ? "Wird auf jeden Satz gestempelt, bis du sie änderst. "
                   + "Beschreib, wie das Handy liegt und wie du dich bewegst."
                 : "Wird auf jeden Satz gestempelt, bis du sie änderst. "
                   + "Übung und Gewicht reichen, um den Satz später dem Training "
                   + "zuzuordnen.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.refreshWatchLink() }
        }
    }

    // MARK: - Count

    private var counter: some View {
        VStack(spacing: 0) {
            if let seconds = session.countdown {
                Text("\(seconds)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                Text("START IN").font(.caption2).tracking(2).foregroundStyle(.secondary)
            } else {
                Text("\(session.count)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(session.phaseLabel.uppercased())
                    .font(.caption2).tracking(2).foregroundStyle(.secondary)
            }
        }
    }

    /// Names the upper tap zone. The boundary between the two has to be readable at a
    /// glance mid-set, without looking properly.
    private var zoneHint: some View {
        zoneLabel("OBEN", "arrow.up.to.line", .blue)
            .padding(.bottom, 6)
    }

    private func zoneLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).tracking(3)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(session.isRunning ? tint : Color.secondary.opacity(0.45))
    }

    /// Shows how many taps went in, and takes the last one back after a mis-tap.
    @ViewBuilder
    private var markBadge: some View {
        if session.isRunning || !session.manualMarks.isEmpty
            || !session.manualBottoms.isEmpty {
            HStack(spacing: 6) {
                if !session.manualMarks.isEmpty || !session.manualBottoms.isEmpty {
                    Button {
                        session.undoMark()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                            .padding(6)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                Text("\(session.manualMarks.count) oben")
                    .font(.caption2).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.25))
                    .clipShape(Capsule())
                Text("\(session.manualBottoms.count) unten")
                    .font(.caption2).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.25))
                    .clipShape(Capsule())
            }
            .padding(8)
        }
    }

    // MARK: - Variant picker

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 12) {
            statItem(session.measuredRate > 0
                     ? String(format: "%.0f Hz", session.measuredRate) : "—", "Rate")
            statItem(String(format: "%.0f s", session.duration), "Dauer")
            statItem(phaseText, "con / ecc")
        }
        .font(.caption2)
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).monospacedDigit().foregroundStyle(.primary)
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var phaseText: String {
        guard let c = session.medianCon, let e = session.medianEcc else { return "—" }
        return String(format: "%.1f / %.1f", c, e)
    }

    // MARK: - Controls

    private var secondaryControls: some View {
        HStack(spacing: 6) {
            smallButton("Timer", session.startDelay == 0 ? "aus" : "\(session.startDelay)s") {
                session.startDelay = nextDelay(after: session.startDelay)
            }
            smallButton("Verlauf", "\(session.store.records.count)") { showHistory = true }
            smallButton("Reset", nil) { session.reset() }
            smallButton("Mehr", nil) { showSettings = true }
        }
    }

    /// Training counts and nothing else. Measurement adds the tap zones and marks the
    /// set as reference data in the history. Both modes carry a label.
    private var modePicker: some View {
        Picker("Modus", selection: $session.isMeasuring) {
            Text("Training").tag(false)
            Text("Messung").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(session.isRunning || session.countdown != nil)
    }

    /// What gets stamped onto the next recorded set. Sits above the Start button so it
    /// is read right before a set, which is the moment a stale label would do damage.
    ///
    /// In training it names the exercise, in measurement the series: in both cases it is
    /// the one thing that lets a stored set be placed afterwards, and a set of squats is
    /// no easier to recognise from its raw signal than a test run is.
    private var seriesStrip: some View {
        Button {
            labelDraft = session.activeLabel
            showLabelEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.activeLabel.isEmpty
                      ? "tag" : "tag.fill")
                    .font(.caption2)
                Text(session.activeLabel.isEmpty
                     ? (session.isMeasuring ? "Messreihe benennen" : "Übung benennen")
                     : session.activeLabel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "pencil").font(.caption2)
            }
            .foregroundStyle(session.activeLabel.isEmpty ? Color.secondary : Color.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func nextDelay(after value: Int) -> Int {
        let steps = [0, 3, 5, 10, 15]
        let i = steps.firstIndex(of: value) ?? 0
        return steps[(i + 1) % steps.count]
    }

    private func smallButton(_ title: String, _ detail: String?,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(title, detail) }.buttonStyle(.plain)
    }

    private func controlLabel(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The one control that has to be hit while lying on a bench: full width, thumb-sized.
    private var startButton: some View {
        Button {
            if session.isRunning || session.countdown != nil {
                session.stop()
            } else {
                session.start()
            }
        } label: {
            Text(startTitle)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(startColor)
                .foregroundStyle(session.isRunning || session.countdown != nil
                                 ? Color.white : Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var startTitle: String {
        if session.countdown != nil { return "Abbrechen" }
        if session.isRunning { return "Stop" }
        return session.startDelay > 0 ? "Start · \(session.startDelay)s" : "Start"
    }

    private var startColor: Color {
        if session.countdown != nil { return .orange }
        return session.isRunning ? Color.red.opacity(0.85) : .green
    }
}

/// Live velocity trace of the selected algorithm, with the repetitions it counted marked.
struct VelocityPlot: View {
    let values: [Double]
    let peaks: [Int]
    var manualMarks: [Int] = []
    var manualBottoms: [Int] = []

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lo = (values.min() ?? -1)
            let hi = (values.max() ?? 1)
            let span = max(hi - lo, 0.0001)
            let x = { (i: Int) in Double(i) / Double(max(values.count - 1, 1)) * w }
            let y = { (v: Double) in h - (v - lo) / span * h }

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04))

                if values.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(0)))
                        p.addLine(to: CGPoint(x: w, y: y(0)))
                    }
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)

                    Path { p in
                        p.move(to: CGPoint(x: x(0), y: y(values[0])))
                        for i in 1..<values.count {
                            p.addLine(to: CGPoint(x: x(i), y: y(values[i])))
                        }
                    }
                    .stroke(Color.green, lineWidth: 2)

                    ForEach(peaks.filter { $0 < values.count }, id: \.self) { i in
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                            .position(x: x(i), y: y(values[i]))
                    }

                    // taps, on their own lines: tops just under the curve's own peaks,
                    // bottoms along the lower edge — the same order as the movement
                    ForEach(manualMarks.filter { $0 < values.count }, id: \.self) { i in
                        Rectangle().fill(Color.blue)
                            .frame(width: 2, height: 14)
                            .position(x: x(i), y: 10)
                    }
                    ForEach(manualBottoms.filter { $0 < values.count }, id: \.self) { i in
                        Rectangle().fill(Color.orange)
                            .frame(width: 2, height: 14)
                            .position(x: x(i), y: h - 8)
                    }
                } else {
                    Text("Geschwindigkeit (integriert)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

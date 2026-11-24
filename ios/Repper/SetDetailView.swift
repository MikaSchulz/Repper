import SwiftUI

/// One stored set, re-analysed and drawn: the velocity curve, the repetitions the
/// detector counted, and the marks tapped in while lifting -- on top of each other.
///
/// The marks can be moved, added and deleted here. Tapping during a set is rough: the
/// hand is busy and the tap lands late, so what gets stored is a first pass. Correcting
/// it against the curve is what turns a recording into a reference the detector can
/// actually be measured against.
struct SetDetailView: View {
    let record: SetRecord
    @ObservedObject var store: SetStore

    @State private var analysis: Analysis?
    @State private var tops: [Double] = []
    @State private var bottoms: [Double] = []
    @State private var selected: Mark?
    @State private var loading = true
    /// Time the mark being dragged started at, so the drag works off its own
    /// translation; absolute hit locations shift meaning depending on where in the
    /// modifier chain `.position` sits, and that is not worth depending on.
    @State private var dragOrigin: Double?

    struct Mark: Equatable {
        var isTop: Bool
        var index: Int
    }

    private let plotHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView("Signal wird ausgewertet …")
                        .frame(maxWidth: .infinity, minHeight: plotHeight)
                } else if analysis == nil {
                    Text("Rohsignal nicht lesbar.")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: plotHeight)
                } else {
                    plot
                    legend
                    editor
                }
                counts
            }
            .padding()
        }
        .navigationTitle(record.shortDate)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let samples = store.samples(for: record)
            analysis = RepCounter.analyse(samples)
            tops = record.manualMarks
            bottoms = record.manualBottoms
            loading = false
        }
    }

    // MARK: - Plot

    private var plot: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
                curve(in: geo.size)
                zeroLine(in: geo.size)
                ForEach(countedTimes, id: \.self) { t in
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                        .position(x: xFor(t, geo.size.width), y: yFor(t, geo.size.height))
                }
                marks(isTop: true, times: tops, in: geo.size)
                marks(isTop: false, times: bottoms, in: geo.size)
            }
            // A tap away from every mark adds one: upper half top, lower half bottom,
            // the same split as the two tap zones during a set.
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                addMark(at: value.location, in: geo.size)
            })
        }
        .frame(height: plotHeight)
    }

    private func curve(in size: CGSize) -> some View {
        Path { path in
            guard let a = analysis, a.vel.count > 1 else { return }
            let step = max(1, a.vel.count / Int(size.width * 2))
            var first = true
            for i in stride(from: 0, to: a.vel.count, by: step) {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(a.vel.count - 1),
                                y: yForValue(a.vel[i], size.height))
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
            }
        }
        .stroke(Color.green, lineWidth: 2)
    }

    private func zeroLine(in size: CGSize) -> some View {
        Path { p in
            let y = yForValue(0, size.height)
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
    }

    /// One draggable handle per mark. Top marks hang from the top edge, bottom marks
    /// stand on the bottom one, so the two never overlap and can be told apart at a
    /// glance while dragging.
    private func marks(isTop: Bool, times: [Double], in size: CGSize) -> some View {
        ForEach(Array(times.enumerated()), id: \.offset) { index, t in
            let mark = Mark(isTop: isTop, index: index)
            let isSelected = selected == mark
            let x = xFor(t, size.width)
            let tint: Color = isTop ? .blue : .orange

            ZStack {
                Rectangle()
                    .fill(tint.opacity(isSelected ? 0.95 : 0.55))
                    .frame(width: isSelected ? 3 : 2, height: size.height)
                Circle()
                    .fill(tint)
                    .frame(width: isSelected ? 26 : 20, height: isSelected ? 26 : 20)
                    .overlay(Circle().stroke(.white.opacity(isSelected ? 0.9 : 0.3),
                                             lineWidth: isSelected ? 2 : 1))
                    .offset(y: isTop ? -size.height / 2 + 13 : size.height / 2 - 13)
            }
            .frame(width: 44, height: size.height)   // finger-sized grab area
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if selected != mark { selected = mark; dragOrigin = t }
                        let base = dragOrigin ?? t
                        setTime(mark, base + secondsPerPoint(size.width)
                                * Double(value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil; persist() }
            )
            .position(x: x, y: size.height / 2)
        }
    }

    // MARK: - Geometry

    private var span: (first: Double, last: Double)? {
        guard let a = analysis, let f = a.t.first, let l = a.t.last, l > f else { return nil }
        return (f, l)
    }

    private func xFor(_ t: Double, _ width: CGFloat) -> CGFloat {
        guard let s = span else { return 0 }
        return width * CGFloat((t - s.first) / (s.last - s.first))
    }

    private func timeFor(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard let s = span, width > 0 else { return 0 }
        let frac = min(1, max(0, Double(x / width)))
        return s.first + frac * (s.last - s.first)
    }

    private func yForValue(_ v: Double, _ height: CGFloat) -> CGFloat {
        guard let a = analysis else { return height / 2 }
        let scale = max(a.vel.map(abs).max() ?? 1, 1e-6)
        return height / 2 - CGFloat(v / scale) * (height / 2 - 14)
    }

    private func yFor(_ t: Double, _ height: CGFloat) -> CGFloat {
        guard let a = analysis, let s = span, a.vel.count > 1 else { return height / 2 }
        let frac = (t - s.first) / (s.last - s.first)
        let i = min(a.vel.count - 1, max(0, Int(frac * Double(a.vel.count - 1))))
        return yForValue(a.vel[i], height)
    }

    private var countedTimes: [Double] { record.repTimes }

    // MARK: - Editing

    private func secondsPerPoint(_ width: CGFloat) -> Double {
        guard let s = span, width > 0 else { return 0 }
        return (s.last - s.first) / Double(width)
    }

    private func setTime(_ mark: Mark, _ value: Double) {
        guard let s = span else { return }
        let t = min(s.last, max(s.first, value))
        if mark.isTop {
            guard tops.indices.contains(mark.index) else { return }
            tops[mark.index] = t
        } else {
            guard bottoms.indices.contains(mark.index) else { return }
            bottoms[mark.index] = t
        }
    }

    private func addMark(at point: CGPoint, in size: CGSize) {
        let t = timeFor(point.x, size.width)
        let isTop = point.y < size.height / 2
        // Near an existing mark this is a selection, not a new mark: otherwise every
        // attempt to grab one would leave a duplicate behind.
        let nearby = (isTop ? tops : bottoms).enumerated()
            .min { abs($0.element - t) < abs($1.element - t) }
        if let nearby, abs(nearby.element - t) * Double(size.width) /
            ((span.map { $0.last - $0.first }) ?? 1) < 22 {
            selected = Mark(isTop: isTop, index: nearby.offset)
            return
        }
        if isTop {
            tops.append(t); tops.sort()
            selected = Mark(isTop: true, index: tops.firstIndex(of: t) ?? 0)
        } else {
            bottoms.append(t); bottoms.sort()
            selected = Mark(isTop: false, index: bottoms.firstIndex(of: t) ?? 0)
        }
        persist()
    }

    private func nudge(_ seconds: Double) {
        guard let mark = selected else { return }
        if mark.isTop, tops.indices.contains(mark.index) {
            tops[mark.index] += seconds
        } else if !mark.isTop, bottoms.indices.contains(mark.index) {
            bottoms[mark.index] += seconds
        }
        persist()
    }

    private func deleteSelected() {
        guard let mark = selected else { return }
        if mark.isTop, tops.indices.contains(mark.index) {
            tops.remove(at: mark.index)
        } else if !mark.isTop, bottoms.indices.contains(mark.index) {
            bottoms.remove(at: mark.index)
        }
        selected = nil
        persist()
    }

    private func persist() {
        tops.sort()
        bottoms.sort()
        store.setMarks(tops: tops, bottoms: bottoms, for: record)
    }

    // MARK: - Chrome

    private var legend: some View {
        HStack(spacing: 14) {
            dot(.red, "gezählt")
            dot(.blue, "oben")
            dot(.orange, "unten")
            Spacer()
        }
        .font(.caption2)
    }

    private func dot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let mark = selected, let time = timeOf(mark) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(mark.isTop ? "Oben" : "Unten") · \(String(format: "%.2f s", time))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Button { nudge(-0.05) } label: { step("−0,05") }
                    Button { nudge(0.05) } label: { step("+0,05") }
                    Spacer()
                    Button(role: .destructive) { deleteSelected() } label: {
                        Label("Löschen", systemImage: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Text("Marke ziehen zum Verschieben. Tippen in die obere Hälfte setzt eine "
                 + "Marke oben, in die untere eine unten.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ title: String) -> some View {
        Text(title)
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func timeOf(_ mark: Mark) -> Double? {
        mark.isTop ? tops[safe: mark.index] : bottoms[safe: mark.index]
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("gezählt").foregroundStyle(.secondary)
                Text("\(record.count)").monospacedDigit()
                Spacer()
                Text("oben").foregroundStyle(.secondary)
                Text("\(tops.count)").monospacedDigit()
                    .foregroundStyle(tops.count == record.count ? .green : .orange)
                Text("unten").foregroundStyle(.secondary)
                Text("\(bottoms.count)").monospacedDigit()
            }
            .font(.subheadline)
            Text("„Tatsächlich\" folgt den oberen Marken.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

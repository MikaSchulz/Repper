import SwiftUI

/// One stored set, re-analysed and drawn: the velocity curve, the repetitions the
/// detector counted, and the marks tapped in while lifting — on top of each other.
///
/// The marks can be moved, added and deleted here. Tapping during a set is rough: the
/// hand is busy and the tap lands late, so what gets stored is a first pass. Correcting
/// it against the curve is what turns a recording into a reference the detector can be
/// measured against, which means this screen has to be genuinely workable — pinch to
/// zoom, drag to pan, and a mark that follows the finger.
///
/// Everything is drawn in a single `Canvas` pass. The first version built the curve as a
/// `Path` and every mark as its own view inside a `ForEach`, so each step of a drag
/// rebuilt the whole hierarchy; at a few thousand samples that is visibly slow.
struct SetDetailView: View {
    let record: SetRecord
    @ObservedObject var store: SetStore

    @State private var analysis: Analysis?
    @State private var tops: [Double] = []
    @State private var bottoms: [Double] = []
    @State private var selected: Mark?
    @State private var loading = true

    /// Fixed for the recording, so it is computed once rather than per drawn point.
    /// It used to be `vel.map(abs).max()` inside the y mapping, which allocated an
    /// array over every sample for each of the few hundred points in a frame -- the
    /// whole cost of a pinch was in that one line.
    @State private var vScale: Double = 1
    @State private var tFirst: Double = 0
    @State private var tSpan: Double = 1

    /// Visible span as a fraction of the whole recording, and where that span starts.
    @State private var zoom: Double = 1
    @State private var originT: Double = 0
    @State private var zoomBase: Double = 1

    /// What the current finger-down is doing. Decided once, on the first movement, so a
    /// drag cannot change its mind halfway and leave a mark somewhere unintended.
    private enum Grab: Equatable {
        case none
        case pan(Double)
        case move(Mark, Double)
        /// Every mark at once, from where they all were when the drag began.
        case shiftAll([Double], [Double])
    }
    @State private var grab: Grab = .none
    @State private var dragStart: CGPoint?
    /// How much the current drag is slowed down, shown while it is.
    @State private var gain: Double = 1
    /// Taps lag what they mark — the hand is busy and the finger lands late — so the
    /// error is largely the same for every mark in a set. Correcting that one mark at a
    /// time is the wrong unit of work.
    @State private var shiftMode = false
    @State private var shiftBy: Double = 0

    /// Snapshots of both mark lists. Correcting a set is fiddly work and a wrong drag
    /// is easy; without a way back the only repair is to remember where the mark was.
    @State private var past: [([Double], [Double])] = []
    @State private var future: [([Double], [Double])] = []

    struct Mark: Equatable {
        var isTop: Bool
        var index: Int
    }

    private let hitRadius: CGFloat = 26

    var body: some View {
        GeometryReader { outer in
            let landscape = outer.size.width > outer.size.height
            VStack(spacing: 10) {
                if loading {
                    ProgressView("Signal wird ausgewertet …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if analysis == nil {
                    Text("Rohsignal nicht lesbar.")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    plot
                        .frame(maxHeight: landscape ? .infinity : 340)
                    legend
                    editor
                    if !landscape { counts }
                }
            }
            .padding(landscape ? 8 : 16)
        }
        .navigationTitle(record.shortDate)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(past.isEmpty)
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(future.isEmpty)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { zoom = 1; originT = tFirst }
                } label: { Image(systemName: "arrow.left.and.right") }
                .disabled(zoom == 1)
            }
        }
        .task {
            let samples = store.samples(for: record)
            let a = RepCounter.analyse(samples)
            analysis = a
            if let a, let f = a.t.first, let l = a.t.last, l > f {
                tFirst = f
                tSpan = l - f
                originT = f
                var peak = 1e-6
                for v in a.vel { peak = Swift.max(peak, abs(v)) }
                vScale = peak
            }
            tops = record.manualMarks
            bottoms = record.manualBottoms
            loading = false
        }
    }

    // MARK: - Plot

    private var plot: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
                draw(ctx, size)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
            .gesture(dragGesture(size))
            .simultaneousGesture(magnify)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// One pass: zero line, curve, counted repetitions, both kinds of mark.
    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let a = analysis, a.vel.count > 1 else { return }
        let lo = originT, hi = originT + visibleSpan

        var ctx = ctx
        let zeroY = yFor(0, size.height)
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: zeroY))
                          $0.addLine(to: CGPoint(x: size.width, y: zeroY)) },
                   with: .color(.white.opacity(0.2)), lineWidth: 1)

        // One point per pixel column: the curve cannot show more than that, and at a
        // few thousand samples drawing them all is most of the cost.
        let i0 = max(0, index(of: lo, a))
        let i1 = min(a.vel.count - 1, index(of: hi, a))
        if i1 > i0 {
            let step = max(1, (i1 - i0) / max(1, Int(size.width)))
            var path = Path()
            var first = true
            for i in stride(from: i0, through: i1, by: step) {
                let p = CGPoint(x: xFor(a.t[i], size.width), y: yFor(a.vel[i], size.height))
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(.green), lineWidth: 2)
        }

        for t in record.repTimes where t >= lo && t <= hi {
            let p = CGPoint(x: xFor(t, size.width), y: yFor(valueAt(t, a), size.height))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)),
                     with: .color(.red))
        }

        // Faint bands where handles live, so it is visible that the middle is for
        // panning and the edges are for grabbing.
        if zoom > 1 {
            for rect in [CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.26),
                         CGRect(x: 0, y: size.height * 0.74,
                                width: size.width, height: size.height * 0.26)] {
                ctx.fill(Path(rect), with: .color(.white.opacity(0.03)))
            }
        }

        drawMarks(&ctx, size, tops, isTop: true, lo: lo, hi: hi)
        drawMarks(&ctx, size, bottoms, isTop: false, lo: lo, hi: hi)
    }

    private func drawMarks(_ ctx: inout GraphicsContext, _ size: CGSize, _ times: [Double],
                           isTop: Bool, lo: Double, hi: Double) {
        let tint: Color = isTop ? .blue : .orange
        for (i, t) in times.enumerated() where t >= lo && t <= hi {
            let on = selected == Mark(isTop: isTop, index: i)
            let x = xFor(t, size.width)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0))
                              $0.addLine(to: CGPoint(x: x, y: size.height)) },
                       with: .color(tint.opacity(on ? 0.95 : 0.5)),
                       lineWidth: on ? 3 : 2)
            let r: CGFloat = on ? 13 : 10
            let cy = isTop ? r + 2 : size.height - r - 2
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2)),
                     with: .color(tint))
            ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2)),
                       with: .color(.white.opacity(on ? 0.9 : 0.35)), lineWidth: on ? 2 : 1)
        }
    }

    // MARK: - Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let centre = originT + visibleSpan / 2
                zoom = min(60, max(1, zoomBase * value.magnification))
                originT = clampOrigin(centre - visibleSpan / 2)
            }
            .onEnded { _ in zoomBase = zoom }   // the next pinch starts from where this left off
    }

    /// A single gesture decides, on the first movement, whether this is a mark being
    /// dragged or the view being panned. Two competing gestures would make grabbing a
    /// mark near the edge a coin toss.
    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                    if let m = hitTest(value.startLocation, size), let t = timeOf(m) {
                        beginEdit()
                        grab = .move(m, t)
                        selected = m
                    } else if shiftMode, !(tops.isEmpty && bottoms.isEmpty) {
                        beginEdit()
                        grab = .shiftAll(tops, bottoms)
                        selected = nil
                    } else {
                        grab = .pan(originT)
                    }
                }
                switch grab {
                case .move(let m, let startTime):
                    // Pull the finger away from the line to slow the mark down, the way
                    // a video scrubber does. Straight across is one to one; further down
                    // or up gives a quarter, then a twelfth, so a hundredth of a second
                    // is reachable without zooming in first.
                    let dy = abs(value.location.y - value.startLocation.y)
                    gain = dy < 48 ? 1 : (dy < 120 ? 0.25 : 0.08)
                    let perPoint = visibleSpan / Double(size.width)
                    setTime(m, startTime + Double(value.translation.width) * perPoint * gain)
                case .shiftAll(let startTops, let startBottoms):
                    let dy = abs(value.location.y - value.startLocation.y)
                    gain = dy < 48 ? 1 : (dy < 120 ? 0.25 : 0.08)
                    let perPoint = visibleSpan / Double(size.width)
                    // One offset for all of them, clamped so that the outermost mark
                    // stays inside the recording. Clamping each mark on its own would
                    // squash the ends together and destroy the spacing being preserved.
                    let all = startTops + startBottoms
                    guard let lowest = all.min(), let highest = all.max() else { return }
                    let raw = Double(value.translation.width) * perPoint * gain
                    shiftBy = min(max(raw, tFirst - lowest), tFirst + tSpan - highest)
                    tops = startTops.map { $0 + shiftBy }
                    bottoms = startBottoms.map { $0 + shiftBy }

                case .pan(let start):
                    let perPoint = visibleSpan / Double(size.width)
                    originT = clampOrigin(start - Double(value.translation.width) * perPoint)
                case .none:
                    break
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                gain = 1
                switch grab {
                case .shiftAll:
                    persist()
                    shiftBy = 0
                case .move:
                    persist()
                case .pan:
                    // A press that went nowhere is a tap: upper half adds a mark at the
                    // top, lower half one at the bottom — the same split as the two tap
                    // zones during a set.
                    if moved < 10 {
                        beginEdit()
                        addMark(at: value.startLocation, in: size)
                    }
                case .none:
                    break
                }
                grab = .none
                dragStart = nil
            }
    }

    /// A mark is grabbed by its handle, not by its whole column.
    ///
    /// Matching on horizontal distance alone made the middle of the plot ungrabbable
    /// for panning: a set carries twenty or more marks, so almost every point is within
    /// a finger's width of one of them, and every attempt to scroll along the axis
    /// dragged a mark instead. Top handles live in the top band, bottom handles in the
    /// bottom one, and the half in between belongs to the view.
    private func hitTest(_ point: CGPoint, _ size: CGSize) -> Mark? {
        let lo = originT, hi = originT + visibleSpan
        let topBand = size.height * 0.26
        let bottomBand = size.height * 0.74
        var best: (Mark, CGFloat)?
        if point.y <= topBand {
            for (i, t) in tops.enumerated() where t >= lo && t <= hi {
                let d = abs(xFor(t, size.width) - point.x)
                if d < hitRadius, best == nil || d < best!.1 {
                    best = (Mark(isTop: true, index: i), d)
                }
            }
        }
        if point.y >= bottomBand {
            for (i, t) in bottoms.enumerated() where t >= lo && t <= hi {
                let d = abs(xFor(t, size.width) - point.x)
                if d < hitRadius, best == nil || d < best!.1 {
                    best = (Mark(isTop: false, index: i), d)
                }
            }
        }
        return best?.0
    }

    // MARK: - Geometry

    private var visibleSpan: Double { tSpan / zoom }

    private func clampOrigin(_ t: Double) -> Double {
        min(max(tFirst, t), tFirst + tSpan - visibleSpan)
    }

    private func xFor(_ t: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((t - originT) / visibleSpan) * width
    }

    private func timeFor(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(tFirst + tSpan, max(tFirst, originT + Double(x / width) * visibleSpan))
    }

    private func yFor(_ v: Double, _ height: CGFloat) -> CGFloat {
        height / 2 - CGFloat(v / vScale) * (height / 2 - 16)
    }

    private func index(of t: Double, _ a: Analysis) -> Int {
        min(a.vel.count - 1, max(0, Int((t - tFirst) * RepConfig.default.fs)))
    }

    private func valueAt(_ t: Double, _ a: Analysis) -> Double { a.vel[index(of: t, a)] }

    // MARK: - Editing

    private func setTime(_ mark: Mark, _ value: Double) {
        let t = min(tFirst + tSpan, max(tFirst, value))
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
        if isTop {
            tops.append(t); tops.sort()
            selected = Mark(isTop: true, index: tops.firstIndex(of: t) ?? 0)
        } else {
            bottoms.append(t); bottoms.sort()
            selected = Mark(isTop: false, index: bottoms.firstIndex(of: t) ?? 0)
        }
        persist()
    }

    /// Remember where the marks were, before changing them.
    private func beginEdit() {
        past.append((tops, bottoms))
        if past.count > 40 { past.removeFirst() }
        future.removeAll()
    }

    private func undo() {
        guard let step = past.popLast() else { return }
        future.append((tops, bottoms))
        (tops, bottoms) = step
        selected = nil
        persist()
    }

    private func redo() {
        guard let step = future.popLast() else { return }
        past.append((tops, bottoms))
        (tops, bottoms) = step
        selected = nil
        persist()
    }

    private func nudge(_ seconds: Double) {
        guard let mark = selected, let t = timeOf(mark) else { return }
        beginEdit()
        setTime(mark, t + seconds)
        persist()
    }

    private func deleteSelected() {
        guard let mark = selected else { return }
        beginEdit()
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

    private func timeOf(_ mark: Mark) -> Double? {
        mark.isTop ? tops[safe: mark.index] : bottoms[safe: mark.index]
    }

    // MARK: - Chrome

    private var legend: some View {
        HStack(spacing: 12) {
            dot(.red, "gezählt")
            dot(.blue, "oben")
            dot(.orange, "unten")
            Spacer()
            if case .shiftAll = grab {
                Text(String(format: "%+.2f s", shiftBy))
                    .foregroundStyle(.yellow).monospacedDigit()
            } else if gain < 1 {
                Text(String(format: "fein ×%.2f", gain))
                    .foregroundStyle(.yellow).monospacedDigit()
            } else if zoom > 1 {
                Text(String(format: "%.0f s sichtbar", visibleSpan))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Button { shiftMode.toggle() } label: {
                Label("alle", systemImage: "arrow.left.and.right")
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(shiftMode ? Color.yellow.opacity(0.25)
                                          : Color.white.opacity(0.10))
                    .foregroundStyle(shiftMode ? Color.yellow : Color.secondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(tops.isEmpty && bottoms.isEmpty)
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
            HStack(spacing: 8) {
                Text("\(mark.isTop ? "Oben" : "Unten") · \(String(format: "%.2f s", time))")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 112, alignment: .leading)
                // Finer steps once zoomed in, where that precision is visible anyway.
                Button { nudge(zoom > 4 ? -0.01 : -0.05) } label: { step(zoom > 4 ? "−0,01" : "−0,05") }
                Button { nudge(zoom > 4 ? 0.01 : 0.05) } label: { step(zoom > 4 ? "+0,01" : "+0,05") }
                Spacer()
                Button(role: .destructive) { deleteSelected() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Text(shiftMode
                 ? "Alle verschieben ist an: Ziehen in der Mitte schiebt sämtliche Marken "
                   + "gemeinsam über die Zeitachse, zur Mitte ausweichen macht es feiner. "
                   + "Einzelne Marken lassen sich weiterhin an ihrem Knopf anfassen."
                 : "In der Mitte ziehen verschiebt die Ansicht, Auf- und Zuziehen zoomt. "
                 + "Eine Marke fasst du an ihrem Knopf oben oder unten an; dabei zur "
                 + "Mitte ausweichen macht sie langsamer, bis auf ein Zwölftel. Tippen "
                 + "setzt eine neue — oben in der oberen Hälfte, unten in der unteren.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ title: String) -> some View {
        Text(title)
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

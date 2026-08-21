import SwiftUI
import FanKit
import ProfileKit
import SensorKit

/// The curve editor. The safety floor is enforced by geometry — points are
/// clamped out of the shaded region during the drag itself, so an unsafe curve
/// simply cannot be authored (UI.md §1 rule 2). No validation dialogs.
struct CurveEditorView: View {
    @ObservedObject var model: AppModel
    @State private var selectedProfileID: UUID?
    @State private var selectedFan: Int = 0
    @State private var draft: FanCurve = .balanced
    @State private var dragIndex: Int?
    @State private var selectedPoint: Int?
    @State private var hoverTemp: Double?

    private let tempRange: ClosedRange<Double> = 30...105
    private let floor = SafetyFloor()
    /// A click farther than this from a handle creates a point instead of
    /// dragging the nearest one halfway across the graph.
    private let grabRadius: CGFloat = 18

    private var profile: Profile {
        model.profiles.first { $0.id == (selectedProfileID ?? model.activeProfileID) }
            ?? model.activeProfile
    }

    private var isDirty: Bool { draft != profile.curve(forFan: selectedFan) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picker
            graphWithAxes.frame(minHeight: 280)
            legend
            sensorMapping
            preview
            controls
        }
        .padding(16)
        .frame(minWidth: 660, minHeight: 520)
        .onAppear {
            if selectedProfileID == nil { selectedProfileID = model.activeProfileID }
            if selectedFan == 0, let first = model.fans.first { selectedFan = first.index }
            reload()
        }
    }

    // MARK: - Header

    private var picker: some View {
        HStack(spacing: 12) {
            Picker("Profile", selection: Binding(
                get: { selectedProfileID ?? model.activeProfileID },
                set: { selectedProfileID = $0; reload() }
            )) {
                ForEach(model.profiles.filter { !$0.releasesToSystem }) {
                    Text($0.name).tag($0.id)
                }
            }
            .fixedSize()

            if model.fans.count > 1 {
                Picker("", selection: Binding(
                    get: { selectedFan },
                    set: { selectedFan = $0; reload() }
                )) {
                    ForEach(model.fans) { Text("Fan \($0.index + 1)").tag($0.index) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
            }

            Spacer()

            if isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var ceiling: Double { profile.settings.ceilingPercent }

    // MARK: - Graph

    /// Axis gutters live outside the plot so the plot's coordinate space stays a
    /// clean 0..width / 0..height mapping of the data range.
    private var graphWithAxes: some View {
        HStack(alignment: .top, spacing: 6) {
            yAxis
            VStack(spacing: 4) {
                GeometryReader { geo in plot(geo.size) }
                xAxis
            }
        }
    }

    private var yAxis: some View {
        GeometryReader { geo in
            let usable = geo.size.height - 18   // minus the x-axis strip below
            ForEach(Array(stride(from: 0.0, through: 100.0, by: 25)), id: \.self) { pct in
                Text("\(Int(pct))%")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .position(x: 17, y: usable * (1 - pct / 100))
            }
        }
        .frame(width: 36)
    }

    private var xAxis: some View {
        GeometryReader { geo in
            ForEach(Array(stride(from: 30.0, through: 105.0, by: 15)), id: \.self) { t in
                Text("\(Int(t))°")
                    .font(.caption2).foregroundStyle(.secondary)
                    .position(x: x(t, CGSize(width: geo.size.width, height: 0)), y: 8)
            }
        }
        .frame(height: 18)
    }

    private func plot(_ size: CGSize) -> some View {
        ZStack {
            gridLines(size)
            floorRegion(size)
            ceilingLine(size)
            curvePath(size)
            liveIndicator(size)
            handles(size)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(size))
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fan curve editor")
    }

    // MARK: - Coordinate mapping (data space, survives resizing)

    private func x(_ tempC: Double, _ size: CGSize) -> CGFloat {
        let t = (tempC - tempRange.lowerBound) /
                (tempRange.upperBound - tempRange.lowerBound)
        return CGFloat(max(0, min(1, t))) * size.width
    }

    private func y(_ percent: Double, _ size: CGSize) -> CGFloat {
        size.height * CGFloat(1 - max(0, min(100, percent)) / 100)
    }

    private func temp(fromX px: CGFloat, _ size: CGSize) -> Double {
        let t = Double(max(0, min(size.width, px)) / max(1, size.width))
        return tempRange.lowerBound + t * (tempRange.upperBound - tempRange.lowerBound)
    }

    private func percent(fromY py: CGFloat, _ size: CGSize) -> Double {
        Double(1 - max(0, min(size.height, py)) / max(1, size.height)) * 100
    }

    // MARK: - Layers

    private func gridLines(_ size: CGSize) -> some View {
        Path { path in
            for pct in stride(from: 0.0, through: 100.0, by: 25) {
                let py = y(pct, size)
                path.move(to: CGPoint(x: 0, y: py))
                path.addLine(to: CGPoint(x: size.width, y: py))
            }
            for t in stride(from: 30.0, through: 105.0, by: 15) {
                let px = x(t, size)
                path.move(to: CGPoint(x: px, y: 0))
                path.addLine(to: CGPoint(x: px, y: size.height))
            }
        }
        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
    }

    private func floorRegion(_ size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            var t = tempRange.lowerBound
            while t <= tempRange.upperBound {
                let f = floor.floorPercent(tempC: t, pressure: .nominal)
                path.addLine(to: CGPoint(x: x(t, size), y: y(f, size)))
                t += 2
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
        .fill(Color.red.opacity(0.12))
    }

    private func ceilingLine(_ size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y(ceiling, size)))
            path.addLine(to: CGPoint(x: size.width, y: y(ceiling, size)))
        }
        .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
    }

    private func curvePath(_ size: CGSize) -> some View {
        Path { path in
            guard let first = draft.points.first else { return }
            path.move(to: CGPoint(x: x(first.tempC, size), y: y(first.percent, size)))
            for point in draft.points.dropFirst() {
                path.addLine(to: CGPoint(x: x(point.tempC, size), y: y(point.percent, size)))
            }
        }
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
    }

    @ViewBuilder
    private func liveIndicator(_ size: CGSize) -> some View {
        if let current = model.maxTempC {
            let px = x(current, size)
            let py = y(draft.percent(at: current), size)
            Path { path in
                path.move(to: CGPoint(x: px, y: 0))
                path.addLine(to: CGPoint(x: px, y: size.height))
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Circle().fill(Color.green).frame(width: 7, height: 7).position(x: px, y: py)
        }
    }

    private func handles(_ size: CGSize) -> some View {
        ForEach(Array(draft.points.enumerated()), id: \.offset) { index, point in
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .frame(width: selectedPoint == index ? 16 : 12,
                       height: selectedPoint == index ? 16 : 12)
                .position(x: x(point.tempC, size), y: y(point.percent, size))
                .accessibilityLabel("Point \(index + 1)")
                .accessibilityValue(String(format: "%.0f degrees, %.0f percent",
                                           point.tempC, point.percent))
        }
    }

    // MARK: - Drag with clamping

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragIndex == nil {
                    // Grab only a handle that was actually near the click; a bare
                    // click on empty graph adds a point there instead of yanking
                    // the nearest one across the plot.
                    if let near = pointNear(value.startLocation, size: size) {
                        dragIndex = near
                    } else {
                        dragIndex = insertPoint(at: value.startLocation, size: size)
                    }
                    selectedPoint = dragIndex
                }
                guard let index = dragIndex else { return }
                var points = draft.points
                guard points.indices.contains(index) else { return }

                var newTemp = temp(fromX: value.location.x, size)
                var newPercent = percent(fromY: value.location.y, size)

                // Cannot cross neighbours — enforces monotonic temperature.
                if index > 0 { newTemp = max(newTemp, points[index - 1].tempC + 1) }
                if index < points.count - 1 { newTemp = min(newTemp, points[index + 1].tempC - 1) }

                // Cannot enter the shaded floor or exceed the ceiling.
                let floorHere = floor.floorPercent(tempC: newTemp, pressure: .nominal)
                newPercent = max(newPercent, floorHere)
                newPercent = min(newPercent, ceiling)
                if index > 0 { newPercent = max(newPercent, points[index - 1].percent) }
                if index < points.count - 1 { newPercent = min(newPercent, points[index + 1].percent) }

                points[index] = CurvePoint(tempC: newTemp, percent: newPercent)
                draft.setPoints(points)
                hoverTemp = newTemp
            }
            .onEnded { _ in dragIndex = nil; hoverTemp = nil }
    }

    private func pointNear(_ location: CGPoint, size: CGSize) -> Int? {
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, point) in draft.points.enumerated() {
            let dx = Double(x(point.tempC, size) - location.x)
            let dy = Double(y(point.percent, size) - location.y)
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestDistance { bestDistance = d; best = i }
        }
        return bestDistance <= Double(grabRadius) ? best : nil
    }

    /// Inserts a point at the click, clamped into the legal band, and returns its
    /// index so the same gesture continues as a drag of the new point.
    private func insertPoint(at location: CGPoint, size: CGSize) -> Int? {
        var points = draft.points
        guard points.count < 12 else { return nil }
        let t = temp(fromX: location.x, size)
        // Keep at least 1°C from neighbours so the monotonic clamp has room.
        guard !points.contains(where: { abs($0.tempC - t) < 2 }) else { return nil }
        let clamped = min(max(percent(fromY: location.y, size),
                              floor.floorPercent(tempC: t, pressure: .nominal)), ceiling)
        points.append(CurvePoint(tempC: t, percent: clamped))
        draft.setPoints(points)
        return draft.points.firstIndex { abs($0.tempC - t) < 0.001 }
    }

    private func deleteSelectedPoint() {
        guard let index = selectedPoint, draft.points.count > 2,
              draft.points.indices.contains(index) else { return }
        var points = draft.points
        points.remove(at: index)
        draft.setPoints(points)
        selectedPoint = nil
    }

    // MARK: - Footer

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .red.opacity(0.35), text: "Safety floor — cannot be entered")
            legendItem(color: .orange, text: "Ceiling \(Int(ceiling))%")
            legendItem(color: .green, text: "Now")
            Spacer()
            Text("Click empty space to add a point · drag to move")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Sensor mapping

    /// Which sensors drive this fan (UI.md §4, AUDIT A-3).
    ///
    /// Naming nothing means "the machine's hottest sensor", which is what every
    /// built-in ships with and what most people should leave alone. It is spelled
    /// out rather than left as an empty row, because an empty list reads as
    /// "no sensors — is this broken?".
    private var sensorMapping: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sensors driving this fan:").font(.callout)
                if draft.sensorIDs.isEmpty {
                    Text("All — the hottest sensor on the machine")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                addSensorMenu
            }

            if !draft.sensorIDs.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(draft.sensorIDs, id: \.self) { id in sensorChip(id) }
                }
                HStack(spacing: 10) {
                    Picker("Reduction", selection: Binding(
                        get: { draft.reduction },
                        set: { draft.reduction = $0 }
                    )) {
                        Text("Max").tag(SensorReduction.max)
                        Text("Mean").tag(SensorReduction.mean)
                    }
                    .pickerStyle(.segmented).fixedSize()
                    .help("How several sensors become one number. Max is the safe default.")

                    Text("The safety floor always follows the hottest sensor on the machine, whatever is chosen here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var addSensorMenu: some View {
        Menu {
            if !draft.sensorIDs.isEmpty {
                Button("Use all sensors") { draft.sensorIDs = [] }
                Divider()
            }
            ForEach(availableSensors, id: \.id) { reading in
                Button(reading.displayName(isAmbiguous: ambiguousNames.contains(reading.name))
                       + String(format: "  %.0f°C", reading.celsius)) {
                    if !draft.sensorIDs.contains(reading.id) { draft.sensorIDs.append(reading.id) }
                }
            }
        } label: {
            Label("Add sensor", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(availableSensors.isEmpty)
    }

    /// Sensors this machine is reporting that the curve does not already name.
    /// Calibration references are excluded: `PMU tcal` is a constant, so a curve
    /// driven by it never moves.
    private var availableSensors: [TemperatureSensors.Reading] {
        model.temperatures
            .filter { !$0.isReference && !draft.sensorIDs.contains($0.id) }
            .sorted { $0.celsius > $1.celsius }
    }

    private var ambiguousNames: Set<String> {
        TemperatureSensors.ambiguousNames(in: model.temperatures)
    }

    /// A named sensor that is not reporting is shown, not hidden. That is the
    /// case where the curve silently falls back to the machine maximum, and the
    /// user needs to be able to see which entry went stale and remove it.
    private func sensorChip(_ id: String) -> some View {
        let reading = model.temperatures.first { $0.id == id }
        let missing = reading == nil
        let label = reading.map { $0.displayName(isAmbiguous: ambiguousNames.contains($0.name)) } ?? id
        return HStack(spacing: 4) {
            if missing { Image(systemName: "exclamationmark.triangle.fill").font(.caption2) }
            Text(label).font(.caption)
            Button {
                draft.sensorIDs.removeAll { $0 == id }
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background((missing ? Color.orange : Color.secondary).opacity(0.15))
        .clipShape(Capsule())
        .foregroundStyle(missing ? Color.orange : Color.primary)
        .help(missing ? "This sensor is not reporting. The curve is using the hottest sensor instead."
                      : id)
    }

    private var preview: some View {
        let current = hoverTemp ?? mappedTemperature ?? model.maxTempC
        let pct = current.map { draft.percent(at: $0) }
        let fan = model.fans.first { $0.index == selectedFan }
        let rpm = (pct != nil && fan != nil) ? fan!.rpm(forPercent: pct!) : nil
        return Text(current == nil
                    ? "Waiting for sensor data"
                    : String(format: "%@ %.0f°C → %.0f%% → ~%.0f rpm",
                             hoverTemp == nil ? "at" : "cursor", current!, pct ?? 0, rpm ?? 0))
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack {
            Button("Remove Point") { deleteSelectedPoint() }
                .disabled(selectedPoint == nil || draft.points.count <= 2)
            Button("Reset Curve") { draft = defaultCurve() }
                .help("Back to this profile's factory curve. Does not touch the fans.")
            Spacer()
            Button("Revert") { reload() }
                .disabled(!isDirty)
            Button("Apply") {
                model.updateCurve(draft, forFan: selectedFan, inProfile: profile.id)
            }
            .disabled(!isDirty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        draft = profile.curve(forFan: selectedFan)
        selectedPoint = nil
    }

    /// The temperature this curve would actually be evaluated at right now, so
    /// the preview shows the effect of the mapping rather than the machine
    /// maximum the mapping was chosen to avoid.
    private var mappedTemperature: Double? {
        var readings: [String: Double] = [:]
        for reading in model.temperatures where reading.celsius.isFinite {
            readings[reading.id] = reading.celsius
        }
        return draft.input(readings: readings, globalMax: model.maxTempC).celsius
    }

    /// The factory curve for this profile, so "Reset Curve" means something
    /// specific rather than "whatever Balanced happens to be".
    private func defaultCurve() -> FanCurve {
        Profile.builtIns(fanCount: max(1, model.fans.count))
            .first { $0.id == profile.id }?
            .curve(forFan: selectedFan) ?? .balanced
    }
}

/// Wraps chips onto as many lines as they need. `HStack` would clip them and
/// `LazyVGrid` would give them all the width of the widest one.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map { $0.width }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > width {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

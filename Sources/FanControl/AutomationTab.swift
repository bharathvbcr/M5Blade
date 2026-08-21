import SwiftUI
import FanKit
import ProfileKit
import SensorKit

/// Rule authoring: "when X, use profile Y".
///
/// Order is priority — the resolver takes the first match — so the list is
/// drag-reorderable and says so. Rules that can never fire are flagged inline
/// rather than accepted silently.
struct AutomationTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?

    private var selected: Rule? { model.rules.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detail.frame(minWidth: 340, maxWidth: .infinity)
        }
        // Per-process sampling is expensive, so it runs only while this editor is
        // open or an enabled rule actually needs it.
        .onAppear { model.beginObservingProcesses() }
        .onDisappear { model.endObservingProcesses() }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            if model.rules.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    Section {
                        ForEach(model.rules) { rule in
                            row(rule).tag(rule.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteRule(rule)
                                    } label: {
                                        Label("Delete Rule", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteRule(rule)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove { model.moveRules(from: $0, to: $1) }
                        .onDelete { offsets in
                            deleteRules(at: offsets)
                        }
                    } header: {
                        Text("Checked top to bottom · first match wins")
                            .font(.caption).textCase(nil)
                    }
                }
                .onDeleteCommand {
                    if let selection { deleteRule(id: selection) }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { addRule() } label: { Image(systemName: "plus") }
                    .help("New rule")
                Button {
                    if let selection { deleteRule(id: selection) }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Delete selected rule")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars").font(.largeTitle).foregroundStyle(.secondary)
            Text("No rules yet").font(.headline)
            Text("Rules switch profiles automatically — when an app gets busy, when thermal pressure rises, or when you unplug.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
            Button("Add a rule") { addRule() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ rule: Rule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { var r = rule; r.enabled = $0; model.updateRule(r) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rule.name).lineLimit(1)
                    if rule.isIncomplete {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption2)
                            .help("This rule can never match as written")
                    }
                }
                Text("→ \(profileName(rule.targetProfileID))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Live feedback: which rule is actually winning right now.
            if model.matchingRuleID == rule.id {
                Text("NOW").font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.green.opacity(0.25))
                    .clipShape(Capsule())
            }
        }
        .opacity(rule.enabled ? 1 : 0.5)
    }

    private func addRule() {
        let rule = Rule(name: "New rule",
                        conditions: [ConditionKind.thermalAtLeast.defaultCondition],
                        targetProfileID: model.defaultProfileID)
        model.addRule(rule)
        selection = rule.id
    }

    private func deleteRule(_ rule: Rule) {
        deleteRule(id: rule.id)
    }

    private func deleteRule(id: UUID) {
        model.deleteRule(id)
        if selection == id {
            selection = model.rules.first?.id
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        let idsToDelete = offsets.map { model.rules[$0].id }
        for id in idsToDelete {
            model.deleteRule(id)
        }
        if let sel = selection, !model.rules.contains(where: { $0.id == sel }) {
            selection = model.rules.first?.id
        }
    }

    private func profileName(_ id: UUID) -> String {
        model.profiles.first { $0.id == id }?.name ?? "missing profile"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let rule = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Rule name", text: bind(rule, \.name))
                        .textFieldStyle(.roundedBorder).font(.title3)

                    conditionsSection(rule)
                    targetSection(rule)
                    timingSection(rule)
                    Divider()
                    deleteSection(rule)
                }
                .padding(16)
            }
        } else {
            Text("Select a rule").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func deleteSection(_ rule: Rule) -> some View {
        HStack {
            Button(role: .destructive) {
                deleteRule(rule)
            } label: {
                Label("Delete Rule", systemImage: "trash")
            }
            Spacer()
        }
    }

    private func conditionsSection(_ rule: Rule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("When all of these are true").font(.headline)
                Spacer()
                Menu {
                    ForEach(ConditionKind.allCases) { kind in
                        Button(kind.title) {
                            var r = rule
                            r.conditions.append(kind.defaultCondition)
                            model.updateRule(r)
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
            }

            if rule.conditions.isEmpty {
                Label("A rule with no conditions never matches.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                ConditionEditor(
                    condition: Binding(
                        get: { condition },
                        set: { new in
                            var r = rule
                            guard r.conditions.indices.contains(index) else { return }
                            r.conditions[index] = new
                            model.updateRule(r)
                        }
                    ),
                    processes: model.topProcesses,
                    onDelete: {
                        var r = rule
                        guard r.conditions.indices.contains(index) else { return }
                        r.conditions.remove(at: index)
                        model.updateRule(r)
                    }
                )
            }
        }
    }

    private func targetSection(_ rule: Rule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Then use").font(.headline)
            Picker("", selection: bind(rule, \.targetProfileID)) {
                ForEach(model.profiles) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
        }
    }

    private func timingSection(_ rule: Rule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timing").font(.headline)
            stepper("Wait before switching", value: bind(rule, \.debounce),
                    range: 0...120, step: 5,
                    help: "How long the conditions must hold before this rule takes effect. Stops a brief spike from changing profiles.")
            stepper("Hold after switching", value: bind(rule, \.minDwell),
                    range: 0...600, step: 15,
                    help: "How long this rule keeps control once it wins, even if the conditions stop matching. Stops rapid flapping.")
        }
    }

    private func stepper(_ title: String, value: Binding<TimeInterval>,
                         range: ClosedRange<Double>, step: Double, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: value, in: range, step: step) {
                HStack {
                    Text(title).font(.callout)
                    Spacer()
                    Text("\(Int(value.wrappedValue))s")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bind<V>(_ rule: Rule, _ path: WritableKeyPath<Rule, V>) -> Binding<V> {
        Binding(
            get: { (model.rules.first { $0.id == rule.id } ?? rule)[keyPath: path] },
            set: { newValue in
                guard var updated = model.rules.first(where: { $0.id == rule.id }) else { return }
                updated[keyPath: path] = newValue
                model.updateRule(updated)
            }
        )
    }
}

// MARK: - Condition editor

/// One condition row. Changing the kind replaces the condition with that kind's
/// default rather than trying to carry parameters across incompatible shapes.
struct ConditionEditor: View {
    @Binding var condition: Condition
    var processes: [ProcessInfoSample]
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(
                    get: { condition.kind },
                    set: { condition = $0.defaultCondition }
                )) {
                    ForEach(ConditionKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()

                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove this condition")
            }
            parameters
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var parameters: some View {
        switch condition {
        case .thermalAtLeast(let level):
            Picker("", selection: Binding(
                get: { level },
                set: { condition = .thermalAtLeast($0) }
            )) {
                ForEach([ThermalPressure.nominal, .fair, .serious, .critical], id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("macOS's own thermal signal — the most trustworthy input available.")
                .font(.caption).foregroundStyle(.secondary)

        case .processActive(let match, let cpu, let seconds):
            processParameters(match: match, cpu: cpu, seconds: seconds)

        case .foregroundApp(let id):
            TextField("Bundle identifier, e.g. com.apple.dt.Xcode", text: Binding(
                get: { id }, set: { condition = .foregroundApp(bundleID: $0) }
            ))
            .textFieldStyle(.roundedBorder)

        case .sustainedLoad(let pct, let secs):
            HStack {
                Text("Above").font(.callout)
                TextField("", value: Binding(
                    get: { pct },
                    set: { condition = .sustainedLoad(cpuPercent: $0, forSeconds: secs) }
                ), format: .number).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("% for").font(.callout)
                TextField("", value: Binding(
                    get: { secs },
                    set: { condition = .sustainedLoad(cpuPercent: pct, forSeconds: $0) }
                ), format: .number).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("seconds").font(.callout)
            }
            Text("Sustain is measured above \(Int(SystemState.loadActivityThresholdPercent))% CPU.")
                .font(.caption).foregroundStyle(.secondary)

        case .powerSource(let source):
            Picker("", selection: Binding(
                get: { source }, set: { condition = .powerSource($0) }
            )) {
                Text("AC power").tag(PowerSource.ac)
                Text("Battery").tag(PowerSource.battery)
            }
            .pickerStyle(.segmented).labelsHidden()

        case .batteryBelow(let pct):
            HStack {
                Text("Below").font(.callout)
                TextField("", value: Binding(
                    get: { pct }, set: { condition = .batteryBelow(percent: $0) }
                ), format: .number).frame(width: 56).textFieldStyle(.roundedBorder)
                Text("%").font(.callout)
            }

        case .externalDisplayCount(let n):
            Stepper(value: Binding(
                get: { n }, set: { condition = .externalDisplayCount(atLeast: $0) }
            ), in: 1...8) {
                Text("At least \(n)").font(.callout)
            }

        case .displaysAsleep(let asleep):
            Picker("", selection: Binding(
                get: { asleep }, set: { condition = .displaysAsleep($0) }
            )) {
                Text("Asleep").tag(true)
                Text("Awake").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()

        case .macOSPowerMode(let mode):
            Picker("", selection: Binding(
                get: { mode }, set: { condition = .macOSPowerMode($0) }
            )) {
                Text("Low Power").tag(MacOSPowerMode.low)
                Text("Automatic").tag(MacOSPowerMode.automatic)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("High Power mode isn't exposed by macOS, so it can't be matched.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The per-app case: pick from what's actually running rather than making the
    /// user guess an executable name.
    @ViewBuilder
    private func processParameters(match: ProcessMatch,
                                   cpu: Double?, seconds: TimeInterval?) -> some View {
        HStack {
            TextField("Executable name", text: Binding(
                get: { match.displayName },
                set: { condition = .processActive(match: .executableName($0),
                                                  sustainedCPU: cpu, forSeconds: seconds) }
            ))
            .textFieldStyle(.roundedBorder)

            Menu {
                if processes.isEmpty {
                    Text("No processes sampled yet")
                } else {
                    ForEach(processes.prefix(25)) { sample in
                        Button(String(format: "%@ — %.0f%%", sample.name, sample.cpuPercent)) {
                            condition = .processActive(match: .executableName(sample.name),
                                                       sustainedCPU: cpu, forSeconds: seconds)
                        }
                    }
                }
            } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pick from running processes, busiest first")
        }

        HStack {
            Text("Above").font(.callout)
            TextField("", value: Binding(
                get: { cpu ?? 0 },
                set: { condition = .processActive(match: match, sustainedCPU: $0,
                                                  forSeconds: seconds) }
            ), format: .number).frame(width: 56).textFieldStyle(.roundedBorder)
            Text("% CPU for").font(.callout)
            TextField("", value: Binding(
                get: { seconds ?? 0 },
                set: { condition = .processActive(match: match, sustainedCPU: cpu,
                                                  forSeconds: $0) }
            ), format: .number).frame(width: 56).textFieldStyle(.roundedBorder)
            Text("seconds").font(.callout)
        }
        Text("CPU is measured across all cores, so a busy compile can exceed 100%. Only processes your user account owns are visible.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

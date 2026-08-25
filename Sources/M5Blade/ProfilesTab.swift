import SwiftUI
import FanKit
import ProfileKit

/// Create, edit, and delete profiles.
///
/// Built-ins are editable but not deletable — every fallback path in the app
/// resolves to one, and the panic path resolves to Stock specifically.
struct ProfilesTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?
    @State private var pendingDelete: Profile?

    private var selected: Profile? {
        model.profiles.first { $0.id == (selection ?? model.activeProfileID) }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
            detail.frame(minWidth: 340, maxWidth: .infinity)
        }
        .onAppear { if selection == nil { selection = model.activeProfileID } }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                model.deleteProfile(profile.id)
                selection = model.activeProfileID
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { profile in
            let n = model.ruleCount(targeting: profile.id)
            Text(n == 0
                 ? "This can't be undone."
                 : "\(n) automation rule\(n == 1 ? "" : "s") target this profile and will be deleted too.")
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.profiles) { profile in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: profile))
                            .foregroundStyle(profile.id == model.activeProfileID
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                            if profile.id == model.defaultProfileID {
                                Text("Default").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if profile.id == model.activeProfileID {
                            Text("Active").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                    .tag(profile.id)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { selection = model.addProfile(basedOn: selected).id } label: {
                    Image(systemName: "plus")
                }
                .help("New profile based on the selection")

                Button {
                    if let selected, model.canDelete(selected) { pendingDelete = selected }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!(selected.map { model.canDelete($0) } ?? false))
                .help(selected?.isBuiltIn == true
                      ? "Built-in profiles can't be deleted"
                      : "Delete the selected profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func icon(for profile: Profile) -> String {
        if profile.releasesToSystem { return "apple.logo" }
        return profile.isBuiltIn ? "lock.fill" : "person.crop.circle"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let profile = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identity(profile)
                    if profile.releasesToSystem {
                        stockNotice
                    } else {
                        limits(profile)
                        responsiveness(profile)
                    }
                    actions(profile)
                }
                .padding(16)
            }
        } else {
            Text("Select a profile").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func identity(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: binding(profile, \.name))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .disabled(profile.isBuiltIn)
            if profile.isBuiltIn {
                Label("Built-in profile — the name is fixed, but its curves and limits are yours to change.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stockNotice: some View {
        Label("Stock hands the fans back to macOS. It has no curve or ceiling of its own.",
              systemImage: "apple.logo")
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func limits(_ profile: Profile) -> some View {
        section("Limits") {
            slider("Ceiling", value: binding(profile, \.settings.ceilingPercent),
                   range: 20...100, step: 1, format: "%.0f%%",
                   help: "The fastest this profile will ever drive the fans. The safety floor can still override it in an emergency.")
        }
    }

    private func responsiveness(_ profile: Profile) -> some View {
        section("Responsiveness") {
            slider("Hysteresis", value: binding(profile, \.settings.hysteresisC),
                   range: 0...10, step: 0.5, format: "%.1f °C",
                   help: "How far the temperature must move before the target changes. Higher is calmer, slower to react.")
            slider("Ramp up", value: binding(profile, \.settings.slewUpRPMPerSec),
                   range: 50...1000, step: 25, format: "%.0f rpm/s",
                   help: "Maximum speed increase per second. The safety floor is exempt from this limit.")
            slider("Ramp down", value: binding(profile, \.settings.slewDownRPMPerSec),
                   range: 25...1000, step: 25, format: "%.0f rpm/s",
                   help: "Maximum speed decrease per second. Lower avoids audible surging.")
            slider("Smoothing", value: binding(profile, \.settings.smoothingAlpha),
                   range: 0.05...1, step: 0.05, format: "%.2f",
                   help: "Sensor smoothing. 1.00 reacts instantly to every reading; lower is steadier. Does not affect the safety floor, which always reads the raw sensor.")
        }
    }

    private func actions(_ profile: Profile) -> some View {
        HStack {
            Button("Make Default") {
                model.defaultProfileID = profile.id
                model.persist()
            }
            .disabled(model.defaultProfileID == profile.id)
            .help("Used when no rule matches and nothing is pinned")

            Button("Activate Now") { model.selectProfile(profile.id) }
                .disabled(model.activeProfileID == profile.id)
            Spacer()
        }
    }

    // MARK: - Plumbing

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double,
                        format: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Writes go straight through `updateProfile`, which persists — there is no
    /// separate save step for the user to forget.
    private func binding<V>(_ profile: Profile,
                            _ path: WritableKeyPath<Profile, V>) -> Binding<V> {
        Binding(
            get: { (model.profiles.first { $0.id == profile.id } ?? profile)[keyPath: path] },
            set: { newValue in
                guard var updated = model.profiles.first(where: { $0.id == profile.id })
                else { return }
                updated[keyPath: path] = newValue
                model.updateProfile(updated)
            }
        )
    }
}

import SwiftUI

struct RootView: View {
    @Bindable var store: ModuleStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
        } detail: {
            if let module = store.module(id: store.selectedModuleID) {
                ModuleDetailView(store: store, module: module)
            } else {
                OverviewView(store: store)
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(SwitchboardTheme.background)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        List(selection: $store.selectedModuleID) {
            Button {
                store.selectedModuleID = nil
            } label: {
                Label("Overview", systemImage: "switch.2")
            }
            .buttonStyle(.plain)

            ForEach(store.groups, id: \.self) { group in
                Section(group) {
                    ForEach(store.modules(in: group)) { module in
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: module.id))
                                .frame(width: 18)
                                .foregroundStyle(store.isEnabled(module) ? SwitchboardTheme.accent : .secondary)
                            Text(module.name)
                            Spacer(minLength: 4)
                            if store.isEnabled(module) {
                                Circle().fill(SwitchboardTheme.success).frame(width: 6, height: 6)
                            }
                        }
                        .tag(module.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Switchboard 0.1")
                    .font(.caption.weight(.semibold))
                Text(store.manifest.supportedPlatform)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func symbol(for id: String) -> String {
        if id.contains("warm-corners") { return "rectangle.inset.topleft.filled" }
        if id.contains("kinetics") { return "bolt.horizontal.fill" }
        if id.contains("audio") { return "speaker.wave.2.fill" }
        if id.contains("quit-on-close") { return "macwindow.badge.minus" }
        if id.contains("smart-wake") { return "moon.stars.fill" }
        if id.contains("brightness") { return "sun.max.fill" }
        if id.contains("mail") { return "envelope.fill" }
        if id.contains("copy-path") { return "doc.on.clipboard" }
        if id.contains("auto-install") { return "externaldrive.fill.badge.plus" }
        if id.contains("claude") { return "link.circle.fill" }
        if id.contains("local-read") { return "books.vertical.fill" }
        if id.contains("memory") { return "brain.head.profile.fill" }
        if id.contains("notebooklm") { return "book.pages.fill" }
        if id.contains("repository") { return "shippingbox.fill" }
        return "gearshape.2.fill"
    }
}

private struct OverviewView: View {
    @Bindable var store: ModuleStore

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Mac, one control center")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Choose only the custom utilities and background systems you want. Standalone products and Safari extensions stay separate.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 680, alignment: .leading)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(value: "\(store.manifest.modules.count)", label: "Switchboard modules", color: SwitchboardTheme.accent)
                    MetricCard(value: "\(store.enabledModuleIDs.count)", label: "Enabled now", color: SwitchboardTheme.success)
                    MetricCard(value: "\(store.manifest.standaloneProducts.count)", label: "Standalone products", color: .purple)
                    MetricCard(value: "\(store.manifest.separateSafariApps.count)", label: "Separate Safari apps", color: SwitchboardTheme.warning)
                }

                UpdateCard(store: store)

                OwnershipBoundaryView(store: store)
            }
            .padding(24)
        }
        .background(SwitchboardTheme.background)
    }
}

private struct UpdateCard: View {
    @Bindable var store: ModuleStore

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(SwitchboardTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Updates").font(.system(size: 14, weight: .semibold))
                Text(store.updates.status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.updates.availableUpdate != nil {
                Button("Install Update") { store.installAvailableUpdate() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Check Now") { store.checkForUpdates() }
                    .disabled(store.updates.status == .checking)
            }
        }
        .padding(18)
        .switchboardPanel()
    }
}

private struct MetricCard: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(minWidth: 40, alignment: .leading)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .switchboardPanel()
    }
}

private struct OwnershipBoundaryView: View {
    let store: ModuleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Distribution boundaries")
                .font(.system(size: 15, weight: .semibold))

            HStack(alignment: .top, spacing: 16) {
                boundaryColumn(
                    title: "Stay standalone",
                    subtitle: "Their workers ship in their own DMGs",
                    values: store.manifest.standaloneProducts.map(\.name),
                    color: .purple)
                boundaryColumn(
                    title: "Safari apps",
                    subtitle: "Separate means separate",
                    values: store.manifest.separateSafariApps,
                    color: SwitchboardTheme.warning)
            }
        }
        .padding(18)
        .switchboardPanel()
    }

    private func boundaryColumn(title: String, subtitle: String, values: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            FlowText(values: values)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowText: View {
    let values: [String]
    var body: some View {
        Text(values.joined(separator: "  ·  "))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

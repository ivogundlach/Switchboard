import AppKit
import SwiftUI

struct ModuleDetailView: View {
    @Bindable var store: ModuleStore
    let module: ModuleDefinition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if module.id == "desktop.warm-corners" {
                    WarmCornersSettingsView(store: store)
                }
                if module.id == "desktop.brightness" {
                    BrightnessSettingsView(store: store)
                }
                details
                inventory
            }
            .padding(24)
        }
        .background(SwitchboardTheme.background)
        .alert("Switchboard", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(module.group.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(SwitchboardTheme.accent)
                Text(module.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(module.purpose)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { store.isEnabled(module) },
                    set: { store.setEnabled($0, module: module) }
                ))
                .toggleStyle(.switch)
                .disabled(!store.canEnable(module))
                StatusPill(health: store.health(for: module))
            }
        }
        .padding(18)
        .switchboardPanel()
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            DetailCard(title: "What it includes", values: module.components, empty: "No support components")
            DetailCard(title: "Permissions", values: module.permissionCategories, empty: "No special permission")
            DetailCard(title: "Settings", values: module.configKeys, empty: "No settings")
        }
    }

    private var inventory: some View {
        let jobs = store.scheduledComponents(for: module)
        let commands = store.commands(for: module)
        let services = store.services(for: module)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Owned processes and tools")
                .font(.system(size: 15, weight: .semibold))

            if jobs.isEmpty && commands.isEmpty && services.isEmpty {
                Text("No additional background process or command is assigned to this module yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(jobs) { job in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(SwitchboardTheme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(job.cadence).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if !services.isEmpty {
                DisclosureGroup("macOS Services (\(services.count))") {
                    inventoryNames(services.map(\.name))
                }
            }

            if !commands.isEmpty {
                DisclosureGroup("Commands and implementation files (\(commands.count))") {
                    inventoryNames(commands)
                }
            }
        }
        .padding(18)
        .switchboardPanel()
    }

    private func inventoryNames(_ names: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 7) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(SwitchboardTheme.inset, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.top, 8)
    }
}

private struct BrightnessSettingsView: View {
    @Bindable var store: ModuleStore
    @State private var resultText = "Choose a preset"

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Display brightness").font(.system(size: 15, weight: .semibold))
                Text(resultText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Night · 30%") { apply(store.brightness.setNight()) }
            Button("Day · 100%") { apply(store.brightness.setDay()) }
                .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .switchboardPanel()
    }

    private func apply(_ result: BrightnessResult) {
        switch result {
        case .applied(let level, let count):
            resultText = "Set \(count) display\(count == 1 ? "" : "s") to \(Int(level * 100))%"
        case .failed(let message):
            resultText = message
        }
    }
}

private struct StatusPill: View {
    let health: ModuleHealth

    var body: some View {
        Text(health.label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch health {
        case .ready: SwitchboardTheme.success
        case .disabled: .secondary
        case .unavailable: SwitchboardTheme.warning
        }
    }
}

private struct DetailCard: View {
    let title: String
    let values: [String]
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ForEach(values.isEmpty ? [empty] : values, id: \.self) { value in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(SwitchboardTheme.accent.opacity(0.8)).frame(width: 5, height: 5).padding(.top, 5)
                    Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .switchboardPanel(cornerRadius: 14)
    }
}

private struct WarmCornersSettingsView: View {
    @Bindable var store: ModuleStore
    private var settings: WarmCornerSettings { store.warmCorners }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Corner assignments").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("Start at Login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.launchAtLogin = $0 }
                ))
                .toggleStyle(.switch)
                .disabled(!CanonicalInstallGate.isCanonical())
                .help(CanonicalInstallGate.isCanonical() ? "Start Switchboard automatically" : "Available after Switchboard is installed in Applications")
                Toggle("Pause", isOn: Binding(
                    get: { settings.isPaused },
                    set: { settings.isPaused = $0 }
                )).toggleStyle(.switch)
                Toggle("Countdown", isOn: Binding(
                    get: { settings.showIndicator },
                    set: { settings.showIndicator = $0 }
                )).toggleStyle(.switch)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(WarmCorner.allCases) { corner in
                    WarmCornerCard(
                        corner: corner,
                        action: Binding(
                            get: { settings.action(for: corner) },
                            set: { settings.setAction($0, for: corner) }
                        )
                    )
                }
            }
        }
        .padding(18)
        .switchboardPanel()
    }
}

private struct WarmCornerCard: View {
    let corner: WarmCorner
    @Binding var action: WarmCornerAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(action.isActive ? SwitchboardTheme.accent : .secondary)
                Text(corner.label).font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            Button {
                chooseApp()
            } label: {
                HStack {
                    if let path = action.appPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                    }
                    Text(action.appName ?? "Choose app…").lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SwitchboardTheme.inset, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Delay").font(.caption).foregroundStyle(.secondary)
                Slider(value: $action.delay, in: 0...3, step: 0.05).disabled(!action.isActive)
                Text(action.delay < 0.025 ? "Now" : String(format: "%.2fs", action.delay))
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }

            if action.isActive {
                Button("Clear") { action.appPath = nil }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(13)
        .background(SwitchboardTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var symbol: String {
        switch corner {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            action.appPath = url.path
        }
    }
}

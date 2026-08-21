import SwiftUI

struct RootView: View {
    @Bindable var store: ModuleStore
    @State private var upgradePresented = false

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
        .sheet(isPresented: $upgradePresented) {
            UpgradeReviewView(store: store, isPresented: $upgradePresented)
                .frame(minWidth: 780, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            if store.hasActionableUpgrade { upgradePresented = true }
        }
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
                Text("Switchboard \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
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

                UpgradeCard(store: store)

                OwnershipBoundaryView(store: store)
            }
            .padding(24)
        }
        .background(SwitchboardTheme.background)
    }
}

private struct UpgradeCard: View {
    @Bindable var store: ModuleStore
    @State private var presented = false

    private var detectedCount: Int {
        store.upgradePlan.modules.filter(\.hasLegacyEvidence).count
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.trianglehead.merge")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SwitchboardTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Upgrade from standalone utilities")
                    .font(.system(size: 14, weight: .semibold))
                Text(detectedCount == 0
                    ? "No old Switchboard utilities were detected."
                    : "\(detectedCount) module groups have old apps, settings, commands, or background jobs to review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(detectedCount == 0 ? "Review Status" : "Review Upgrade") { presented = true }
        }
        .padding(18)
        .switchboardPanel()
        .sheet(isPresented: $presented) {
            UpgradeReviewView(store: store, isPresented: $presented)
                .frame(minWidth: 780, minHeight: 680)
                .preferredColorScheme(.dark)
        }
    }
}

private struct UpgradeReviewView: View {
    @Bindable var store: ModuleStore
    @Binding var isPresented: Bool

    private var displayedModules: [LegacyUpgradeModuleReview] { store.upgradePlan.modules }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Move old utilities into Switchboard")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Review every detected component. Your existing settings take priority. Nothing changes until you press Upgrade.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { isPresented = false }
            }
            .padding(22)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(displayedModules) { review in
                            upgradeModuleCard(review)
                        }

                        if store.upgradeState != .idle {
                            permissionAndProgress
                                .id(UpgradeAttentionTarget.permissions.scrollID)
                        }
                    }
                    .padding(22)
                }
                .onChange(of: store.upgradeAttention) { _, event in
                    guard let event else { return }
                    Task { @MainActor in
                        await Task.yield()
                        let anchor: UnitPoint = switch event.target {
                        case .permissions: .top
                        case .moduleResult: .center
                        }
                        proxy.scrollTo(event.target.scrollID, anchor: anchor)
                    }
                }
            }

            Divider()
            footer
                .padding(18)
        }
        .background(SwitchboardTheme.background)
    }

    private func upgradeModuleCard(_ review: LegacyUpgradeModuleReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.module.name).font(.system(size: 14, weight: .semibold))
                    Text(review.legacyEnabled ? "Legacy version is active" : (review.hasLegacyEvidence ? "Legacy files or settings were detected" : "Available in Switchboard"))
                        .font(.caption)
                        .foregroundStyle(review.legacyEnabled ? SwitchboardTheme.success : .secondary)
                }
                Spacer()
                if review.hasMigratableEvidence || !review.hasLegacyEvidence {
                    Toggle("Include", isOn: Binding(
                        get: { store.upgradeSelectedModuleIDs.contains(review.module.id) },
                        set: { store.setUpgradeSelected($0, moduleID: review.module.id) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(store.upgradeState != .idle)
                }
            }

            ForEach(review.components.filter(\.isDetected)) { evidence in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: evidence.component.disposition == .retain ? "exclamationmark.shield" : "arrow.right.circle")
                        .foregroundStyle(evidence.component.disposition == .retain ? SwitchboardTheme.warning : SwitchboardTheme.accent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(evidence.component.displayName).font(.system(size: 11, weight: .semibold))
                            Text(evidence.detection.label)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(evidence.component.disposition == .retain ? SwitchboardTheme.warning : .secondary)
                        }
                        Text(evidence.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if !review.legacySettingsSummary.isEmpty {
                Text("Existing settings kept: \(review.legacySettingsSummary.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let result = store.upgradeResults[review.module.id] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Migrated") ? SwitchboardTheme.success : SwitchboardTheme.warning)
                    .id(UpgradeAttentionTarget.moduleResult(review.module.id).scrollID)
            }
        }
        .padding(15)
        .switchboardPanel(cornerRadius: 14)
    }

    @ViewBuilder
    private var permissionAndProgress: some View {
        if !store.upgradePermissionReviews.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions for selected utilities")
                    .font(.system(size: 15, weight: .semibold))
                Text("Only the exact app or helper that performs the protected action is listed. Administrator access is requested later only when an install actually needs it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.upgradePermissionReviews) { review in
                    permissionRow(review)
                }
            }
            .padding(16)
            .switchboardPanel()
        }

        switch store.upgradeState {
        case .running(_, let message):
            HStack(spacing: 12) {
                ProgressView()
                Text(message).font(.system(size: 13, weight: .semibold))
            }
            .padding(16)
            .switchboardPanel()
        case .completed:
            Label("Upgrade complete", systemImage: "checkmark.seal.fill")
                .foregroundStyle(SwitchboardTheme.success)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .switchboardPanel()
        case .completedWithIssues:
            Label("The healthy replacements are active. Items that could not be retired remain installed and are listed above.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SwitchboardTheme.warning)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .switchboardPanel()
        case .failed(let message):
            Text(message).foregroundStyle(SwitchboardTheme.warning).padding(16).switchboardPanel()
        default:
            EmptyView()
        }
    }

    private func permissionRow(_ review: UpgradePermissionReview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: review.readiness.isBlocking ? "lock.trianglebadge.exclamationmark" : "checkmark.shield")
                .foregroundStyle(review.readiness.isBlocking ? SwitchboardTheme.warning : SwitchboardTheme.success)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(review.permission.displayName).font(.system(size: 12, weight: .semibold))
                Text(review.permission.detail).font(.caption2).foregroundStyle(.secondary)
                Text(review.readiness.label).font(.caption2).foregroundStyle(review.readiness.isBlocking ? SwitchboardTheme.warning : .secondary)
            }
            Spacer()
            if review.readiness.isBlocking {
                if review.permission.mechanism == .appManagementAttestation {
                    Button("Open Settings") { store.requestPermission(review) }
                    Button("I've Enabled It") { store.confirmAppManagement(review) }
                        .buttonStyle(.borderedProminent)
                } else {
                    if review.permission.mechanism == .fullDiskAccessHelper {
                        Button("Reveal Helper") { store.revealPermissionSubject(review) }
                    }
                    Button(review.permission.mechanism == .accessibilityHelper ? "Request Access" : "Open Settings") {
                        store.requestPermission(review)
                    }
                }
            }
        }
        .padding(11)
        .background(SwitchboardTheme.inset, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("Old apps are archived and moved to Trash only after the replacement passes its health check.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            switch store.upgradeState {
            case .idle:
                Button(store.upgradePlan.shouldPresentOnUserLaunch ? "Upgrade Selected Utilities" : "Finish Setup") { store.confirmUpgrade() }
                    .buttonStyle(.borderedProminent)
            case .waitingForPermissions, .confirmed:
                Button("Check Again") { store.checkPermissionsAgain() }
                    .buttonStyle(.borderedProminent)
            case .running:
                ProgressView().controlSize(.small)
            case .completed, .completedWithIssues:
                Button("Done") { isPresented = false }.buttonStyle(.borderedProminent)
            case .failed:
                Button("Close") { isPresented = false }
            }
        }
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

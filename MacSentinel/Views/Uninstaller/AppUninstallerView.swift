import SwiftUI
import AppKit

@Observable
final class AppUninstallerViewModel {
    var apps: [AppBundleInfo] = []
    var isScanning = false
    var selectedAppID: UUID?
    var removeBundle: Bool = true
    var statusMessage = "點擊「掃描應用程式」開始"

    /// Last removal's outcome — surfaced in the detail view so users can act
    /// on items the cascading fallback couldn't reach (com.apple.macl, etc.).
    var lastFailures: [SafeDeleteService.DeletionFailure] = []

    /// Selection state is kept **outside** the heavy AppBundleInfo struct so
    /// toggling a single residual is O(1) on a Set, not O(n) struct copy + List re-render.
    var selectedResidualIDs: Set<UUID> = []

    var selectedApp: AppBundleInfo? {
        guard let id = selectedAppID else { return nil }
        return apps.first { $0.id == id }
    }

    func scan() async {
        isScanning = true
        statusMessage = "掃描中，請稍候…"
        apps = await AppResidualScanner.shared.scanInstalledApps()
        statusMessage = "找到 \(apps.count) 個應用程式"
        isScanning = false
    }

    // MARK: - Selection management

    /// Called when the user picks an app in the list — seeds the selection Set
    /// with whatever was pre-marked in the model (default: all).
    func selectApp(_ app: AppBundleInfo) {
        selectedAppID = app.id
        removeBundle = true
        selectedResidualIDs = Set(app.residuals.filter(\.isSelected).map(\.id))
    }

    func isResidualSelected(_ id: UUID) -> Bool {
        selectedResidualIDs.contains(id)
    }

    func toggleResidual(_ id: UUID) {
        if selectedResidualIDs.contains(id) {
            selectedResidualIDs.remove(id)
        } else {
            selectedResidualIDs.insert(id)
        }
    }

    func selectAllResiduals() {
        guard let app = selectedApp else { return }
        selectedResidualIDs = Set(app.residuals.map(\.id))
    }

    func deselectAllResiduals() {
        selectedResidualIDs.removeAll()
    }

    /// Auto-select only items deemed "safe" or "recommended"
    func selectSafeResiduals() {
        guard let app = selectedApp else { return }
        selectedResidualIDs = Set(
            app.residuals.filter { $0.safetyLevel <= .recommended }.map(\.id)
        )
    }

    /// Bytes that will be removed given the user's current selection on the focused app.
    var selectedRemovalBytes: UInt64 {
        guard let app = selectedApp else { return 0 }
        var total: UInt64 = removeBundle ? app.bundleSizeBytes : 0
        for r in app.residuals where selectedResidualIDs.contains(r.id) {
            total += r.sizeBytes
        }
        return total
    }

    // MARK: - Remove

    func remove(app: AppBundleInfo) async {
        var urls: [URL] = []
        if removeBundle {
            urls.append(URL(fileURLWithPath: app.bundlePath))
        }
        for r in app.residuals where selectedResidualIDs.contains(r.id) {
            urls.append(URL(fileURLWithPath: r.path))
        }
        // Launch agents: include only orphaned + unloaded ones
        for agent in app.launchAgents where agent.isOrphaned && !agent.isLoaded {
            urls.append(URL(fileURLWithPath: agent.plistPath))
        }
        let result = await SafeDeleteService.shared.remove(items: urls)
        lastFailures = result.failures

        if result.failures.isEmpty {
            // All items successfully removed.
            apps.removeAll { $0.id == app.id }
            if selectedAppID == app.id { selectedAppID = nil }
            selectedResidualIDs.removeAll()
            statusMessage = "\(app.name) 已移除"
        } else {
            // Partial — keep the app in the list so the user can see what
            // failed and act on it (the residual rows reflect the disk state).
            let n = result.deleted.count
            let f = result.failures.count
            statusMessage = "\(app.name) 部分移除：成功 \(n) 項、需手動處理 \(f) 項"
        }
    }

    /// Open the offending path in Finder so the user can drag-to-trash.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Retry a single failed URL via the privileged helper (if installed).
    /// Returns true if the helper successfully removed the item.
    @discardableResult
    func retryViaHelper(_ url: URL) async -> Bool {
        let helper = PrivilegedHelperConnection.shared
        guard helper.installStatus == .installed else { return false }
        let (ok, _) = await helper.trashPath(url.path)
        if ok {
            lastFailures.removeAll { $0.url == url }
        }
        return ok
    }
}


struct AppUninstallerView: View {
    @State private var vm = AppUninstallerViewModel()

    var body: some View {
        NavigationSplitView {
            // App list
            VStack(spacing: 0) {
                HStack {
                    Text(vm.statusMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if vm.isScanning { ProgressView().controlSize(.small) }
                    Button("掃描應用程式") { Task { await vm.scan() } }
                        .disabled(vm.isScanning)
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
                Divider()

                List(vm.apps, selection: Binding(
                    get: { vm.selectedAppID },
                    set: { newID in
                        if let id = newID, let app = vm.apps.first(where: { $0.id == id }) {
                            vm.selectApp(app)
                        } else {
                            vm.selectedAppID = nil
                            vm.selectedResidualIDs.removeAll()
                        }
                    }
                )) { app in
                    AppListRow(app: app)
                        .tag(app.id)
                }
                .listStyle(.inset)
            }
        } detail: {
            if vm.selectedApp != nil {
                AppDetailView(vm: vm)
            } else {
                ContentUnavailableView(
                    "選擇應用程式",
                    systemImage: "apps.iphone",
                    description: Text("從左側選擇一個應用程式，查看其殘留檔案。\n所有移除操作都會放入垃圾桶，可隨時還原。")
                )
            }
        }
        .navigationTitle("App 移除器")
    }
}

struct AppListRow: View {
    let app: AppBundleInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.subheadline.bold())
                    ArchBadge(arch: app.architecture)
                }
                Text(app.version).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.format(app.totalSizeBytes))
                    .font(.caption.monospacedDigit())
                if app.totalSizeBytes > app.bundleSizeBytes {
                    Text("+殘留 \(ByteFormatter.format(app.totalSizeBytes - app.bundleSizeBytes))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ArchBadge: View {
    let arch: BinaryArchitecture

    var body: some View {
        Text(arch.label)
            .font(.caption2.bold())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch arch {
        case .arm64:      return .green
        case .x86Only:    return .red
        case .universal2: return .blue
        case .unknown:    return .gray
        }
    }
}

struct AppDetailView: View {
    @Bindable var vm: AppUninstallerViewModel
    @State private var showConfirmation = false

    var body: some View {
        if let app = vm.selectedApp {
            detailBody(app: app)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func detailBody(app: AppBundleInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard(app: app)

                if app.needsRosetta {
                    InfoBanner(
                        color: .orange,
                        icon: "exclamationmark.triangle.fill",
                        title: "Intel-only 應用程式（需要 Rosetta 2）",
                        message: "此 App 是為 Intel Mac 編譯的，在 Apple Silicon 上會透過 Rosetta 2 仿真執行，速度較慢且耗電較多。如果此 App 有 Apple Silicon 原生版本，建議升級；若已不使用，建議移除。"
                    )
                }

                quickActionsBar
                failureSection
                residualSection(app: app)
                launchAgentSection(app: app)
            }
            .padding()
        }
        .confirmationDialog(
            "確定要移除已勾選的 \(ByteFormatter.format(vm.selectedRemovalBytes)) 嗎？",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除（移入垃圾桶）", role: .destructive) {
                Task { await vm.remove(app: app) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let selectedCount = vm.selectedResidualIDs.count
            let bundleNote = vm.removeBundle ? "應用程式本體 + " : ""
            Text("將移除：\(bundleNote)\(selectedCount) 項殘留檔案。所有項目會移入垃圾桶，可從垃圾桶還原。")
        }
    }

    @ViewBuilder
    private func headerCard(app: AppBundleInfo) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                HStack {
                    Text(app.name).font(.title2.bold())
                    ArchBadge(arch: app.architecture)
                }
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                Text("版本 \(app.version)  •  本體 \(ByteFormatter.format(app.bundleSizeBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("勾選 \(ByteFormatter.format(vm.selectedRemovalBytes))")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                Text("總計 \(ByteFormatter.format(app.totalSizeBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("移除已勾選項目") { showConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(vm.selectedRemovalBytes == 0)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var quickActionsBar: some View {
        HStack {
            Toggle("移除應用程式本體", isOn: $vm.removeBundle)
                .toggleStyle(.checkbox)
            Spacer()
            Menu("快速選取殘留") {
                Button("全選") { vm.selectAllResiduals() }
                Button("全不選") { vm.deselectAllResiduals() }
                Divider()
                Button("只選「可安全清除」") { vm.selectSafeResiduals() }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var failureSection: some View {
        if !vm.lastFailures.isEmpty {
            ResidualSection(title: "需要手動處理（\(vm.lastFailures.count) 項）",
                            icon: "exclamationmark.octagon.fill",
                            color: .red) {
                Text("MacSentinel 已嘗試直接刪除與 Finder ACL fallback，但下列項目仍受 com.apple.macl / TCC / 系統管理員權限保護。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(vm.lastFailures, id: \.url) { f in
                    FailureRow(failure: f, vm: vm)
                }
            }
        }
    }

    @ViewBuilder
    private func residualSection(app: AppBundleInfo) -> some View {
        if !app.residuals.isEmpty {
            ResidualSection(title: "殘留檔案", icon: "folder.fill", color: .orange) {
                ForEach(app.residuals) { item in
                    SelectableResidualRow(
                        item: item,
                        isSelected: vm.selectedResidualIDs.contains(item.id),
                        onToggle: { vm.toggleResidual(item.id) }
                    )
                    .equatable()
                }
            }
        }
    }

    @ViewBuilder
    private func launchAgentSection(app: AppBundleInfo) -> some View {
        if !app.launchAgents.isEmpty {
            ResidualSection(title: "啟動項目", icon: "bolt.fill", color: .red) {
                Text("提示：已載入的啟動項目不會自動移除，請先重啟或執行 launchctl unload。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(app.launchAgents) { agent in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(agent.label).font(.caption.bold())
                                SafetyBadge(level: agent.isLoaded ? .risky : .caution, compact: true)
                            }
                            Text(agent.plistPath).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if agent.isOrphaned {
                            Text("孤立").font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                                .background(Color.red.opacity(0.1), in: Capsule())
                        }
                        if agent.isLoaded {
                            Text("已載入").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Failure Row

struct FailureRow: View {
    let failure: SafeDeleteService.DeletionFailure
    let vm: AppUninstallerViewModel
    @State private var retrying = false
    @State private var retryError: String?

    private var helperAvailable: Bool {
        PrivilegedHelperConnection.shared.installStatus == .installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.url.lastPathComponent).font(.caption.bold())
                    Text(failure.url.path).font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(failure.category.rawValue)
                        .font(.caption2.bold())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            Text(failure.suggestion)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("在 Finder 顯示") {
                    vm.revealInFinder(failure.url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if failure.category == .rootRequired || failure.category == .maclACL {
                    Button {
                        Task { await retry() }
                    } label: {
                        if retrying { ProgressView().controlSize(.small) }
                        else { Text(helperAvailable ? "用 Helper 重試" : "Helper 未啟用") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!helperAvailable || retrying)
                }
                if let err = retryError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                Spacer()
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func retry() async {
        retrying = true
        retryError = nil
        let ok = await vm.retryViaHelper(failure.url)
        if !ok { retryError = "Helper 也無法處理此路徑" }
        retrying = false
    }
}

// MARK: - Selectable Residual Row (Equatable for perf)

struct SelectableResidualRow: View, Equatable {
    let item: ResidualItem
    let isSelected: Bool
    let onToggle: () -> Void

    // Re-render this row only when its data or selection actually changes.
    static func == (lhs: SelectableResidualRow, rhs: SelectableResidualRow) -> Bool {
        lhs.item.id == rhs.item.id && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { onToggle() } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: item.category.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.category.rawValue).font(.caption.bold())
                    SafetyBadge(level: item.safetyLevel, compact: true)
                }
                Text(item.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(item.displaySize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .help(item.safetyLevel.rationale)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }   // entire row clickable, not just checkbox
    }
}

// MARK: - Info Banner

struct InfoBanner: View {
    let color: Color
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ResidualSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) { content() }
        } label: {
            Label(title, systemImage: icon).foregroundStyle(color)
        }
    }
}

import SwiftUI

@Observable
final class MigrationViewModel {
    var scanResult: MigrationScanResult?
    var isScanning = false
    var statusMessage = "點擊「開始掃描」檢測舊資料與架構不匹配的項目"

    func scan() async {
        isScanning = true
        statusMessage = "掃描中，正在分析架構與孤立項目…"
        scanResult = await MigrationScanner.shared.fullScan()
        let result = scanResult!
        let total = result.rosettaApps.count
                  + result.orphanedLaunchAgents.count
                  + result.orphanedContainers.count
                  + result.legacyKexts.count
        statusMessage = "發現 \(total) 個遷移相關問題，孤立資料約 \(ByteFormatter.format(result.totalOrphanBytes))"
        isScanning = false
    }

    func removeOrphanedContainer(_ container: OrphanedContainer) async {
        _ = await SafeDeleteService.shared.remove(
            items: [URL(fileURLWithPath: container.containerPath)]
        )
        scanResult?.orphanedContainers.removeAll { $0.id == container.id }
    }

    func removeOrphanedAgent(_ agent: OrphanedLaunchAgent) async {
        _ = await SafeDeleteService.shared.remove(
            items: [URL(fileURLWithPath: agent.plistPath)]
        )
        await AuditLog.shared.record(.launchAgentDisabled(label: agent.label, plistPath: agent.plistPath))
        scanResult?.orphanedLaunchAgents.removeAll { $0.id == agent.id }
    }

    /// Remove an Intel-only application bundle (and its residual files).
    /// Goes through the same SafeDeleteService as the regular uninstaller.
    func removeRosettaApp(_ app: AppBundleInfo) async {
        var urls = [URL(fileURLWithPath: app.bundlePath)]
        urls += app.residuals.map { URL(fileURLWithPath: $0.path) }
        _ = await SafeDeleteService.shared.remove(items: urls)
        scanResult?.rosettaApps.removeAll { $0.id == app.id }
    }

    /// Remove a legacy kext. Loaded kexts CANNOT be removed without root via
    /// kextunload + SIP exceptions — we move the bundle to Trash but warn the
    /// user a restart is required to fully unload.
    /// Set to true when at least one kext was removed in this session —
    /// triggers a reboot reminder.
    var rebootRecommended: Bool = false
    var lastRemovedKextName: String = ""

    func removeKext(_ kext: LegacyKext) async {
        guard !kext.isLoaded else {
            statusMessage = "「\(kext.name)」目前已載入，請先重新開機後再移除（系統會自動卸載未列入啟動項的 kext）。"
            return
        }
        _ = await SafeDeleteService.shared.remove(
            items: [URL(fileURLWithPath: kext.path)]
        )
        scanResult?.legacyKexts.removeAll { $0.id == kext.id }
        // Flag for reboot prompt
        rebootRecommended = true
        lastRemovedKextName = kext.name
    }
}

struct MigrationScanView: View {
    @State private var vm = MigrationViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(vm.statusMessage).font(.subheadline).foregroundStyle(.secondary)
                    if let result = vm.scanResult {
                        Text("孤立資料可釋放：\(ByteFormatter.format(result.totalOrphanBytes))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if vm.isScanning { ProgressView().controlSize(.small) }
                Button("開始掃描") { Task { await vm.scan() } }
                    .disabled(vm.isScanning)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if let result = vm.scanResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // ── 入門引導卡 ──
                        BeginnerIntroCard()

                        // 1. Rosetta Apps
                        MigrationSection(
                            title: "Intel-Only 應用程式",
                            subtitle: "這些 App 僅支援 Intel 晶片。在 Apple Silicon Mac 上需透過 Rosetta 2 仿真執行，效能較慢且更耗電。若該軟體已有 Apple Silicon 原生版本，建議升級；若已不使用，可在此移除。",
                            safety: .caution,
                            icon: "desktopcomputer.trianglebadge.exclamationmark",
                            color: .red,
                            count: result.rosettaApps.count,
                            emptyMessage: "未發現 Intel-only 應用程式 ✓"
                        ) {
                            ForEach(result.rosettaApps) { app in
                                HStack {
                                    ArchBadge(arch: .x86Only)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).font(.subheadline)
                                        Text(app.bundlePath).font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Text(app.version).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(ByteFormatter.format(app.bundleSizeBytes))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Button("移除") {
                                        Task { await vm.removeRosettaApp(app) }
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .tint(.red)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        // 2. Orphaned Launch Agents
                        MigrationSection(
                            title: "孤立的啟動項目",
                            subtitle: "登入時或開機時想自動執行的程式，但實際的執行檔已遺失。常見原因是先前移除過該應用程式但設定殘留。它們會在每次登入時靜默失敗、徒增系統負擔。",
                            safety: .recommended,
                            icon: "bolt.trianglebadge.exclamationmark.fill",
                            color: .orange,
                            count: result.orphanedLaunchAgents.count,
                            emptyMessage: "未發現孤立啟動項目 ✓"
                        ) {
                            ForEach(result.orphanedLaunchAgents) { agent in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.label).font(.caption.bold())
                                        Text("遺失：\(agent.missingExecutable)")
                                            .font(.caption2).foregroundStyle(.red)
                                        Text(agent.plistPath).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button("移除") {
                                        Task { await vm.removeOrphanedAgent(agent) }
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .tint(.orange)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        // 3. Orphaned Containers
                        MigrationSection(
                            title: "找不到對應 App 的資料夾",
                            subtitle: "macOS 沙箱 App 會把資料存在 Container 資料夾（~/Library/Containers/）。掃描發現以下 Container 對應的 App 已不存在，可能是先前移除 App 時殘留下來的孤兒資料。",
                            safety: .recommended,
                            icon: "shippingbox.and.arrow.backward.fill",
                            color: .purple,
                            count: result.orphanedContainers.count,
                            emptyMessage: "未發現孤立 Container ✓"
                        ) {
                            ForEach(result.orphanedContainers) { container in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(container.bundleID).font(.caption.bold())
                                        Text(container.containerPath).font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(container.displaySize)
                                        .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                                    Button("移除") {
                                        Task { await vm.removeOrphanedContainer(container) }
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .tint(.purple)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        // 4. Legacy Kexts
                        MigrationSection(
                            title: "舊式核心擴充（kext）",
                            subtitle: "kext 是會載入到 macOS 核心的驅動程式（用於外接卡、虛擬機器、舊式 RAID、繪圖板等）。Apple Silicon 已不再支援第三方 kext，新的等價技術是 System Extension / DriverKit。⚠️ 移除前請確認該硬體已不使用；已載入的 kext 需重新開機後才會真正卸載。",
                            safety: .risky,
                            icon: "cpu.fill",
                            color: .gray,
                            count: result.legacyKexts.count,
                            emptyMessage: "未發現遺留的 kext ✓"
                        ) {
                            ForEach(result.legacyKexts) { kext in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(kext.name).font(.caption.bold())
                                            if !kext.isAppleSigned {
                                                Text("非官方").font(.caption2)
                                                    .foregroundStyle(.red)
                                                    .padding(.horizontal, 4)
                                                    .background(Color.red.opacity(0.1), in: Capsule())
                                            }
                                        }
                                        Text(kext.bundleID).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if kext.isLoaded {
                                        Text("已載入").font(.caption2).foregroundStyle(.orange)
                                    } else {
                                        Text("未載入").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Button("移除") {
                                        Task { await vm.removeKext(kext) }
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    .tint(.gray)
                                    .disabled(kext.isLoaded)
                                    .help(kext.isLoaded ? "已載入的 kext 須先重開機才能移除" : "")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label("舊資料 / 架構不匹配 掃描", systemImage: "arrow.triangle.2.circlepath.circle")
                        } description: {
                            Text("找出系統中閒置不再使用、或不適合目前晶片架構的殘留資料。")
                        }
                        BeginnerIntroCard()
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                }
            }
        }
        .navigationTitle("舊資料掃描")
        .alert("建議重新開機",
                isPresented: Binding(
                    get: { vm.rebootRecommended },
                    set: { vm.rebootRecommended = $0 }
                )) {
            Button("稍後") { vm.rebootRecommended = false }
            Button("立即重開機", role: .destructive) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "tell application \"System Events\" to restart"]
                try? process.run()
            }
        } message: {
            Text("「\(vm.lastRemovedKextName)」kext 已從磁碟移除，但 kernel cache 仍記得它。重開機後系統才會真正卸載並丟棄它。")
        }
    }
}

// MARK: - Beginner Intro Card

struct BeginnerIntroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                Text("這個功能在做什麼？").font(.headline)
            }
            Text("這項掃描會找出 macOS 上「閒置不再使用」或「不適合目前晶片架構」的舊資料。常見來源包括：升級系統、長期使用、或從舊 Mac 移轉資料時帶過來的殘留。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                BulletItem(icon: "1.circle.fill", color: .red,
                           text: "Intel-only App：在 Apple Silicon（M 系列）需 Rosetta 仿真執行，效能與耗電皆較差")
                BulletItem(icon: "2.circle.fill", color: .orange,
                           text: "孤立啟動項目：登入時想自動啟動，但實際執行檔已不存在")
                BulletItem(icon: "3.circle.fill", color: .purple,
                           text: "孤兒 Container：對應 App 已刪除，但資料夾還留在系統")
                BulletItem(icon: "4.circle.fill", color: .gray,
                           text: "舊式核心擴充（kext）：第三方驅動，在 Apple Silicon 上多半已無法使用")
            }
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.green)
                Text("所有移除都會放入垃圾桶，可以還原。建議先看安全等級標籤再決定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct BulletItem: View {
    let icon: String
    let color: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption)
            Spacer()
        }
    }
}

struct MigrationSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var safety: SafetyLevel? = nil
    let icon: String
    let color: Color
    let count: Int
    let emptyMessage: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = true

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if count == 0 {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(emptyMessage).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        VStack(alignment: .leading, spacing: 4) { content() }
                            .padding(.top, 4)
                    } label: {
                        HStack {
                            Text("找到 \(count) 個項目").font(.subheadline)
                                .foregroundStyle(color)
                            Spacer()
                        }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.headline)
                if let safety = safety { SafetyBadge(level: safety, compact: false) }
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color.opacity(0.15), in: Capsule())
                        .foregroundStyle(color)
                }
            }
        }
    }
}

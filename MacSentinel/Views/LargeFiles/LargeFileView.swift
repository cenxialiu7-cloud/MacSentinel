//
//  LargeFileView.swift
//  MacSentinel
//
//  Sidebar tab for the LargeFileScanner. Two-axis filter (size + age),
//  selectable list, and a single "送垃圾桶" action that routes through
//  SafeDeleteService.
//

import SwiftUI

@Observable
final class LargeFileViewModel {
    var items: [LargeFileItem] = []
    var isScanning = false
    var isDeleting = false
    var statusMessage = "選擇條件後點「掃描」"
    var lastDeletedBytes: UInt64 = 0
    /// Items the multi-tier delete couldn't reach (TCC / macl / hard-protected).
    /// Surface them so the user gets honest feedback rather than a silent
    /// disappear-then-reappear-on-rescan loop.
    var lastSkipped: [URL] = []
    var lastFailures: [SafeDeleteService.DeletionFailure] = []

    // Filter controls
    var sizeThresholdMB: Double = 100
    var ageThresholdDays: Double = 30

    var selectedBytes: UInt64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedCount: Int { items.filter(\.isSelected).count }

    func scan() async {
        isScanning = true
        statusMessage = "正在掃描…"
        let opts = LargeFileScanOptions(
            minSizeBytes: UInt64(sizeThresholdMB * 1_048_576),
            minDays: Int(ageThresholdDays)
        )
        let found = await LargeFileScanner.shared.scan(options: opts)
        items = found
        statusMessage = items.isEmpty
            ? "沒有符合條件的檔案"
            : "找到 \(items.count) 個檔案，共 \(ByteFormatter.format(items.reduce(0) { $0 + $1.sizeBytes }))"
        await AuditLog.shared.record(.scanCompleted(
            type: "large_files",
            itemsFound: items.count,
            totalBytes: items.reduce(0) { $0 + $1.sizeBytes }
        ))
        isScanning = false
    }

    func toggle(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isSelected.toggle()
    }

    func selectAll()   { for i in items.indices { items[i].isSelected = true } }
    func deselectAll() { for i in items.indices { items[i].isSelected = false } }

    func delete() async {
        let urls = items.filter(\.isSelected).map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        isDeleting = true
        statusMessage = "送往垃圾桶…"

        // .userExplicit — the user can see every row and clicked the
        // checkbox themselves. This is the only safe place to allow
        // deletions inside ~/Downloads, ~/Documents, etc.
        let result = await SafeDeleteService.shared.remove(
            items: urls,
            policy: .userExplicit
        )
        lastDeletedBytes = result.totalDeletedBytes
        lastSkipped      = result.skipped
        lastFailures     = result.failures

        // Honest UI: drop ONLY items that actually got trashed. Items still
        // on disk stay in the list — and we tell the user why below.
        let deletedPaths = Set(result.deleted.map { $0.0.path })
        items.removeAll { deletedPaths.contains($0.path) }

        let deletedCount = result.deleted.count
        let stuckCount   = result.skipped.count + result.failures.count
        if stuckCount == 0 {
            statusMessage = "已送往垃圾桶 \(deletedCount) 個檔案，\(ByteFormatter.format(lastDeletedBytes))"
        } else {
            statusMessage = "已送 \(deletedCount) 個（\(ByteFormatter.format(lastDeletedBytes))）；\(stuckCount) 個仍受保護，需手動處理"
        }
        isDeleting = false
    }
}

struct LargeFileView: View {
    @State private var vm = LargeFileViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(vm.statusMessage).foregroundStyle(.secondary).font(.subheadline)
                    Spacer()
                    if vm.isScanning || vm.isDeleting {
                        ProgressView().controlSize(.small)
                    }
                    if !vm.items.isEmpty {
                        Menu("快速選取") {
                            Button("全選") { vm.selectAll() }
                            Button("全不選") { vm.deselectAll() }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 88)
                    }
                    Button("掃描") {
                        Task { await vm.scan() }
                    }
                    .disabled(vm.isScanning || vm.isDeleting)

                    if vm.selectedCount > 0 {
                        Button("送垃圾桶 \(ByteFormatter.format(vm.selectedBytes))") {
                            Task { await vm.delete() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isDeleting)
                    }
                }

                // Filters
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最小大小 \(Int(vm.sizeThresholdMB)) MB")
                            .font(.caption.monospacedDigit())
                        Slider(value: $vm.sizeThresholdMB, in: 50...2048, step: 50)
                            .frame(maxWidth: 280)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最少未存取 \(Int(vm.ageThresholdDays)) 天")
                            .font(.caption.monospacedDigit())
                        Slider(value: $vm.ageThresholdDays, in: 0...365, step: 15)
                            .frame(maxWidth: 280)
                    }
                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Stuck-items banner — honest feedback after a partial delete
            if !vm.lastSkipped.isEmpty || !vm.lastFailures.isEmpty {
                StuckItemsBanner(
                    skipped: vm.lastSkipped,
                    failures: vm.lastFailures
                )
            }

            // List
            if vm.items.isEmpty {
                ContentUnavailableView(
                    "大檔/舊檔掃描",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("拉動上方滑桿調整門檻，點「掃描」尋找 ~/Downloads / Documents / Desktop / Movies / Pictures 內符合條件的檔案。")
                )
            } else {
                List {
                    ForEach(vm.items) { item in
                        LargeFileRow(item: item) { vm.toggle(item.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("大檔／舊檔")
    }
}

// MARK: - Stuck items banner

/// Shown when SafeDeleteService skipped or failed on items the user clicked.
/// Without this, the previous code silently dropped items from the list and
/// the user assumed deletion succeeded — then the next scan rediscovered
/// them and they thought MacSentinel was broken.
struct StuckItemsBanner: View {
    let skipped: [URL]                                    // ProtectedPaths refused
    let failures: [SafeDeleteService.DeletionFailure]    // direct + Finder fallback failed
    @State private var expanded = true

    var total: Int { skipped.count + failures.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("\(total) 個檔案無法自動移到垃圾桶")
                    .font(.subheadline.bold())
                Spacer()
                Button(expanded ? "收合" : "展開") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if expanded {
                ForEach(skipped, id: \.self) { url in
                    StuckRow(
                        url: url,
                        reason: "受 ProtectedPaths 保護（內含敏感資料夾，如 Keychain / Mail / Safari / iCloud / Photos Library）。",
                        category: "受保護"
                    )
                }
                ForEach(failures, id: \.url) { f in
                    StuckRow(
                        url: f.url,
                        reason: f.suggestion,
                        category: f.category.rawValue
                    )
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

private struct StuckRow: View {
    let url: URL
    let reason: String
    let category: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.caption.bold())
                Text(url.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(category)
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
            Button("在 Finder 顯示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Row

struct LargeFileRow: View {
    let item: LargeFileItem
    let onToggle: () -> Void
    @State private var showingReason = false

    var body: some View {
        let rec = item.recommendation

        HStack(spacing: 10) {
            Button { onToggle() } label: {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).font(.subheadline)
                    Button { showingReason = true } label: {
                        Image(systemName: rec.action.systemImage)
                            .font(.caption2)
                            .foregroundStyle(actionColor(rec.action))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingReason, arrowEdge: .top) {
                        ReasonPopover(action: rec.action, text: rec.reasonText)
                    }
                }
                Text(item.directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.displaySize)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
                if item.daysSinceModified > 0 {
                    Text("\(item.daysSinceModified) 天前")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Label("在 Finder 顯示", systemImage: "folder")
            }
        }
    }

    private var iconName: String {
        let ext = (item.path as NSString).pathExtension.lowercased()
        switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi": return "film"
        case "dmg", "iso":                       return "opticaldisc"
        case "zip", "tar", "gz", "bz2", "7z":    return "archivebox"
        case "pdf":                              return "doc.richtext"
        case "psd", "ai", "sketch":              return "paintbrush"
        case "jpg","jpeg","png","heic","tiff":   return "photo"
        default:                                 return "doc"
        }
    }

    private func actionColor(_ action: RecommendedAction) -> Color {
        switch action {
        case .delete:  return .blue
        case .caution: return .orange
        case .keep:    return .green
        }
    }
}

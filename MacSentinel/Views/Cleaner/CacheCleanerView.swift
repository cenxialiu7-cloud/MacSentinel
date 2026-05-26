import SwiftUI

@Observable
final class CacheCleanerViewModel {
    var scanResult: CacheScanResult?
    var isScanning = false
    var isCleaning = false
    var lastCleanedBytes: UInt64 = 0
    var statusMessage = "點擊「掃描」開始分析"

    /// Bytes that will be removed given current selection state.
    var selectedBytes: UInt64 {
        guard let result = scanResult else { return 0 }
        var total: UInt64 = 0
        for cat in result.categories where cat.isSelected {
            for item in cat.items where item.isSelected {
                total += item.sizeBytes
            }
        }
        return total
    }

    func scan() async {
        isScanning = true
        statusMessage = "掃描中…"
        scanResult = await CacheScanner.shared.scan()
        statusMessage = scanResult.map {
            "發現 \(ByteFormatter.format($0.totalReclaimableBytes)) 可清除"
        } ?? "掃描完成"
        await AuditLog.shared.record(.scanCompleted(
            type: "cache",
            itemsFound: scanResult?.categories.reduce(0) { $0 + $1.items.count } ?? 0,
            totalBytes: scanResult?.totalReclaimableBytes ?? 0
        ))
        // Persist scan summary for Before/After deltas
        if let r = scanResult {
            var entry = ScanHistoryEntry(timestamp: Date())
            entry.totalCacheBytes = r.totalReclaimableBytes
            entry.cacheCategoryCount = r.categories.count
            try? ScanHistoryService.append(entry)
        }
        isScanning = false
    }

    func clean() async {
        guard let result = scanResult else { return }
        isCleaning = true
        statusMessage = "清除中…"

        var urls: [URL] = []
        for category in result.categories where category.isSelected {
            for item in category.items where item.isSelected {
                urls.append(URL(fileURLWithPath: item.path))
            }
        }

        let deleteResult = await SafeDeleteService.shared.remove(items: urls)
        lastCleanedBytes = deleteResult.totalDeletedBytes
        statusMessage = "已清除 \(ByteFormatter.format(lastCleanedBytes))"
        scanResult = nil
        isCleaning = false
    }

    // MARK: - Selection helpers

    func toggleCategory(_ id: UUID) {
        guard var result = scanResult,
              let idx = result.categories.firstIndex(where: { $0.id == id }) else { return }
        let newValue = !result.categories[idx].isSelected
        result.categories[idx].isSelected = newValue
        // Cascade to children
        for i in result.categories[idx].items.indices {
            result.categories[idx].items[i].isSelected = newValue
        }
        scanResult = result
    }

    func toggleItem(categoryID: UUID, itemID: UUID) {
        guard var result = scanResult,
              let ci = result.categories.firstIndex(where: { $0.id == categoryID }),
              let ii = result.categories[ci].items.firstIndex(where: { $0.id == itemID })
        else { return }
        result.categories[ci].items[ii].isSelected.toggle()
        // Auto-update the parent: selected iff at least one child is selected
        result.categories[ci].isSelected = result.categories[ci].items.contains { $0.isSelected }
        scanResult = result
    }

    func selectAll() {
        guard var result = scanResult else { return }
        for ci in result.categories.indices {
            result.categories[ci].isSelected = true
            for ii in result.categories[ci].items.indices {
                result.categories[ci].items[ii].isSelected = true
            }
        }
        scanResult = result
    }

    func deselectAll() {
        guard var result = scanResult else { return }
        for ci in result.categories.indices {
            result.categories[ci].isSelected = false
            for ii in result.categories[ci].items.indices {
                result.categories[ci].items[ii].isSelected = false
            }
        }
        scanResult = result
    }

    /// Quickly select only items classified as "safe"
    func selectSafeOnly() {
        guard var result = scanResult else { return }
        for ci in result.categories.indices {
            var anySelected = false
            for ii in result.categories[ci].items.indices {
                let isSafe = result.categories[ci].items[ii].safetyLevel == .safe
                result.categories[ci].items[ii].isSelected = isSafe
                if isSafe { anySelected = true }
            }
            result.categories[ci].isSelected = anySelected
        }
        scanResult = result
    }
}

struct CacheCleanerView: View {
    @State private var vm = CacheCleanerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(vm.statusMessage).foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                if vm.isScanning || vm.isCleaning {
                    ProgressView().controlSize(.small)
                }

                if vm.scanResult != nil {
                    Menu("快速選取") {
                        Button("全選") { vm.selectAll() }
                        Button("全不選") { vm.deselectAll() }
                        Divider()
                        Button("只選「可安全清除」") { vm.selectSafeOnly() }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 88)
                }

                Button("掃描") {
                    Task { await vm.scan() }
                }
                .disabled(vm.isScanning || vm.isCleaning)

                if let result = vm.scanResult {
                    Button {
                        exportForAI(result)
                    } label: {
                        Label("匯出 JSON", systemImage: "square.and.arrow.up")
                    }
                    .help("匯出掃描結果為 JSON，可給本機 AI 助理（已啟用 MCP 時可直接呼叫）")

                    Button("清除 \(ByteFormatter.format(vm.selectedBytes))") {
                        Task { await vm.clean() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isCleaning || vm.selectedBytes == 0)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if let result = vm.scanResult {
                List {
                    ForEach(result.categories) { category in
                        CacheCategoryRow(
                            category: category,
                            onToggleCategory: { vm.toggleCategory(category.id) },
                            onToggleItem: { itemID in vm.toggleItem(categoryID: category.id, itemID: itemID) }
                        )
                    }
                }
                .listStyle(.inset)
            } else if vm.lastCleanedBytes > 0 {
                VStack(spacing: 16) {
                    ContentUnavailableView {
                        Label("清除完成", systemImage: "checkmark.circle.fill")
                    } description: {
                        VStack(spacing: 4) {
                            Text("已移到垃圾桶 \(ByteFormatter.format(vm.lastCleanedBytes))")
                            Text("⚠️ macOS 在「清空垃圾桶」前不會真正釋放磁碟空間")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Button {
                        _ = TrashService.emptyTrash()
                    } label: {
                        Label("立刻清空垃圾桶（真正釋放磁碟空間）",
                              systemImage: "trash.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                }
                .padding()
            } else {
                ContentUnavailableView {
                    Label("尚未掃描", systemImage: "trash.circle")
                } description: {
                    Text("點擊「掃描」分析可清除的快取與垃圾檔案。\n所有刪除都會先放入垃圾桶，可隨時還原。")
                }
            }
        }
        .navigationTitle("快取清理")
    }

    private func exportForAI(_ result: CacheScanResult) {
        let report = AIScanReporter.shared.report(from: result)
        do {
            let url = try AIScanReporter.shared.exportToTempFile(report)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("Failed to export AI report: \(error)")
        }
    }
}

struct CacheCategoryRow: View {
    let category: CacheCategory
    let onToggleCategory: () -> Void
    let onToggleItem: (UUID) -> Void
    @State private var isExpanded = true

    private var categorySafety: SafetyLevel {
        SafetyClassifier.classify(cacheCategory: category.type)
    }

    /// Three-state check: all / partial / none
    private var checkSymbol: String {
        let selected = category.items.filter(\.isSelected).count
        if selected == 0 { return "square" }
        if selected == category.items.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(category.items) { item in
                CacheItemRow(item: item, onToggle: { onToggleItem(item.id) })
            }
        } label: {
            HStack {
                Button { onToggleCategory() } label: {
                    Image(systemName: checkSymbol)
                        .foregroundStyle(category.isSelected ? Color.accentColor : Color.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Image(systemName: category.type.icon)
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                Text(category.type.rawValue).font(.headline)
                SafetyBadge(level: categorySafety)
                Spacer()
                Text(category.displaySize)
                    .font(.subheadline.bold().monospacedDigit())
            }
        }
    }
}

struct CacheItemRow: View {
    let item: CacheItem
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Button { onToggle() } label: {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).font(.subheadline)
                    SafetyBadge(level: item.safetyLevel, compact: true)
                }
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(item.displaySize)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(item.safetyLevel.rationale)
    }
}

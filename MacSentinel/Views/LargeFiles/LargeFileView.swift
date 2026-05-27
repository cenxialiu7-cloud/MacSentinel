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
        let result = await SafeDeleteService.shared.remove(items: urls)
        lastDeletedBytes = result.totalDeletedBytes
        items.removeAll { item in urls.contains(URL(fileURLWithPath: item.path)) }
        statusMessage = "已送往垃圾桶 \(ByteFormatter.format(lastDeletedBytes))"
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

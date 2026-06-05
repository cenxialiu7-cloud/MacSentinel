//
//  DuplicateFileView.swift
//  MacSentinel
//
//  Sidebar tab for DuplicateScanner. Presents duplicate groups; user can
//  expand a group to see all copies, mark which to delete (defaults: keep
//  newest, mark older ones for deletion). One-click "智慧選取" automates
//  the default policy across all groups.
//

import SwiftUI

@Observable
final class DuplicateFileViewModel {
    var groups: [DuplicateGroup] = []
    var isScanning = false
    var isDeleting = false
    var statusMessage = "點「掃描」開始尋找重複檔案"
    var minSizeMB: Double = 1   // skip files smaller than this
    /// Items the delete couldn't reach; surfaced to the user instead of
    /// silently disappearing from the list.
    var lastSkipped: [URL] = []
    var lastFailures: [SafeDeleteService.DeletionFailure] = []

    var totalReclaimable: UInt64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
    var markedBytes: UInt64 {
        groups.reduce(0) { sum, g in
            let count = g.files.filter(\.markedForDeletion).count
            return sum + UInt64(count) * g.sizeBytes
        }
    }
    var markedCount: Int {
        groups.reduce(0) { $0 + $1.files.filter(\.markedForDeletion).count }
    }

    func scan() async {
        isScanning = true
        statusMessage = "掃描中（可能需要數分鐘，視檔案數量而定）…"
        let opts = DuplicateScanOptions(minSizeBytes: UInt64(minSizeMB * 1_048_576))
        groups = await DuplicateScanner.shared.scan(options: opts)
        statusMessage = groups.isEmpty
            ? "沒有找到重複檔案"
            : "找到 \(groups.count) 組重複，可釋出 \(ByteFormatter.format(totalReclaimable))"
        await AuditLog.shared.record(.scanCompleted(
            type: "duplicates",
            itemsFound: groups.flatMap(\.files).count,
            totalBytes: totalReclaimable
        ))
        isScanning = false
    }

    /// Default policy: keep newest, mark all older copies for deletion.
    func smartSelect() {
        for gIdx in groups.indices {
            for fIdx in groups[gIdx].files.indices {
                // files were sorted newest-first by the scanner
                groups[gIdx].files[fIdx].markedForDeletion = fIdx > 0
            }
        }
    }

    func clearSelection() {
        for gIdx in groups.indices {
            for fIdx in groups[gIdx].files.indices {
                groups[gIdx].files[fIdx].markedForDeletion = false
            }
        }
    }

    func toggle(groupID: UUID, fileID: UUID) {
        guard let gIdx = groups.firstIndex(where: { $0.id == groupID }),
              let fIdx = groups[gIdx].files.firstIndex(where: { $0.id == fileID }) else { return }
        // Guard: never mark all files in a group for deletion
        var copy = groups[gIdx]
        copy.files[fIdx].markedForDeletion.toggle()
        if copy.files.allSatisfy(\.markedForDeletion) {
            // Re-enable the most recent file
            copy.files[0].markedForDeletion = false
        }
        groups[gIdx] = copy
    }

    func delete() async {
        var urls: [URL] = []
        for g in groups {
            for f in g.files where f.markedForDeletion {
                urls.append(URL(fileURLWithPath: f.path))
            }
        }
        guard !urls.isEmpty else { return }
        isDeleting = true
        statusMessage = "送往垃圾桶 \(urls.count) 個檔案…"

        // .userExplicit — user can see every file row + checkbox.
        let result = await SafeDeleteService.shared.remove(
            items: urls,
            policy: .userExplicit
        )
        lastSkipped  = result.skipped
        lastFailures = result.failures

        // Honest UI: only drop items that actually got trashed. A group with
        // <2 files left is no longer a duplicate group.
        let deletedPaths = Set(result.deleted.map { $0.0.path })
        groups = groups.compactMap { g in
            var copy = g
            copy.files.removeAll { deletedPaths.contains($0.path) }
            return copy.files.count >= 2 ? copy : nil
        }

        let deletedCount = result.deleted.count
        let stuckCount   = result.skipped.count + result.failures.count
        if stuckCount == 0 {
            statusMessage = "已送往垃圾桶 \(deletedCount) 個檔案，\(ByteFormatter.format(result.totalDeletedBytes))"
        } else {
            statusMessage = "已送 \(deletedCount) 個（\(ByteFormatter.format(result.totalDeletedBytes))）；\(stuckCount) 個仍受保護"
        }
        isDeleting = false
    }
}

struct DuplicateFileView: View {
    @State private var vm = DuplicateFileViewModel()
    @State private var expandedGroups: Set<UUID> = []

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
                    if !vm.groups.isEmpty {
                        Menu("快速選取") {
                            Button("智慧選取（保留最新）") { vm.smartSelect() }
                            Button("全不選") { vm.clearSelection() }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 110)
                    }
                    Button("掃描") { Task { await vm.scan() } }
                        .disabled(vm.isScanning || vm.isDeleting)
                    if vm.markedCount > 0 {
                        Button("送垃圾桶 \(ByteFormatter.format(vm.markedBytes))") {
                            Task { await vm.delete() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isDeleting)
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("略過小於 \(Int(vm.minSizeMB)) MB 的檔案")
                            .font(.caption.monospacedDigit())
                        Slider(value: $vm.minSizeMB, in: 1...100, step: 1)
                            .frame(maxWidth: 280)
                    }
                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if !vm.lastSkipped.isEmpty || !vm.lastFailures.isEmpty {
                StuckItemsBanner(
                    skipped: vm.lastSkipped,
                    failures: vm.lastFailures
                )
            }

            if vm.groups.isEmpty && !vm.isScanning {
                ContentUnavailableView(
                    "重複檔案掃描",
                    systemImage: "doc.on.doc.fill",
                    description: Text("以 SHA-256 內容比對找出 Downloads / Documents / Desktop / Movies / Pictures 中的重複副本。三階段演算法（大小 → 4KB → 完整 hash），即使檔名不同也能配對。")
                )
            } else {
                List {
                    ForEach(vm.groups) { group in
                        DuplicateGroupRow(
                            group: group,
                            isExpanded: expandedGroups.contains(group.id),
                            onToggleExpand: {
                                if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) }
                                else { expandedGroups.insert(group.id) }
                            },
                            onToggleFile: { fileID in
                                vm.toggle(groupID: group.id, fileID: fileID)
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("重複檔案")
    }
}

// MARK: - Group row

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleFile: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            HStack(spacing: 10) {
                Button { onToggleExpand() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.mint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files.first?.name ?? "(unnamed)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(group.files.count) 份副本，每份 \(ByteFormatter.format(group.sizeBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Text("可省 \(ByteFormatter.format(group.reclaimableBytes))")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            .padding(.vertical, 6)

            // Expanded file list
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { idx, f in
                        DuplicateFileRow(
                            file: f,
                            isNewest: idx == 0,
                            onToggle: { onToggleFile(f.id) }
                        )
                        if f.id != group.files.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, 4)
            }
        }
    }
}

struct DuplicateFileRow: View {
    let file: DuplicateFile
    let isNewest: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { onToggle() } label: {
                Image(systemName: file.markedForDeletion ? "checkmark.square.fill" : "square")
                    .foregroundStyle(file.markedForDeletion ? .red : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(file.name).font(.caption)
                    if isNewest {
                        Text("最新")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(file.directory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let modDate = file.modificationDate {
                Text(modDate, style: .date)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Label("在 Finder 顯示", systemImage: "folder")
            }
        }
    }
}

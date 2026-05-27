//
//  DiskDetailView.swift
//  MacSentinel
//
//  Disk drill-down: total/free + a list of fat directories (Xcode DerivedData,
//  Docker, Trash, etc.) and Top-50 individual files > 1 GB sourced from
//  Spotlight. Click a hotspot to open it in Finder; click a large file to
//  reveal it.
//

import SwiftUI
import Charts

@Observable
final class DiskDetailViewModel {
    var hotspots: [DiskHotspot] = []
    var largeFiles: [LargeFileHit] = []
    var isLoading = false
    var statusMessage = "正在掃描熱點目錄與大檔案…"
    var minLargeFileMB: Double = 1024     // 1 GB default

    func refresh() async {
        isLoading = true
        statusMessage = "掃描中…"
        let (h, l) = await DiskHotspotService.snapshot(minLargeFileSizeMB: Int(minLargeFileMB))
        hotspots = h
        largeFiles = l
        let totalHotspotBytes = h.reduce(0) { $0 + $1.sizeBytes }
        statusMessage = "找到 \(h.count) 個熱點目錄（共 \(ByteFormatter.format(totalHotspotBytes))）+ \(l.count) 個 > \(Int(minLargeFileMB)) MB 的檔案"
        isLoading = false
    }
}

struct DiskDetailView: View {
    @Environment(SystemDataCollector.self) var collector
    @State private var vm = DiskDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snap = collector.latestSnapshot {
                    headerSection(snap.disk)
                }
                controlsSection
                hotspotsSection
                largeFilesSection
            }
            .padding(24)
        }
        .navigationTitle("磁碟細節")
        .task { await vm.refresh() }
    }

    // MARK: - Header

    private func headerSection(_ d: DiskSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading) {
                Text(String(format: "%.0f%%", d.usagePercent))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(alertColor(d.alertLevel))
                    .monospacedDigit()
                Text("使用中").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 56)
            VStack(alignment: .leading, spacing: 4) {
                KVRow(key: "可用", value: ByteFormatter.format(d.freeBytes))
                KVRow(key: "總量", value: ByteFormatter.format(d.totalBytes))
                KVRow(key: "卷宗", value: "/")
            }
            .frame(width: 220)
            Spacer()
        }
    }

    private var controlsSection: some View {
        GroupBox {
            HStack {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button("重新掃描") { Task { await vm.refresh() } }
                    .disabled(vm.isLoading)
            }
            HStack {
                Text("大檔門檻 \(Int(vm.minLargeFileMB)) MB")
                    .font(.caption.monospacedDigit())
                    .frame(width: 140, alignment: .leading)
                Slider(value: $vm.minLargeFileMB, in: 100...5120, step: 100)
            }
        }
    }

    // MARK: - Hotspots

    private var hotspotsSection: some View {
        GroupBox("常見大目錄") {
            if vm.hotspots.isEmpty && !vm.isLoading {
                Text("沒找到任何熱點目錄。").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.hotspots) { h in
                        HotspotRow(hotspot: h)
                        if h.id != vm.hotspots.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Large files

    private var largeFilesSection: some View {
        GroupBox("大檔案（Spotlight，Top \(vm.largeFiles.count)）") {
            if vm.largeFiles.isEmpty && !vm.isLoading {
                Text("沒找到大於 \(Int(vm.minLargeFileMB)) MB 的個別檔案。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.largeFiles.prefix(50)) { hit in
                        LargeFileHitRow(hit: hit)
                        if hit.id != vm.largeFiles.prefix(50).last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func alertColor(_ level: AlertLevel) -> Color {
        switch level {
        case .normal:   return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Rows

struct HotspotRow: View {
    let hotspot: DiskHotspot
    @State private var showingTip = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hotspot.label).font(.callout.weight(.medium))
                Text(hotspot.path)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormatter.format(hotspot.sizeBytes))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Button { showingTip = true } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingTip, arrowEdge: .leading) {
                Text(hotspot.recommendation)
                    .font(.callout)
                    .padding(14)
                    .frame(width: 320)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hotspot.path)])
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hotspot.path)])
            } label: {
                Label("在 Finder 顯示", systemImage: "folder")
            }
        }
    }
}

struct LargeFileHitRow: View {
    let hit: LargeFileHit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name).font(.caption.weight(.medium))
                Text(hit.directory)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormatter.format(hit.sizeBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
            } label: {
                Label("在 Finder 顯示", systemImage: "folder")
            }
        }
    }
}

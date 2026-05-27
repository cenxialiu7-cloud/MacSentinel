//
//  MemoryDetailView.swift
//  MacSentinel
//
//  Memory drill-down: pressure light, layered composition bar, swap, and
//  Top-10 processes by real memory footprint.
//

import SwiftUI
import Charts

struct MemoryDetailView: View {
    @Environment(SystemDataCollector.self) var collector
    @Environment(ProcessSnapshotService.self) var processes
    @State private var isPurging = false
    @State private var purgeMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snap = collector.latestSnapshot {
                    headerSection(snap.memory)
                    purgeSection(snap.memory)
                    pressureSection(snap.memory)
                    compositionSection(snap.memory)
                    historySection
                    topProcessesSection
                } else {
                    ProgressView("載入中…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .navigationTitle("記憶體細節")
    }

    // MARK: - Purge button

    private func purgeSection(_ m: MemorySnapshot) -> some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("一鍵釋放可清除的記憶體")
                        .font(.callout.weight(.medium))
                    Text("透過 /usr/bin/purge 強制清空檔案快取與 inactive 頁面。需要管理員密碼。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let purgeMessage {
                        Text(purgeMessage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(purgeMessage.contains("失敗") || purgeMessage.contains("取消")
                                             ? .orange : .green)
                            .padding(.top, 2)
                    }
                }
                Spacer()
                Button {
                    Task { await runPurge() }
                } label: {
                    if isPurging {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("釋放中…")
                        }
                    } else {
                        Text("立即釋放")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPurging)
            }
            .padding(.vertical, 4)
        }
    }

    private func runPurge() async {
        isPurging = true
        purgeMessage = nil
        let result = await Self.invokePurge()
        purgeMessage = result
        // Trigger an immediate re-sample so the UI reflects the change
        await collector.sample()
        isPurging = false
    }

    /// Invoke /usr/bin/purge via osascript with administrator privileges.
    /// Returns a human-readable status message.
    private static func invokePurge() async -> String {
        await Task.detached(priority: .userInitiated) {
            let script = "do shell script \"/usr/bin/purge\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err = err {
                if (err["NSAppleScriptErrorNumber"] as? Int) == -128 {
                    return "已取消（未輸入管理員密碼）。"
                }
                let msg = err["NSAppleScriptErrorMessage"] as? String ?? "未知錯誤"
                return "失敗：\(msg)"
            }
            return "已釋放（請查看下方記憶體曲線變化）。"
        }.value
    }

    // MARK: - Header

    private func headerSection(_ m: MemorySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading) {
                Text(String(format: "%.0f%%", m.usagePercent))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(alertColor(m.alertLevel))
                    .monospacedDigit()
                Text("\(ByteFormatter.format(m.usedBytes)) / \(ByteFormatter.format(m.totalBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 56)
            VStack(alignment: .leading, spacing: 4) {
                KVRow(key: "Wired", value: ByteFormatter.format(m.wiredBytes))
                KVRow(key: "Compressed", value: ByteFormatter.format(m.compressedBytes))
                KVRow(key: "Swap", value: ByteFormatter.format(m.swapUsedBytes))
            }
            .frame(width: 220)
            Spacer()
        }
    }

    // MARK: - Pressure light

    private func pressureSection(_ m: MemorySnapshot) -> some View {
        GroupBox("記憶體壓力") {
            HStack(spacing: 14) {
                Circle()
                    .fill(pressureColor(m.pressureLevel))
                    .frame(width: 16, height: 16)
                    .shadow(color: pressureColor(m.pressureLevel).opacity(0.6), radius: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pressureLabel(m.pressureLevel))
                        .font(.headline)
                        .foregroundStyle(pressureColor(m.pressureLevel))
                    Text(pressureDescription(m.pressureLevel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if m.swapUsedBytes > 1_073_741_824 {
                    VStack(alignment: .trailing) {
                        Text("Swap > 1 GB").font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("RAM 可能不夠")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Composition stacked bar

    private func compositionSection(_ m: MemorySnapshot) -> some View {
        GroupBox("記憶體組成") {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(compositionSegments(m), id: \.label) { seg in
                            Rectangle()
                                .fill(seg.color)
                                .frame(width: max(2, CGFloat(seg.fraction) * geo.size.width))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 22)

                // Legend
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 6) {
                    ForEach(compositionSegments(m), id: \.label) { seg in
                        HStack(spacing: 6) {
                            Circle().fill(seg.color).frame(width: 8, height: 8)
                            Text(seg.label).font(.caption)
                            Spacer(minLength: 0)
                            Text(ByteFormatter.format(seg.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - History

    private var historySection: some View {
        GroupBox("最近採樣") {
            Chart {
                ForEach(Array(collector.history.enumerated()), id: \.offset) { idx, snap in
                    LineMark(x: .value("t", idx), y: .value("used%", snap.memory.usagePercent))
                        .foregroundStyle(.purple)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 100)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Top processes by memory

    private var topProcessesSection: some View {
        GroupBox("最耗記憶體的程序（Top 10）") {
            let top = processes.processes
                .sorted { $0.memoryBytes > $1.memoryBytes }
                .prefix(10)

            VStack(spacing: 0) {
                if top.isEmpty {
                    Text("正在收集程序資料…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding()
                } else {
                    ForEach(Array(top)) { p in
                        TopProcessRow(
                            process: p,
                            primaryValue: ByteFormatter.format(p.memoryBytes),
                            primaryColor: memColor(p.memoryBytes),
                            secondaryValue: String(format: "%.1f%% CPU", p.cpuPercent)
                        )
                        if p.id != top.last?.id { Divider() }
                    }
                }
            }
            .padding(.vertical, 4)
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

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal:   return "正常"
        case .warning:  return "偏緊"
        case .critical: return "緊張"
        }
    }

    private func pressureDescription(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal:
            return "目前 RAM 充足，系統不必壓縮或交換到磁碟。"
        case .warning:
            return "RAM 開始吃緊，macOS 已啟動記憶體壓縮以維持效能。"
        case .critical:
            return "RAM 嚴重不足，已大量寫入 swap，請考慮關閉部分應用或重啟。"
        }
    }

    private func memColor(_ bytes: UInt64) -> Color {
        switch bytes {
        case 4_294_967_296...: return .red       // > 4 GB
        case 2_147_483_648...: return .orange    // > 2 GB
        case 524_288_000...:   return .blue      // > 500 MB
        default:               return .secondary
        }
    }

    private struct Segment { let label: String; let bytes: UInt64; let fraction: Double; let color: Color }

    private func compositionSegments(_ m: MemorySnapshot) -> [Segment] {
        let total = Double(max(m.totalBytes, 1))
        let app = m.usedBytes >= (m.wiredBytes + m.compressedBytes)
            ? m.usedBytes - m.wiredBytes - m.compressedBytes
            : 0
        return [
            Segment(label: "App",       bytes: app,                fraction: Double(app) / total,                color: .blue),
            Segment(label: "Wired",     bytes: m.wiredBytes,       fraction: Double(m.wiredBytes) / total,       color: .yellow),
            Segment(label: "Compressed",bytes: m.compressedBytes,  fraction: Double(m.compressedBytes) / total,  color: .purple),
            Segment(label: "Free",      bytes: m.freeBytes,        fraction: Double(m.freeBytes) / total,        color: .green.opacity(0.5))
        ]
    }
}

//
//  CPUDetailView.swift
//  MacSentinel
//
//  CPU drill-down: per-core bars, sparkline, and Top-10 processes by CPU.
//

import SwiftUI
import Charts

struct CPUDetailView: View {
    @Environment(SystemDataCollector.self) var collector
    @Environment(ProcessSnapshotService.self) var processes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snap = collector.latestSnapshot {
                    headerSection(snap.cpu)
                    coreSection(snap.cpu)
                    historySection
                    topProcessesSection
                } else {
                    ProgressView("載入中…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .navigationTitle("CPU 細節")
    }

    // MARK: - Header

    private func headerSection(_ cpu: CPUSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading) {
                Text(String(format: "%.1f%%", cpu.usagePercent))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(alertColor(cpu.alertLevel))
                    .monospacedDigit()
                Text("整體使用率").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 56)
            VStack(alignment: .leading, spacing: 4) {
                KVRow(key: "系統", value: String(format: "%.1f%%", cpu.systemPercent))
                KVRow(key: "使用者", value: String(format: "%.1f%%", cpu.userPercent))
                KVRow(key: "閒置", value: String(format: "%.1f%%", cpu.idlePercent))
            }
            .frame(width: 180)
            Spacer()
        }
    }

    // MARK: - Per-core

    private func coreSection(_ cpu: CPUSnapshot) -> some View {
        GroupBox("每核心使用率（\(cpu.coreUsages.count) cores）") {
            VStack(alignment: .leading, spacing: 6) {
                if cpu.coreUsages.isEmpty {
                    Text("無資料").font(.caption).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                       count: min(cpu.coreUsages.count, 8)),
                        spacing: 8
                    ) {
                        ForEach(Array(cpu.coreUsages.enumerated()), id: \.offset) { idx, val in
                            CoreBar(coreIdx: idx, usage: val)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - History sparkline (60 samples)

    private var historySection: some View {
        GroupBox("最近 \(collector.history.count) 筆採樣") {
            Chart {
                ForEach(Array(collector.history.enumerated()), id: \.offset) { idx, snap in
                    AreaMark(x: .value("t", idx), y: .value("user", snap.cpu.userPercent))
                        .foregroundStyle(.blue.opacity(0.4))
                    AreaMark(x: .value("t", idx), y: .value("sys", snap.cpu.systemPercent))
                        .foregroundStyle(.purple.opacity(0.3))
                        .position(by: .value("kind", "system"))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 120)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Top processes

    private var topProcessesSection: some View {
        GroupBox("最耗 CPU 的程序（Top 10）") {
            let top = processes.processes
                .sorted { $0.cpuPercent > $1.cpuPercent }
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
                            primaryValue: String(format: "%.1f%%", p.cpuPercent),
                            primaryColor: cpuColor(p.cpuPercent)
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

    private func cpuColor(_ percent: Double) -> Color {
        switch percent {
        case 80...: return .red
        case 50...: return .orange
        case 20...: return .blue
        default:    return .secondary
        }
    }
}

// MARK: - Per-core bar

struct CoreBar: View {
    let coreIdx: Int
    let usage: Double

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [color, color.opacity(0.6)],
                        startPoint: .bottom, endPoint: .top
                    ))
                    .frame(height: max(2, CGFloat(usage / 100) * 60))
            }
            .frame(height: 60)
            Text("\(coreIdx)").font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(usage))%").font(.caption2.weight(.medium)).monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch usage {
        case 80...: return .red
        case 50...: return .orange
        default:    return .blue
        }
    }
}

// MARK: - Top process row (shared with Memory/Network drill-downs later)

struct TopProcessRow: View {
    let process: ProcessInfo
    let primaryValue: String
    let primaryColor: Color
    var secondaryValue: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ProcessIconView(executablePath: process.executablePath,
                            bundleId: process.bundleIdentifier,
                            fallbackSymbol: process.icon ?? "app.dashed")
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("PID \(process.id)" + (process.bundleIdentifier.map { "  ·  \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryValue)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(primaryColor)
                    .monospacedDigit()
                if let secondaryValue {
                    Text(secondaryValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

// MARK: - Process icon loader

struct ProcessIconView: View {
    let executablePath: String
    let bundleId: String?
    let fallbackSymbol: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable().scaledToFit()
                    .foregroundStyle(.tint)
                    .padding(4)
            }
        }
        .task {
            image = await loadIcon()
        }
    }

    private func loadIcon() async -> NSImage? {
        // Strategy: walk up from the executable path until we find a .app bundle,
        // then ask NSWorkspace for that bundle's icon. Falls back to the raw exec.
        await Task.detached(priority: .utility) { [executablePath] in
            var path = (executablePath as NSString).deletingLastPathComponent
            while !path.isEmpty, path != "/" {
                if path.hasSuffix(".app") {
                    return NSWorkspace.shared.icon(forFile: path)
                }
                path = (path as NSString).deletingLastPathComponent
            }
            if !executablePath.isEmpty {
                return NSWorkspace.shared.icon(forFile: executablePath)
            }
            return nil
        }.value
    }
}

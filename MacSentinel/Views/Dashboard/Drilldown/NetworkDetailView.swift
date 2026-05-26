//
//  NetworkDetailView.swift
//  MacSentinel
//
//  Network drill-down: per-process throughput sourced from `nettop -d`, plus
//  total in/out sparkline. No NetworkExtension required.
//

import SwiftUI
import Charts

struct NetworkDetailView: View {
    @Environment(SystemDataCollector.self) var collector
    @Environment(ProcessSnapshotService.self) var processes
    @State private var nettop = NetTopService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                sparklineSection
                topProcessesSection
            }
            .padding(24)
        }
        .navigationTitle("網路細節")
        .task {
            nettop.start()
        }
        .onDisappear {
            nettop.stop()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.title3).foregroundStyle(.blue)
                    Text(ByteFormatter.formatSpeed(Double(nettop.totalInPerSec)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Text("下行").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.title3).foregroundStyle(.orange)
                    Text(ByteFormatter.formatSpeed(Double(nettop.totalOutPerSec)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Text("上行").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let snap = collector.latestSnapshot {
                VStack(alignment: .trailing) {
                    Text(snap.network.activeInterface)
                        .font(.callout.weight(.medium))
                    Text("使用中介面").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Sparkline

    private var sparklineSection: some View {
        GroupBox("最近 \(nettop.history.count) 秒") {
            Chart {
                ForEach(Array(nettop.history.enumerated()), id: \.offset) { idx, sample in
                    LineMark(x: .value("t", idx), y: .value("in", sample.0))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", idx), y: .value("out", sample.1))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 100)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Top processes

    private var topProcessesSection: some View {
        GroupBox(label: HStack {
            Text("使用網路的程序（Top 10）")
            Spacer()
            if !nettop.isRunning {
                ProgressView().controlSize(.small)
            }
        }) {
            let top = Array(nettop.entries.prefix(10))

            VStack(spacing: 0) {
                if top.isEmpty {
                    Text(nettop.lastError ?? "正在等待第一筆 delta 樣本（約 2 秒）…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding()
                } else {
                    ForEach(top) { entry in
                        NetworkRow(entry: entry, process: processes.processes.first(where: { $0.id == entry.id }))
                        if entry.id != top.last?.id { Divider() }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Row

struct NetworkRow: View {
    let entry: NetTopService.Entry
    let process: ProcessInfo?

    var body: some View {
        HStack(spacing: 12) {
            if let process {
                ProcessIconView(executablePath: process.executablePath,
                                bundleId: process.bundleIdentifier,
                                fallbackSymbol: process.icon ?? "globe")
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "globe")
                    .resizable().scaledToFit()
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24).padding(2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(process?.name ?? entry.name)
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text("PID \(entry.id)").font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.blue)
                    Text(ByteFormatter.formatSpeed(Double(entry.bytesInPerSec)))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.caption2).foregroundStyle(.orange)
                    Text(ByteFormatter.formatSpeed(Double(entry.bytesOutPerSec)))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

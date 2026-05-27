//
//  GPUDetailView.swift
//  MacSentinel
//
//  GPU drill-down: usage % and VRAM utilisation per GPU device, polled
//  every 2 seconds via GPUStatsService. No sudo, no entitlement.
//

import SwiftUI
import Charts

@Observable
final class GPUDetailViewModel {
    var stats: [GPUStats] = []
    var history: [(devicePct: Double, vramPct: Double)] = []
    var isPolling = false
    private var timer: Timer?

    @MainActor
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    @MainActor
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func refresh() async {
        let snapshot = await GPUStatsService.snapshot()
        self.stats = snapshot
        let primary = snapshot.first
        history.append((
            devicePct: max(0, primary?.devicePercent ?? 0),
            vramPct:   primary?.vramUsagePercent ?? 0
        ))
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}

struct GPUDetailView: View {
    @State private var vm = GPUDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if vm.stats.isEmpty {
                    ContentUnavailableView(
                        "正在讀取 GPU 資料…",
                        systemImage: "cpu.fill",
                        description: Text("查詢 IOAccelerator + Metal MTLDevice。")
                    )
                } else {
                    ForEach(Array(vm.stats.enumerated()), id: \.offset) { _, gpu in
                        gpuCard(gpu)
                    }
                    historyChart
                }
            }
            .padding(24)
        }
        .navigationTitle("GPU 細節")
        .task { vm.start() }
        .onDisappear { vm.stop() }
    }

    private func gpuCard(_ gpu: GPUStats) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Image(systemName: "cpu.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gpu.deviceName).font(.headline)
                        Text(gpu.isLowPower ? "Integrated GPU" : "Discrete GPU")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(gpu.devicePercent >= 0
                             ? String(format: "%.0f%%", gpu.devicePercent)
                             : "—")
                            .font(.title.weight(.bold).monospacedDigit())
                            .foregroundStyle(usageColor(gpu.devicePercent))
                        Text("使用率").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VRAM").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(ByteFormatter.format(gpu.vramUsedBytes)) / \(ByteFormatter.format(gpu.vramBudgetBytes))")
                            .font(.callout.monospacedDigit())
                    }
                    Spacer()
                    Text(String(format: "%.0f%%", gpu.vramUsagePercent))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(usageColor(gpu.vramUsagePercent))
                }

                ProgressView(value: min(gpu.vramUsagePercent / 100, 1.0))
                    .tint(usageColor(gpu.vramUsagePercent))
            }
            .padding(.vertical, 4)
        }
    }

    private var historyChart: some View {
        GroupBox("最近 \(vm.history.count) 筆採樣（每 2 秒）") {
            Chart {
                ForEach(Array(vm.history.enumerated()), id: \.offset) { idx, sample in
                    LineMark(x: .value("t", idx), y: .value("GPU%", sample.devicePct))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", idx), y: .value("VRAM%", sample.vramPct))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 110)
        }
    }

    private func usageColor(_ p: Double) -> Color {
        switch p {
        case 80...: return .red
        case 50...: return .orange
        case 20...: return .blue
        case 0..<20: return .secondary
        default:     return .secondary
        }
    }
}

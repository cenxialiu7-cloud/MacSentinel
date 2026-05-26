import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(SystemDataCollector.self) var collector: SystemDataCollector
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "shield.checkered")
                    .foregroundStyle(.blue)
                Text("MacSentinel").font(.headline)
                Spacer()
                if !collector.systemAlerts.isEmpty {
                    AlertBadge(count: collector.systemAlerts.count)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    if let snap = collector.latestSnapshot {
                        // CPU
                        PopoverMetricRow(
                            label: "CPU",
                            value: ByteFormatter.formatPercent(snap.cpu.usagePercent),
                            progress: snap.cpu.usagePercent / 100,
                            color: metricColor(snap.cpu.alertLevel)
                        )
                        // RAM
                        PopoverMetricRow(
                            label: "記憶體",
                            value: ByteFormatter.formatPercent(snap.memory.usagePercent),
                            progress: snap.memory.usagePercent / 100,
                            color: metricColor(snap.memory.alertLevel)
                        )
                        // Disk
                        PopoverMetricRow(
                            label: "磁碟",
                            value: ByteFormatter.formatPercent(snap.disk.usagePercent),
                            progress: snap.disk.usagePercent / 100,
                            color: metricColor(snap.disk.alertLevel)
                        )

                        Divider()

                        // Battery
                        HStack {
                            Label("\(snap.battery.percentage)% \(snap.battery.isCharging ? "⚡" : "")",
                                  systemImage: "battery.75")
                            Spacer()
                            Text(snap.battery.isPluggedIn ? "已插電" : "使用電池")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        // Temperature
                        if snap.thermal.cpuTemperatureCelsius > 0 {
                            HStack {
                                Label(ByteFormatter.formatTemp(snap.thermal.cpuTemperatureCelsius),
                                      systemImage: "thermometer.medium")
                                Spacer()
                                if snap.thermal.fanSpeedRPM > 0 {
                                    Text(ByteFormatter.formatRPM(snap.thermal.fanSpeedRPM))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Alerts
                        if !collector.systemAlerts.isEmpty {
                            Divider()
                            ForEach(collector.systemAlerts.prefix(3)) { alert in
                                HStack(spacing: 6) {
                                    Image(systemName: alert.icon)
                                        .foregroundStyle(alert.level == .critical ? .red : .orange)
                                        .font(.caption)
                                    Text(alert.title)
                                        .font(.caption)
                                    Spacer()
                                }
                            }
                        }
                    } else {
                        ProgressView().padding()
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("開啟主介面") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Spacer()

                Button("結束") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private func metricColor(_ level: AlertLevel) -> Color {
        switch level {
        case .normal:   return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

struct PopoverMetricRow: View {
    let label: String
    let value: String
    let progress: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                Text(value).font(.caption.bold()).foregroundStyle(color).monospacedDigit()
            }
            ProgressView(value: progress).tint(color)
        }
    }
}

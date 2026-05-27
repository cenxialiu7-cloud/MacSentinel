import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(SystemDataCollector.self) var collector: SystemDataCollector
    @State private var permissions = PermissionService.shared
    @State private var activeDrillDown: DashboardDrillDown?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Permission Banner ────────────────────────────────────────
                if !permissions.hasFullDiskAccess {
                    PermissionBanner(permissions: permissions)
                }

                // ── Alert Banner ─────────────────────────────────────────────
                if !collector.systemAlerts.isEmpty {
                    AlertBannerView(alerts: collector.systemAlerts)
                }

                // ── Sponsor Banner (auto-hides if disabled / no live offer) ─
                SponsorBanner()

                // ── Metric Cards Grid ─────────────────────────────────────────
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    if let snap = collector.latestSnapshot {
                        MetricCardView(
                            title: "CPU",
                            value: ByteFormatter.formatPercent(snap.cpu.usagePercent),
                            subtitle: "系統 \(ByteFormatter.formatPercent(snap.cpu.systemPercent))  用戶 \(ByteFormatter.formatPercent(snap.cpu.userPercent))",
                            icon: "cpu",
                            color: alertColor(snap.cpu.alertLevel),
                            history: collector.history.map { $0.cpu.usagePercent },
                            maxValue: 100,
                            onTap: { activeDrillDown = .cpu }
                        )
                        MetricCardView(
                            title: "記憶體",
                            value: ByteFormatter.formatPercent(snap.memory.usagePercent),
                            subtitle: "\(ByteFormatter.format(snap.memory.usedBytes)) / \(ByteFormatter.format(snap.memory.totalBytes))",
                            icon: "memorychip",
                            color: alertColor(snap.memory.alertLevel),
                            history: collector.history.map { $0.memory.usagePercent },
                            maxValue: 100,
                            onTap: { activeDrillDown = .memory }
                        )
                        MetricCardView(
                            title: "磁碟",
                            value: ByteFormatter.formatPercent(snap.disk.usagePercent),
                            subtitle: "可用 \(ByteFormatter.format(snap.disk.freeBytes))",
                            icon: "internaldrive",
                            color: alertColor(snap.disk.alertLevel),
                            history: collector.history.map { $0.disk.usagePercent },
                            maxValue: 100,
                            onTap: { activeDrillDown = .disk }
                        )
                        MetricCardView(
                            title: "網路 ↓",
                            value: ByteFormatter.formatSpeed(snap.network.downloadBytesPerSec),
                            subtitle: "↑ \(ByteFormatter.formatSpeed(snap.network.uploadBytesPerSec))  \(snap.network.activeInterface)",
                            icon: "network",
                            color: .blue,
                            history: collector.history.map { $0.network.downloadBytesPerSec },
                            maxValue: nil,
                            onTap: { activeDrillDown = .network }
                        )
                    } else {
                        ProgressView("載入中…").frame(maxWidth: .infinity)
                    }
                }

                // ── Battery + Thermal Row ─────────────────────────────────────
                if let snap = collector.latestSnapshot {
                    HStack(spacing: 16) {
                        if snap.battery.isAvailable {
                            BatteryCardView(battery: snap.battery)
                                .contentShape(Rectangle())
                                .onTapGesture { activeDrillDown = .battery }
                        }
                        ThermalCardView(thermal: snap.thermal)
                            .contentShape(Rectangle())
                            .onTapGesture { activeDrillDown = .thermal }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("系統概覽")
        .task {
            permissions.refresh()
        }
        // ── Drill-down sheets ────────────────────────────────────────────
        .sheet(item: $activeDrillDown) { item in
            DrillDownContainer(item: item)
                .frame(minWidth: 720, minHeight: 540)
        }
    }

    private func alertColor(_ level: AlertLevel) -> Color {
        switch level {
        case .normal:   return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Permission Banner (FDA prompt)

struct PermissionBanner: View {
    let permissions: PermissionService

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("MacSentinel 需要「完整磁碟取用權」才能完整清理")
                    .font(.headline)
                Text("目前能清的：~/Library/Caches、Logs、LaunchAgents、Application Support …\n需 FDA 才能清：~/Library/Containers/*（App 沙箱資料、孤兒殘留）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("開啟系統設定") { permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    Button("重新偵測") {
                        permissions.refresh()
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Metric Card

struct MetricCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    let history: [Double]
    let maxValue: Double?
    /// Optional tap callback. When set, the card becomes clickable and shows
    /// a chevron hint in the header to indicate drill-down availability.
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(title).font(.headline)
                    if onTap != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(value).font(.title2.bold()).foregroundStyle(color).monospacedDigit()
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)

                // Sparkline chart
                if !history.isEmpty {
                    Chart {
                        ForEach(Array(history.enumerated()), id: \.offset) { idx, val in
                            AreaMark(
                                x: .value("t", idx),
                                y: .value("v", val)
                            )
                            .foregroundStyle(color.opacity(0.2))
                            LineMark(
                                x: .value("t", idx),
                                y: .value("v", val)
                            )
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .if(maxValue != nil) { view in
                        view.chartYScale(domain: 0...(maxValue ?? 100))
                    }
                    .frame(height: 48)
                }
            }
        }
        // Tap & hover behaviour (only active when onTap is provided)
        .contentShape(Rectangle())
        .scaleEffect(hovering && onTap != nil ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { isHovering in
            hovering = isHovering
            if onTap != nil {
                isHovering ? NSCursor.pointingHand.push() : NSCursor.pop()
            }
        }
        .onTapGesture { onTap?() }
    }
}

// MARK: - Battery Card

struct BatteryCardView: View {
    let battery: BatterySnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: batteryIcon)
                        .foregroundStyle(chargeColor)
                    Text("電池").font(.headline)
                    Spacer()
                    Text("\(battery.percentage)%")
                        .font(.title2.bold())
                        .foregroundStyle(chargeColor)
                        .monospacedDigit()
                }

                ProgressView(value: Double(battery.percentage), total: 100)
                    .tint(chargeColor)

                HStack {
                    Label(battery.isCharging ? "充電中" : battery.isPluggedIn ? "已連接" : "使用電池",
                          systemImage: battery.isCharging ? "bolt.fill" : (battery.isPluggedIn ? "powerplug.fill" : "battery.50"))
                    Spacer()
                    Text("循環 \(battery.cycleCount) 次")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Battery health — green ≥80%, orange 70-80%, red <70%
                if battery.healthPercent > 0 {
                    Label("電池健康度 \(ByteFormatter.formatPercent(battery.healthPercent * 100))",
                          systemImage: healthIcon)
                        .font(.caption)
                        .foregroundStyle(healthColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var batteryIcon: String {
        switch battery.percentage {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 11...: return "battery.25"
        default:    return "battery.0"
        }
    }

    /// Color of the % readout — green when plugged in or healthy charge level
    private var chargeColor: Color {
        switch battery.lowBatteryAlertLevel {
        case .critical: return .red
        case .warning:  return .orange
        case .normal:   return battery.isPluggedIn ? .green : .blue
        }
    }

    private var healthIcon: String {
        switch battery.healthAlertLevel {
        case .normal:   return "heart.fill"
        case .warning:  return "heart.fill"
        case .critical: return "heart.slash.fill"
        }
    }

    private var healthColor: Color {
        switch battery.healthAlertLevel {
        case .critical: return .red
        case .warning:  return .orange
        case .normal:   return .green
        }
    }
}

// MARK: - Thermal Card

struct ThermalCardView: View {
    let thermal: ThermalSnapshot

    private var anySensorAvailable: Bool {
        thermal.cpuTemperatureCelsius > 0 ||
        thermal.gpuTemperatureCelsius > 0 ||
        thermal.fanSpeedRPM > 0 ||
        thermal.totalPowerWatts > 0
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(tempColor)
                    Text("溫度 / 功耗").font(.headline)
                    Spacer()
                    Text(thermal.cpuTemperatureCelsius > 0
                         ? ByteFormatter.formatTemp(thermal.cpuTemperatureCelsius)
                         : "—")
                        .font(.title2.bold())
                        .foregroundStyle(tempColor)
                }

                if anySensorAvailable {
                    HStack(spacing: 16) {
                        if thermal.gpuTemperatureCelsius > 0 {
                            Label("GPU \(ByteFormatter.formatTemp(thermal.gpuTemperatureCelsius))",
                                  systemImage: "rectangle.3.group.fill")
                        }
                        if thermal.fanSpeedRPM > 0 {
                            Label(ByteFormatter.formatRPM(thermal.fanSpeedRPM),
                                  systemImage: "wind")
                        }
                        if thermal.totalPowerWatts > 0 {
                            Label(String(format: "%.1fW", thermal.totalPowerWatts),
                                  systemImage: "bolt")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("找不到任何熱感測器讀數")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("可能原因：硬體無 IOHID 溫度服務、或被沙箱阻擋。功耗讀數需透過 XPC Helper（規劃中）。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tempColor: Color {
        switch thermal.cpuAlertLevel {
        case .critical: return .red
        case .warning:  return .orange
        case .normal:   return thermal.cpuTemperatureCelsius > 0 ? .primary : .secondary
        }
    }
}

// MARK: - Alert Banner

struct AlertBannerView: View {
    let alerts: [SystemAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(alerts) { alert in
                HStack {
                    Image(systemName: alert.icon)
                        .foregroundStyle(alert.level == .critical ? .red : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title).font(.subheadline.bold())
                        Text(alert.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (alert.level == .critical ? Color.red : Color.orange).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
        }
    }
}

// MARK: - View Extension

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

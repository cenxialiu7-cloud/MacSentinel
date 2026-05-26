//
//  BatteryDetailView.swift
//  MacSentinel
//
//  Drill-down detail for the Battery card. Surfaces coconutBattery-equivalent
//  info: cycle count, design vs current max capacity (health %), connected
//  charger wattage, temperature, voltage, time-remaining estimate.
//

import SwiftUI

struct BatteryDetailView: View {
    @Environment(SystemDataCollector.self) var collector
    @State private var hw: BatteryHardwareInfo?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snap = collector.latestSnapshot, snap.battery.isAvailable {
                    headerSection(snap.battery)
                    healthSection(snap.battery)
                    chargingSection(snap.battery)
                    hardwareSection(snap.battery)
                } else {
                    ContentUnavailableView(
                        "此 Mac 沒有電池",
                        systemImage: "powerplug",
                        description: Text("桌上型 Mac（Mac mini / Mac Studio / iMac）沒有可監測的電池。")
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("電池健康")
        .task {
            loading = true
            hw = await BatteryHealthService.fetch()
            loading = false
        }
    }

    // MARK: - Sections

    private func headerSection(_ b: BatterySnapshot) -> some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(b.percentage) / 100)
                    .stroke(chargeColor(b), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(b.percentage)%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(b.isCharging ? "充電中" : b.isPluggedIn ? "已插電" : "使用電池")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 6) {
                if let hw, let mins = hw.timeRemainingMinutes {
                    Label(formatMinutes(mins), systemImage: "clock")
                        .font(.title3.weight(.medium))
                    Text(b.isCharging ? "預計充滿時間" : "預計剩餘時間")
                        .font(.caption).foregroundStyle(.secondary)
                } else if b.isCharging || b.isPluggedIn == false {
                    Label("計算中…", systemImage: "clock")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if b.isFullyCharged {
                    Label("已充滿", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
    }

    private func healthSection(_ b: BatterySnapshot) -> some View {
        GroupBox("電池健康度") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.0f%%", hw?.preciseHealthPercent ?? b.healthPercent))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(healthColor(hw?.preciseHealthPercent ?? b.healthPercent))
                        .monospacedDigit()
                    Text("最大可用容量")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let hw {
                    HStack {
                        InfoLabel(label: "設計容量", value: "\(hw.designCapacityMAh) mAh")
                        Spacer()
                        InfoLabel(label: "目前容量", value: "\(hw.currentMaxCapacityMAh) mAh")
                        Spacer()
                        InfoLabel(label: "循環次數", value: "\(b.cycleCount) 次",
                                  highlight: b.cycleCount > 1000 ? .orange : nil)
                    }
                }

                Text(healthMessage(b.cycleCount, percent: hw?.preciseHealthPercent ?? b.healthPercent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    private func chargingSection(_ b: BatterySnapshot) -> some View {
        GroupBox(b.isCharging ? "充電中" : "電源狀態") {
            VStack(alignment: .leading, spacing: 10) {
                if let hw, let watts = hw.adapterWatts {
                    HStack {
                        Image(systemName: "powerplug.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("\(watts) W 電源")
                                .font(.callout.weight(.medium))
                            if let desc = hw.adapterDescription {
                                Text(desc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                } else if !b.isPluggedIn {
                    Label("未連接外接電源", systemImage: "battery.50")
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    InfoLabel(label: "電壓", value: String(format: "%.2f V", b.voltageVolts))
                    Spacer()
                    InfoLabel(
                        label: "電流",
                        value: String(format: "%.2f A", abs(b.amperageAmps)),
                        sublabel: b.amperageAmps < 0 ? "放電中" : (b.amperageAmps > 0 ? "充電中" : "靜置")
                    )
                    Spacer()
                    InfoLabel(
                        label: "溫度",
                        value: String(format: "%.1f°C", b.temperatureCelsius),
                        highlight: b.temperatureCelsius >= 40 ? .orange :
                                   b.temperatureCelsius >= 45 ? .red : nil
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func hardwareSection(_ b: BatterySnapshot) -> some View {
        GroupBox("硬體資訊") {
            VStack(alignment: .leading, spacing: 8) {
                if let hw, let name = hw.controllerDeviceName {
                    KVRow(key: "電池控制器", value: name)
                }
                KVRow(key: "目前充電狀態",
                      value: b.isCharging ? "充電中" : (b.isFullyCharged ? "已充滿" : "放電中"))
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在讀取硬體資訊…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func chargeColor(_ b: BatterySnapshot) -> Color {
        if b.isCharging { return .green }
        switch b.percentage {
        case ...10: return .red
        case ...20: return .orange
        default:    return .blue
        }
    }

    private func healthColor(_ percent: Double) -> Color {
        switch percent {
        case 90...: return .green
        case 80...: return .blue
        case 70...: return .orange
        default:    return .red
        }
    }

    private func healthMessage(_ cycles: Int, percent: Double) -> String {
        var parts: [String] = []
        if percent < 80 {
            parts.append("電池容量已低於 80%，可以考慮更換電池。")
        } else if percent < 90 {
            parts.append("電池容量已開始下降，但仍在正常使用範圍。")
        } else {
            parts.append("電池健康狀況良好。")
        }
        if cycles > 1000 {
            parts.append("循環次數超過 1000 次，已超過 Apple 設計的標準壽命。")
        } else if cycles > 500 {
            parts.append("循環次數適中（Apple 設計可承受約 1000 次循環）。")
        }
        return parts.joined(separator: " ")
    }

    private func formatMinutes(_ mins: Int) -> String {
        let h = mins / 60
        let m = mins % 60
        if h > 0 { return "\(h) 小時 \(m) 分" }
        return "\(m) 分"
    }
}

// MARK: - Small reusable views

struct InfoLabel: View {
    let label: String
    let value: String
    var sublabel: String? = nil
    var highlight: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(highlight ?? .primary)
                .monospacedDigit()
            if let sublabel {
                Text(sublabel).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct KVRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

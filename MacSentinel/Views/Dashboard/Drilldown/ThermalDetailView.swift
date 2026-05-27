//
//  ThermalDetailView.swift
//  MacSentinel
//
//  Temperature / power drill-down. Uses the existing ThermalSnapshot from
//  SystemDataCollector plus NSProcessInfo.thermalState for Apple's high-level
//  pressure indicator. Apple Silicon HID sensor enumeration is intentionally
//  out of scope for v1 (private API, fragile).
//

import SwiftUI
import Charts

struct ThermalDetailView: View {
    @Environment(SystemDataCollector.self) var collector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snap = collector.latestSnapshot {
                    headerSection(snap.thermal)
                    pressureSection
                    sensorsSection(snap.thermal)
                    historySection
                    powerHistorySection
                } else {
                    ProgressView("載入中…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .navigationTitle("溫度與功耗")
    }

    // MARK: - Header

    private func headerSection(_ t: ThermalSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading) {
                Text(t.cpuTemperatureCelsius > 0
                     ? String(format: "%.0f°C", t.cpuTemperatureCelsius)
                     : "—")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(tempColor(t.cpuTemperatureCelsius))
                    .monospacedDigit()
                Text("CPU 溫度").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 56)
            VStack(alignment: .leading, spacing: 4) {
                if t.totalPowerWatts > 0 {
                    KVRow(key: "整機功耗", value: String(format: "%.1f W", t.totalPowerWatts))
                }
                if t.fanSpeedRPM > 0 {
                    KVRow(key: "風扇", value: String(format: "%.0f RPM", t.fanSpeedRPM))
                } else {
                    KVRow(key: "風扇", value: "無 / 無資料")
                }
                if t.gpuTemperatureCelsius > 0 {
                    KVRow(key: "GPU 溫度", value: String(format: "%.0f°C", t.gpuTemperatureCelsius))
                }
            }
            .frame(width: 220)
            Spacer()
        }
    }

    // MARK: - macOS Thermal Pressure (system-wide)

    private var pressureSection: some View {
        let state = Foundation.ProcessInfo.processInfo.thermalState
        return GroupBox("系統熱壓力（macOS Thermal State）") {
            HStack(spacing: 14) {
                Circle()
                    .fill(pressureColor(state))
                    .frame(width: 16, height: 16)
                    .shadow(color: pressureColor(state).opacity(0.6), radius: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pressureLabel(state))
                        .font(.headline)
                        .foregroundStyle(pressureColor(state))
                    Text(pressureDescription(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Sensors list

    private func sensorsSection(_ t: ThermalSnapshot) -> some View {
        GroupBox("感測器") {
            VStack(spacing: 0) {
                SensorRow(label: "CPU die",
                          value: t.cpuTemperatureCelsius,
                          unit: "°C",
                          available: t.cpuTemperatureCelsius > 0)
                Divider()
                SensorRow(label: "GPU",
                          value: t.gpuTemperatureCelsius,
                          unit: "°C",
                          available: t.gpuTemperatureCelsius > 0)
                Divider()
                SensorRow(label: "風扇轉速",
                          value: t.fanSpeedRPM,
                          unit: "RPM",
                          available: t.fanSpeedRPM > 0)
                Divider()
                SensorRow(label: "整機功耗",
                          value: t.totalPowerWatts,
                          unit: "W",
                          available: t.totalPowerWatts > 0,
                          decimals: 1)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - History sparklines

    private var historySection: some View {
        GroupBox("溫度趨勢（最近 \(collector.history.count) 筆）") {
            Chart {
                ForEach(Array(collector.history.enumerated()), id: \.offset) { idx, snap in
                    if snap.thermal.cpuTemperatureCelsius > 0 {
                        LineMark(x: .value("t", idx),
                                 y: .value("CPU", snap.thermal.cpuTemperatureCelsius))
                            .foregroundStyle(.red)
                            .interpolationMethod(.catmullRom)
                    }
                    if snap.thermal.gpuTemperatureCelsius > 0 {
                        LineMark(x: .value("t", idx),
                                 y: .value("GPU", snap.thermal.gpuTemperatureCelsius))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 100)
            .padding(.vertical, 4)
        }
    }

    private var powerHistorySection: some View {
        GroupBox("功耗趨勢") {
            Chart {
                ForEach(Array(collector.history.enumerated()), id: \.offset) { idx, snap in
                    if snap.thermal.totalPowerWatts > 0 {
                        AreaMark(x: .value("t", idx),
                                 y: .value("W", snap.thermal.totalPowerWatts))
                            .foregroundStyle(.green.opacity(0.3))
                        LineMark(x: .value("t", idx),
                                 y: .value("W", snap.thermal.totalPowerWatts))
                            .foregroundStyle(.green)
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 80)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func tempColor(_ c: Double) -> Color {
        switch c {
        case 95...: return .red
        case 85...: return .orange
        case 70...: return .yellow
        case 0...:  return .blue
        default:    return .secondary
        }
    }

    private func pressureColor(_ s: Foundation.ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private func pressureLabel(_ s: Foundation.ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "正常 (Nominal)"
        case .fair:     return "輕度 (Fair)"
        case .serious:  return "嚴重 (Serious)"
        case .critical: return "危急 (Critical)"
        @unknown default: return "未知"
        }
    }

    private func pressureDescription(_ s: Foundation.ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "系統散熱良好，所有效能可全速運作。"
        case .fair:     return "系統正在升溫，可能會適度限制部分背景工作。"
        case .serious:  return "系統明顯過熱，已限制 CPU/GPU 頻率以維持穩定。"
        case .critical: return "系統極度過熱，已大幅降頻並可能暫停背景工作。建議減輕負載或讓機器散熱。"
        @unknown default: return ""
        }
    }
}

// MARK: - Sensor row

struct SensorRow: View {
    let label: String
    let value: Double
    let unit: String
    let available: Bool
    var decimals: Int = 0

    var body: some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            if available {
                Text(String(format: "%.\(decimals)f %@", value, unit))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text("無資料")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

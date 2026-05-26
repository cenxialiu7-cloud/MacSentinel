import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(SystemDataCollector.self) var collector: SystemDataCollector

    var body: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            NavigationLink(value: item) {
                Label {
                    HStack {
                        Text(item.rawValue)
                        Spacer()
                        // Alert badge for dashboard
                        if item == .dashboard, !collector.systemAlerts.isEmpty {
                            AlertBadge(count: collector.systemAlerts.count)
                        }
                    }
                } icon: {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MacSentinel")
        .frame(minWidth: 180)

        // Quick stats at bottom of sidebar
        Divider()
        VStack(spacing: 4) {
            if let snap = collector.latestSnapshot {
                MiniStatRow(label: "CPU", value: ByteFormatter.formatPercent(snap.cpu.usagePercent),
                            color: snap.cpu.alertLevel == .normal ? .secondary : .orange)
                MiniStatRow(label: "RAM", value: ByteFormatter.formatPercent(snap.memory.usagePercent),
                            color: snap.memory.alertLevel == .normal ? .secondary : .orange)
                if snap.battery.percentage > 0 {
                    MiniStatRow(label: "電池", value: "\(snap.battery.percentage)%",
                                color: snap.battery.alertLevel == .normal ? .secondary : .orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.caption)
    }
}

struct AlertBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red, in: Capsule())
    }
}

struct MiniStatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color).monospacedDigit()
        }
    }
}

import SwiftUI

struct ProcessListView: View {
    @Environment(ProcessSnapshotService.self) var service: ProcessSnapshotService
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .cpu
    @State private var showGUIOnly = false

    enum SortOrder: String, CaseIterable {
        case cpu = "CPU"
        case memory = "記憶體"
        case name = "名稱"
    }

    var filteredProcesses: [ProcessInfo] {
        var list = service.processes
        if showGUIOnly { list = list.filter(\.isGUIApp) }
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .cpu:    list.sort { $0.cpuPercent > $1.cpuPercent }
        case .memory: list.sort { $0.memoryBytes > $1.memoryBytes }
        case .name:   list.sort { $0.name < $1.name }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Alert bar
            if !service.alerts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(service.alerts) { alert in
                            ProcessAlertChip(alert: alert)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 40)
                .background(Color.orange.opacity(0.1))
                Divider()
            }

            // Filter bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋程序名稱…", text: $searchText)
                    .textFieldStyle(.plain)
                Toggle("僅顯示視窗程式", isOn: $showGUIOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Picker("排序", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            // Table header
            HStack {
                Text("程序名稱").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").font(.caption.bold()).frame(width: 60, alignment: .trailing)
                Text("記憶體").font(.caption.bold()).frame(width: 80, alignment: .trailing)
                Text("狀態").font(.caption.bold()).frame(width: 80, alignment: .center)
                Text("操作").font(.caption.bold()).frame(width: 80, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            Divider()

            List(filteredProcesses) { proc in
                ProcessRow(process: proc, service: service)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
        .navigationTitle("行程管理")
    }
}

struct ProcessRow: View {
    let process: ProcessInfo
    let service: ProcessSnapshotService

    // Trust evaluation result — lazy-loaded the first time the row appears
    @State private var trust: ProcessTrustInfo?
    @State private var showTrustDetails = false

    var body: some View {
        HStack(spacing: 0) {
            // Trust badge (or alert indicator if trust unavailable)
            if let trust = trust {
                Button { showTrustDetails = true } label: {
                    Image(systemName: trust.trustLevel.symbolName)
                        .foregroundStyle(trustColor(trust.trustLevel))
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .frame(width: 22)
                .help("\(trust.trustLevel.shortLabel)：點擊查看簽章詳情")
            } else {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                    .padding(.horizontal, 7)
            }

            // Name
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(process.executablePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // CPU
            Text(ByteFormatter.formatPercent(process.cpuPercent))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(process.cpuPercent > 50 ? .orange : .primary)
                .frame(width: 60, alignment: .trailing)

            // Memory
            Text(ByteFormatter.format(process.memoryBytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(process.memoryBytes > 1_073_741_824 ? .orange : .primary)
                .frame(width: 80, alignment: .trailing)

            // Alert badge
            Group {
                if process.alertLevel >= .warning {
                    Text(process.alertLevel == .critical ? "⚠ 高負載" : "注意")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            process.alertLevel == .critical ? Color.red.opacity(0.15) : Color.orange.opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(process.alertLevel == .critical ? .red : .orange)
                } else {
                    Text("正常")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, alignment: .center)

            // Actions
            HStack(spacing: 4) {
                Button("結束") { service.quit(pid: process.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.blue)
                Button("強制") { service.forceQuit(pid: process.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .frame(width: 80)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            process.alertLevel >= .warning
                ? (process.alertLevel == .critical ? Color.red.opacity(0.05) : Color.orange.opacity(0.05))
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .task {
            // Lazy-load trust info on first appearance — cheap (cached) for repeats
            if trust == nil {
                let info = ProcessTrustService.shared.evaluate(
                    pid: process.id, path: process.executablePath, name: process.name)
                await MainActor.run { trust = info }
            }
        }
        .sheet(isPresented: $showTrustDetails) {
            if let trust = trust {
                ProcessTrustDetailSheet(trust: trust)
            }
        }
    }

    private var indicatorColor: Color {
        switch process.alertLevel {
        case .critical: return .red
        case .warning:  return .orange
        case .normal:   return .clear
        }
    }

    private func trustColor(_ level: ProcessTrustLevel) -> Color {
        switch level {
        case .l5_appleSystem:        return .blue
        case .l4_notarizedThird:     return .green
        case .l3_signedNotNotarized: return .yellow
        case .l2_adhocOrSelfSigned:  return .orange
        case .l1_unsigned:           return .red
        }
    }
}

// MARK: - Process Trust Detail Sheet

struct ProcessTrustDetailSheet: View {
    let trust: ProcessTrustInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: trust.trustLevel.symbolName)
                    .foregroundStyle(trustColor)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(trust.processName).font(.title3.bold())
                    Text("PID \(trust.pid)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(trust.trustLevel.shortLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(trustColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(trustColor)
                Button("關閉") { dismiss() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !trust.reasons.isEmpty {
                        GroupBox("評估摘要") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(trust.reasons, id: \.self) { reason in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("•")
                                        Text(reason).font(.caption)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("簽章資訊") {
                        VStack(alignment: .leading, spacing: 4) {
                            row("Team ID", trust.teamIdentifier ?? "—")
                            row("Identifier", trust.signingIdentifier ?? "—")
                            row("有效簽章", trust.isSignatureValid ? "✓ 是" : "✗ 否")
                            row("Notarized", trust.isNotarized ? "✓ 是" : "✗ 否")
                            row("Hardened Runtime", trust.isHardenedRuntime ? "✓ 是" : "✗ 否")
                            row("Ad-hoc", trust.isAdHoc ? "⚠ 是" : "否")
                            if let cdHash = trust.cdHash {
                                row("CD Hash", String(cdHash.prefix(40)) + "…")
                            }
                        }
                    }

                    if !trust.authorityChain.isEmpty {
                        GroupBox("憑證鏈") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(trust.authorityChain.enumerated()), id: \.offset) { idx, cert in
                                    HStack(spacing: 6) {
                                        Image(systemName: idx == 0 ? "person.fill" : "shield.fill")
                                            .foregroundStyle(.secondary)
                                        Text(cert).font(.caption.monospaced())
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !trust.highRiskEntitlements.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(trust.highRiskEntitlements, id: \.self) { ent in
                                    Text(ent).font(.caption2.monospaced()).foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label("高風險 Entitlements", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }

                    if !trust.allEntitlements.isEmpty {
                        DisclosureGroup("所有 Entitlements (\(trust.allEntitlements.count))") {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(trust.allEntitlements, id: \.self) { ent in
                                    Text(ent).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("路徑") {
                        Text(trust.executablePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }

    private var trustColor: Color {
        switch trust.trustLevel {
        case .l5_appleSystem:        return .blue
        case .l4_notarizedThird:     return .green
        case .l3_signedNotNotarized: return .yellow
        case .l2_adhocOrSelfSigned:  return .orange
        case .l1_unsigned:           return .red
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

struct ProcessAlertChip: View {
    let alert: ProcessAlert

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: alert.type.icon).font(.caption)
            Text("\(alert.processName) — \(alert.type.title)").font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.2), in: Capsule())
        .foregroundStyle(.orange)
    }
}

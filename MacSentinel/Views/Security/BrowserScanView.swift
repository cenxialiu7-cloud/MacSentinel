import SwiftUI

@Observable
final class BrowserScanViewModel {
    var result: BrowserScanResult?
    var isScanning = false
    var status = "點擊「掃描瀏覽器」分析所有已安裝瀏覽器的擴充功能"

    func scan() async {
        isScanning = true
        status = "正在掃描各瀏覽器的擴充清單與權限…"
        let r = await BrowserScanner.shared.scanAll()
        result = r
        status = "找到 \(r.totalCount) 個擴充功能：\(r.blockedCount) 黑名單、\(r.highRiskCount) 高風險、\(r.lowRiskCount) 低風險"
        isScanning = false
    }
}

struct BrowserScanView: View {
    @State private var vm = BrowserScanViewModel()
    @State private var expandedBrowsers: Set<BrowserKind> = Set(BrowserKind.allCases)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.status).font(.caption).foregroundStyle(.secondary)
                    if let result = vm.result, !result.scanErrors.isEmpty {
                        Text("\(result.scanErrors.count) 個瀏覽器無法讀取（可能需要 Full Disk Access）")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if vm.isScanning { ProgressView().controlSize(.small) }
                Button("掃描瀏覽器") { Task { await vm.scan() } }
                    .disabled(vm.isScanning)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if let result = vm.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryCard(result)
                        let grouped = Dictionary(grouping: result.extensions, by: { $0.browser })
                        ForEach(BrowserKind.allCases, id: \.self) { kind in
                            if let exts = grouped[kind], !exts.isEmpty {
                                BrowserGroupCard(
                                    browser: kind,
                                    extensions: exts,
                                    isExpanded: expandedBrowsers.contains(kind),
                                    onToggle: {
                                        if expandedBrowsers.contains(kind) { expandedBrowsers.remove(kind) }
                                        else { expandedBrowsers.insert(kind) }
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    BrowserIntroCard()
                        .padding()
                }
            }
        }
        .navigationTitle("瀏覽器安全")
    }

    private func summaryCard(_ result: BrowserScanResult) -> some View {
        HStack(spacing: 14) {
            ScanChip(count: result.blockedCount, label: "黑名單", color: .red)
            ScanChip(count: result.highRiskCount, label: "高風險", color: .orange)
            ScanChip(count: result.lowRiskCount, label: "低風險", color: .yellow)
            ScanChip(count: result.totalCount - result.blockedCount - result.highRiskCount - result.lowRiskCount,
                     label: "正常", color: .green)
            Spacer()
        }
    }
}

struct ScanChip: View {
    let count: Int
    let label: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct BrowserGroupCard: View {
    let browser: BrowserKind
    let extensions: [BrowserExtension]
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        GroupBox {
            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(extensions.sorted { $0.riskScore > $1.riskScore }) { ext in
                        BrowserExtensionRow(ext: ext)
                    }
                }
            }
        } label: {
            HStack {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Image(systemName: browser.symbolName).foregroundStyle(.indigo)
                Text(browser.rawValue).font(.headline)
                Spacer()
                Text("\(extensions.count) 個擴充")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BrowserExtensionRow: View {
    let ext: BrowserExtension

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RiskBadge(level: ext.riskLevel, score: ext.riskScore)
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.subheadline.bold())
                    Text("v\(ext.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !ext.isEnabled {
                        Text("已停用")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.gray.opacity(0.2), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if !ext.isFromStore {
                        Text("側載")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if !ext.riskFactors.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(ext.riskFactors.prefix(3), id: \.self) { factor in
                            Text("• \(factor)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(ext.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct RiskBadge: View {
    let level: ExtensionRiskLevel
    let score: Int

    var color: Color {
        switch level {
        case .clean:    return .green
        case .lowRisk:  return .yellow
        case .highRisk: return .orange
        case .blocked:  return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(score)").font(.subheadline.bold().monospacedDigit())
            Text(level.label).font(.caption2)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(color)
    }
}

struct BrowserIntroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.indigo)
                Text("瀏覽器擴充功能安全掃描").font(.title3.bold())
            }
            Text("此功能會掃描所有已安裝瀏覽器（Chrome、Brave、Edge、Arc、Vivaldi、Opera、Firefox、Safari）的擴充功能，根據其聲明的權限與來源計算風險評分。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                BulletItem(icon: "checkmark.circle.fill", color: .green,
                           text: "正常（0–39）：標準權限，從官方 Web Store 安裝")
                BulletItem(icon: "exclamationmark.triangle.fill", color: .yellow,
                           text: "低風險（40–69）：權限較廣，需確認用途")
                BulletItem(icon: "exclamationmark.octagon.fill", color: .orange,
                           text: "高風險（70–99）：可攔截網路請求 / 操作所有網站")
                BulletItem(icon: "xmark.octagon.fill", color: .red,
                           text: "黑名單（100）：已被資安團隊標記為惡意")
            }

            Text("⚠️ 移除擴充需到該瀏覽器的設定頁手動操作（避免破壞瀏覽器設定檔）。MacSentinel 只提供識別與評分。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

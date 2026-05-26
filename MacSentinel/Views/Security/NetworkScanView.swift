import SwiftUI

@Observable
final class NetworkScanViewModel {
    var result: NetworkScanResult?
    var isScanning = false
    var status = "點擊「開始掃描」分析網路層是否有劫持跡象"

    func scan() async {
        isScanning = true
        status = "掃描中：/etc/hosts、DNS、PAC、LaunchDaemons…"
        let r = await NetworkScanner.shared.scan()
        result = r
        status = r.anomalies.isEmpty
            ? "未發現網路層異常 ✓"
            : "找到 \(r.anomalies.count) 個值得關注的項目"
        isScanning = false
    }
}

struct NetworkScanView: View {
    @State private var vm = NetworkScanViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(vm.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if vm.isScanning { ProgressView().controlSize(.small) }
                Button("開始掃描") { Task { await vm.scan() } }
                    .disabled(vm.isScanning)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if let result = vm.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Stats
                        HStack(spacing: 14) {
                            ScanChip(count: result.anomalies.filter { $0.severity == .critical }.count,
                                     label: "嚴重", color: .red)
                            ScanChip(count: result.anomalies.filter { $0.severity == .warning }.count,
                                     label: "警告", color: .orange)
                            ScanChip(count: result.anomalies.filter { $0.severity == .info }.count,
                                     label: "資訊", color: .blue)
                            Spacer()
                        }

                        // System state
                        GroupBox("目前網路設定") {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("hosts 檔行數：\(result.hostsLineCount)", systemImage: "doc.text")
                                    .font(.caption)
                                Label("DNS 伺服器：\(result.dnsServers.joined(separator: ", "))",
                                      systemImage: "globe")
                                    .font(.caption)
                                if let pac = result.pacURL {
                                    Label("自動代理 (PAC)：\(pac)", systemImage: "arrow.triangle.swap")
                                        .font(.caption)
                                }
                                Label("已檢查 LaunchDaemons：\(result.totalLaunchDaemonsChecked) 個",
                                      systemImage: "bolt")
                                    .font(.caption)
                            }
                        }

                        if result.anomalies.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                Text("沒有發現異常").font(.headline)
                            }.padding()
                        } else {
                            ForEach(result.anomalies) { anomaly in
                                NetworkAnomalyCard(anomaly: anomaly)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    NetworkIntroCard()
                        .padding()
                }
            }
        }
        .navigationTitle("網路掃描")
    }
}

struct NetworkAnomalyCard: View {
    let anomaly: NetworkAnomaly

    var color: Color {
        switch anomaly.severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    var icon: String {
        switch anomaly.severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(anomaly.detail).font(.callout)
                Text(anomaly.evidence)
                    .font(.caption.monospaced())
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                Label(anomaly.remediation, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(anomaly.title).font(.subheadline.bold())
                Spacer()
                Text(anomaly.severity.label)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
            }
        }
    }
}

struct NetworkIntroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.teal)
                Text("網路層安全掃描").font(.title3.bold())
            }
            Text("這項掃描會檢查你的 Mac 是否有「網路層劫持」跡象。常見手法是把流量導向假網站（網銀詐騙）或植入廣告。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                BulletItem(icon: "1.circle.fill", color: .red,
                           text: "/etc/hosts 是否被改寫，把 google.com / 銀行網站等指向錯誤的 IP")
                BulletItem(icon: "2.circle.fill", color: .orange,
                           text: "DNS 伺服器是否被換成可疑的位置")
                BulletItem(icon: "3.circle.fill", color: .yellow,
                           text: "是否設定了 PAC（自動代理），把流量全部轉走")
                BulletItem(icon: "4.circle.fill", color: .gray,
                           text: "/Library/LaunchDaemons 是否藏有透明代理工具")
            }

            Text("⚠️ 此掃描為唯讀，不會修改任何系統設定。修復需要 sudo 權限，請依結果頁的「建議操作」手動執行。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

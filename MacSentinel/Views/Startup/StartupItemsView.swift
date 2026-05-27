//
//  StartupItemsView.swift
//  MacSentinel
//
//  Sidebar tab for managing LaunchAgents/Daemons with knowledge-base
//  recommendations.
//

import SwiftUI

@Observable
final class StartupItemsViewModel {
    var items: [StartupItem] = []
    var isLoading = false
    var filter: Filter = .all
    var statusMessage: String = "點「掃描」載入啟動項"

    enum Filter: String, CaseIterable, Identifiable {
        case all       = "全部"
        case enabled   = "已啟用"
        case disabled  = "已停用"
        case user      = "使用者"
        case system    = "系統"
        var id: String { rawValue }
    }

    var filtered: [StartupItem] {
        switch filter {
        case .all:      return items
        case .enabled:  return items.filter(\.isEnabled)
        case .disabled: return items.filter { !$0.isEnabled }
        case .user:     return items.filter { !$0.isSystemLevel }
        case .system:   return items.filter(\.isSystemLevel)
        }
    }

    var summary: String {
        let enabled = items.filter(\.isEnabled).count
        let suggestDisable = items.filter { $0.isEnabled && $0.recommendation == .shouldDisable }.count
        return "共 \(items.count) 項，目前 \(enabled) 啟用"
            + (suggestDisable > 0 ? "，建議關閉 \(suggestDisable) 項" : "")
    }

    func scan() async {
        isLoading = true
        statusMessage = "讀取 LaunchAgents/Daemons…"
        items = await StartupItemService.shared.scan()
        statusMessage = summary
        await AuditLog.shared.record(.scanCompleted(
            type: "startup_items",
            itemsFound: items.count,
            totalBytes: 0
        ))
        isLoading = false
    }

    func toggle(_ item: StartupItem) async {
        let want = !item.isEnabled
        let result = await StartupItemService.shared.toggle(item, enable: want)
        if result.success, let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isEnabled = want
        }
        statusMessage = result.message + " — " + summary
    }
}

struct StartupItemsView: View {
    @State private var vm = StartupItemsViewModel()
    @State private var search = ""

    var displayedItems: [StartupItem] {
        guard !search.isEmpty else { return vm.filtered }
        return vm.filtered.filter {
            $0.label.localizedCaseInsensitiveContains(search)
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.program.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(vm.statusMessage).foregroundStyle(.secondary).font(.subheadline)
                    Spacer()
                    if vm.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button("掃描") { Task { await vm.scan() } }
                        .disabled(vm.isLoading)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋 label / 程式…", text: $search)
                        .textFieldStyle(.plain)
                    Picker("", selection: $vm.filter) {
                        ForEach(StartupItemsViewModel.Filter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if vm.items.isEmpty && !vm.isLoading {
                ContentUnavailableView(
                    "啟動項管理",
                    systemImage: "power.circle.fill",
                    description: Text("掃描 ~/Library/LaunchAgents、/Library/LaunchAgents、/Library/LaunchDaemons 三個位置，並用內建 40+ 條規則提供「建議開啟 / 關閉 / 依需求」中文判斷。\n系統層級項目切換時會跳出 macOS 管理員密碼對話框。")
                )
            } else {
                List {
                    ForEach(displayedItems) { item in
                        StartupItemRow(item: item) {
                            Task { await vm.toggle(item) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("啟動項")
    }
}

// MARK: - Row

struct StartupItemRow: View {
    let item: StartupItem
    let onToggle: () -> Void
    @State private var showingReason = false

    var body: some View {
        HStack(spacing: 12) {
            // Recommendation icon (clickable for popover)
            Button { showingReason = true } label: {
                Image(systemName: item.recommendation.systemImage)
                    .font(.title3)
                    .foregroundStyle(recommendationColor)
                    .frame(width: 26)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingReason, arrowEdge: .leading) {
                StartupReasonPopover(item: item)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if item.isSystemLevel {
                        Text("系統")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 4) {
                    Text(item.sourceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·").font(.caption2).foregroundStyle(.secondary)
                    Text((item.program as NSString).lastPathComponent)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(get: { item.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Label("在 Finder 顯示 plist", systemImage: "folder")
            }
        }
    }

    private var recommendationColor: Color {
        switch item.recommendation {
        case .shouldEnable:  return .green
        case .shouldDisable: return .orange
        case .neutral:       return .gray
        }
    }
}

struct StartupReasonPopover: View {
    let item: StartupItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.recommendation.systemImage)
                    .foregroundStyle(color)
                Text(item.recommendation.rawValue)
                    .font(.headline)
                    .foregroundStyle(color)
            }
            Divider()
            Text(item.descriptionText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Label: \(item.label)")
                    .font(.caption.monospacedDigit())
                Text("程式: \(item.program)")
                    .font(.caption.monospacedDigit())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var color: Color {
        switch item.recommendation {
        case .shouldEnable:  return .green
        case .shouldDisable: return .orange
        case .neutral:       return .gray
        }
    }
}

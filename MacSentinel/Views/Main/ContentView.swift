import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard   = "Dashboard"
    case processes   = "行程管理"
    case cleaner     = "快取清理"
    case largeFiles  = "大檔/舊檔"
    case duplicates  = "重複檔案"
    case uninstaller = "App 移除"
    case migration   = "舊資料掃描"
    case browsers    = "瀏覽器安全"
    case network     = "網路掃描"
    case chat        = "AI 助理"
    case settings    = "設定"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard:   return "gauge.with.dots.needle.bottom.50percent"
        case .processes:   return "list.bullet.rectangle"
        case .cleaner:     return "trash.fill"
        case .largeFiles:  return "doc.text.magnifyingglass"
        case .duplicates:  return "doc.on.doc.fill"
        case .uninstaller: return "xmark.app.fill"
        case .migration:   return "arrow.triangle.2.circlepath.circle"
        case .browsers:    return "shield.lefthalf.filled"
        case .network:     return "network.badge.shield.half.filled"
        case .chat:        return "bubble.left.and.bubble.right.fill"
        case .settings:    return "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .dashboard:   return .blue
        case .processes:   return .green
        case .cleaner:     return .orange
        case .largeFiles:  return .yellow
        case .duplicates:  return .mint
        case .uninstaller: return .red
        case .migration:   return .purple
        case .browsers:    return .indigo
        case .network:     return .teal
        case .chat:        return .pink
        case .settings:    return .gray
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            Group {
                switch selection {
                case .dashboard:   DashboardView()
                case .processes:   ProcessListView()
                case .cleaner:     CacheCleanerView()
                case .largeFiles:  LargeFileView()
                case .duplicates:  DuplicateFileView()
                case .uninstaller: AppUninstallerView()
                case .migration:   MigrationScanView()
                case .browsers:    BrowserScanView()
                case .network:     NetworkScanView()
                case .chat:        ChatView()
                case .settings:    SettingsView()
                case .none:        DashboardView()
                }
            }
        }
    }
}

import Foundation

// MARK: - System Snapshot (one data point in time)

struct SystemSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date

    var cpu: CPUSnapshot
    var memory: MemorySnapshot
    var battery: BatterySnapshot
    var disk: DiskSnapshot
    var network: NetworkSnapshot
    var thermal: ThermalSnapshot
}

// MARK: - CPU

struct CPUSnapshot {
    var usagePercent: Double        // 0–100
    var coreUsages: [Double]        // per-core, 0–100
    var systemPercent: Double
    var userPercent: Double
    var idlePercent: Double

    var alertLevel: AlertLevel {
        switch usagePercent {
        case 95...: return .critical
        case 80...: return .warning
        default:    return .normal
        }
    }
}

// MARK: - Memory

struct MemorySnapshot {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
    var pressureLevel: MemoryPressureLevel

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    var alertLevel: AlertLevel {
        switch pressureLevel {
        case .critical: return .critical
        case .warning:  return .warning
        default:
            return usagePercent >= 90 ? .warning : .normal
        }
    }
}

enum MemoryPressureLevel: Int {
    case normal   = 1
    case warning  = 2
    case critical = 4
}

// MARK: - Battery

struct BatterySnapshot {
    var isAvailable: Bool = true    // false on desktop Macs (Mac mini, Mac Studio)
    var percentage: Int             // 0–100
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    var cycleCount: Int
    var healthPercent: Double       // rawMaxCapacity (mAh) / designCapacity (mAh)
    var temperatureCelsius: Double
    var voltageVolts: Double
    var amperageAmps: Double        // negative = discharging

    /// Alert specifically for low charge (only when running on battery)
    var lowBatteryAlertLevel: AlertLevel {
        guard isAvailable, !isPluggedIn else { return .normal }
        if percentage <= 10 { return .critical }
        if percentage <= 20 { return .warning }
        return .normal
    }

    /// Alert specifically for degraded battery health
    var healthAlertLevel: AlertLevel {
        guard isAvailable, healthPercent > 0 else { return .normal }
        if healthPercent < 0.70 { return .critical }   // need replacement
        if healthPercent < 0.80 { return .warning }    // wear noticeable
        return .normal
    }

    /// Combined for legacy callers
    var alertLevel: AlertLevel { max(lowBatteryAlertLevel, healthAlertLevel) }
}

// MARK: - Disk

struct DiskSnapshot {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
    var readBytesPerSec: Double
    var writeBytesPerSec: Double

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    var alertLevel: AlertLevel {
        switch usagePercent {
        case 95...: return .critical
        case 90...: return .warning
        default:    return .normal
        }
    }
}

// MARK: - Network

struct NetworkSnapshot {
    var uploadBytesPerSec: Double
    var downloadBytesPerSec: Double
    var totalUploadBytes: UInt64
    var totalDownloadBytes: UInt64
    var activeInterface: String
}

// MARK: - Thermal

struct ThermalSnapshot {
    var cpuTemperatureCelsius: Double   // -1 if unavailable
    var gpuTemperatureCelsius: Double
    var fanSpeedRPM: Double
    var totalPowerWatts: Double

    var cpuAlertLevel: AlertLevel {
        switch cpuTemperatureCelsius {
        case 95...:  return .critical
        case 85...:  return .warning
        default:     return .normal
        }
    }
}

// MARK: - Alert Level

enum AlertLevel: Int, Comparable {
    case normal   = 0
    case warning  = 1
    case critical = 2

    static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: String {
        switch self {
        case .normal:   return "green"
        case .warning:  return "orange"
        case .critical: return "red"
        }
    }
}

// MARK: - Process Info

struct ProcessInfo: Identifiable, Hashable {
    let id: Int32           // PID
    var name: String
    var executablePath: String
    var cpuPercent: Double
    var memoryBytes: UInt64
    var parentPID: Int32
    var isGUIApp: Bool
    var bundleIdentifier: String?
    var icon: String?       // SF Symbol fallback

    var memoryMB: Double { Double(memoryBytes) / 1_048_576 }
    var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }

    var alertLevel: AlertLevel {
        if cpuPercent >= 90 || memoryBytes >= 4_294_967_296 { return .critical }
        if cpuPercent >= 70 || memoryBytes >= 2_147_483_648 { return .warning }
        return .normal
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ProcessInfo, rhs: ProcessInfo) -> Bool { lhs.id == rhs.id }
}

// MARK: - App Bundle Info

struct AppBundleInfo: Identifiable, Hashable {
    static func == (lhs: AppBundleInfo, rhs: AppBundleInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id = UUID()
    var name: String
    var bundleID: String
    var bundlePath: String
    var version: String
    var bundleSizeBytes: UInt64
    var totalSizeBytes: UInt64       // bundle + residuals
    var architecture: BinaryArchitecture
    var residuals: [ResidualItem]
    var launchAgents: [LaunchAgentInfo]

    var needsRosetta: Bool { architecture == .x86Only }
}

enum BinaryArchitecture: String {
    case arm64       = "arm64"
    case x86Only     = "x86_64"
    case universal2  = "Universal"
    case unknown     = "Unknown"

    var label: String {
        switch self {
        case .arm64:      return "ARM64"
        case .x86Only:    return "Intel"
        case .universal2: return "Universal"
        case .unknown:    return "?"
        }
    }
}

struct ResidualItem: Identifiable {
    let id = UUID()
    var path: String
    var category: ResidualCategory
    var sizeBytes: UInt64
    var isSelected: Bool = true

    var displaySize: String { ByteFormatter.format(sizeBytes) }

    /// Safety level — take the more conservative (riskier) of path vs category classification
    var safetyLevel: SafetyLevel {
        max(SafetyClassifier.classify(path: path),
            SafetyClassifier.classify(category: category))
    }
}

enum ResidualCategory: String, CaseIterable {
    case preferences        = "Preferences"
    case applicationSupport = "Application Support"
    case caches             = "Caches"
    case container          = "Container"
    case groupContainer     = "Group Container"
    case savedState         = "Saved State"
    case logs               = "Logs"
    case launchAgent        = "Launch Agent"
    case launchDaemon       = "Launch Daemon"
    case other              = "Other"

    var icon: String {
        switch self {
        case .preferences:        return "gearshape"
        case .applicationSupport: return "folder"
        case .caches:             return "internaldrive"
        case .container:          return "shippingbox"
        case .groupContainer:     return "shippingbox.fill"
        case .savedState:         return "arrow.clockwise"
        case .logs:               return "doc.text"
        case .launchAgent:        return "bolt"
        case .launchDaemon:       return "bolt.fill"
        case .other:              return "ellipsis.circle"
        }
    }
}

struct LaunchAgentInfo: Identifiable {
    let id = UUID()
    var label: String
    var plistPath: String
    var executablePath: String
    var isLoaded: Bool
    var isOrphaned: Bool    // executable missing
}

// MARK: - Cache Scan Result

struct CacheScanResult {
    var categories: [CacheCategory]
    var totalReclaimableBytes: UInt64 {
        categories.filter(\.isSelected).reduce(0) { $0 + $1.totalBytes }
    }
}

struct CacheCategory: Identifiable {
    let id = UUID()
    var type: CacheCategoryType
    var items: [CacheItem]
    var isSelected: Bool = true

    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var displaySize: String { ByteFormatter.format(totalBytes) }
}

enum CacheCategoryType: String, CaseIterable {
    case browserCache  = "瀏覽器快取"
    case devToolCache  = "開發工具快取"
    case systemCache   = "系統快取"
    case mediaAssets   = "媒體資源"
    case appLogs       = "應用程式 Log"
    case otherJunk     = "其他垃圾"

    var icon: String {
        switch self {
        case .browserCache: return "safari"
        case .devToolCache: return "hammer"
        case .systemCache:  return "apple.logo"
        case .mediaAssets:  return "photo.on.rectangle"
        case .appLogs:      return "doc.plaintext"
        case .otherJunk:    return "trash"
        }
    }
}

struct CacheItem: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var sizeBytes: UInt64
    var isSelected: Bool = true
    /// Filesystem modification date; populated by CacheScanner. Optional
    /// because some paths (especially containers) may not return attributes.
    var modificationDate: Date? = nil

    var displaySize: String { ByteFormatter.format(sizeBytes) }
    var safetyLevel: SafetyLevel { SafetyClassifier.classify(path: path) }

    /// Per-item recommendation (safety level, suggested action, 中文 reasonText).
    /// Computed lazily from path + modDate + size via RecommendationEvaluator.
    var recommendation: ItemRecommendation {
        RecommendationEvaluator.evaluate(
            path: path,
            modificationDate: modificationDate,
            sizeBytes: sizeBytes
        )
    }
}

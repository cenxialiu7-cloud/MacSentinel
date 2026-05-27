import Foundation
import AppKit

// MARK: - Cache Scanner

final class CacheScanner {

    static let shared = CacheScanner()
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private init() {}

    // MARK: - Full Scan

    func scan() async -> CacheScanResult {
        async let browser = scanBrowserCaches()
        async let devTool = scanDevToolCaches()
        async let system  = scanSystemCaches()
        async let media   = scanMediaAssets()
        async let logs    = scanAppLogs()
        async let other   = scanOtherJunk()

        let raw = await [browser, devTool, system, media, logs, other]

        // ── Deduplicate paths across categories ──
        // Earlier categories (browser > devTool > system > media > logs > other) win
        // when the same path appears multiple times. This avoids the user seeing
        // e.g. Chrome 856 MB twice (once as browser, once as system cache).
        var seenPaths = Set<String>()
        var deduped: [CacheCategory] = []
        for var cat in raw {
            cat.items = cat.items.filter { item in
                if seenPaths.contains(item.path) { return false }
                seenPaths.insert(item.path)
                return true
            }
            if !cat.items.isEmpty { deduped.append(cat) }
        }

        return CacheScanResult(categories: deduped)
    }

    // MARK: - Browser Caches

    private func scanBrowserCaches() async -> CacheCategory {
        var paths: [(String, String)] = []

        // ── Chromium-family: split per profile (Default / Profile 1 / …) ──
        // Cache layout: ~/Library/Caches/<Vendor>/<BrowserName>/<Profile>/Cache/Cache_Data
        // For most users this just produces "Chrome — Default", which is
        // identical to the old rollup; power users with multiple profiles see
        // each one independently.
        //
        // (label, cacheRoot, vendorFallback) — `vendorFallback` is the
        // grandparent-vendor cache directory we report if profile discovery
        // fails AND the cacheRoot doesn't exist. NEVER fall back to
        // `~/Library/Caches` itself (that's the whole library!).
        let cachesRoot = "\(home)/Library/Caches"
        let chromium: [(label: String, cacheRoot: String, fallback: String?)] = [
            ("Chrome",  "\(cachesRoot)/Google/Chrome",                 "\(cachesRoot)/Google"),
            ("Brave",   "\(cachesRoot)/BraveSoftware/Brave-Browser",   "\(cachesRoot)/BraveSoftware"),
            ("Edge",    "\(cachesRoot)/com.microsoft.edgemac",         nil),
            ("Arc",     "\(cachesRoot)/company.thebrowser.Browser",    nil),
            ("Vivaldi", "\(cachesRoot)/com.vivaldi.Vivaldi",           nil),
        ]
        for (label, root, fallback) in chromium {
            let profiles = chromiumProfiles(under: root)
            if !profiles.isEmpty {
                for p in profiles {
                    paths.append(("\(label) — \(p.name)", p.path))
                }
            } else if fm.fileExists(atPath: root) {
                // No profiles but cacheRoot itself has data — report it as-is.
                paths.append((label, root))
            } else if let fb = fallback,
                      fb != cachesRoot,
                      fm.fileExists(atPath: fb) {
                // Last resort: the vendor's umbrella cache dir, but ONLY if
                // it exists and is strictly below ~/Library/Caches.
                paths.append((label, fb))
            }
            // Otherwise: silently skip. We refuse to ever report
            // ~/Library/Caches itself as a single cleanable item.
        }

        // ── Single-profile / opaque caches ──
        paths.append(("Safari",  "\(home)/Library/Caches/com.apple.Safari"))
        paths.append(("Firefox", "\(home)/Library/Caches/Firefox"))

        return await buildCategory(type: .browserCache, paths: paths)
    }

    /// Enumerate `Default`, `Profile 1`, etc. directly under a Chromium
    /// cache root. Returns one entry per profile; the path points at the
    /// per-profile cache directory so cleaning one profile doesn't touch
    /// the others.
    private func chromiumProfiles(under cacheRoot: String) -> [(name: String, path: String)] {
        guard fm.fileExists(atPath: cacheRoot),
              let entries = try? fm.contentsOfDirectory(atPath: cacheRoot)
        else { return [] }
        var out: [(String, String)] = []
        for name in entries where name == "Default" || name.hasPrefix("Profile ") {
            out.append((name, "\(cacheRoot)/\(name)"))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - Dev Tool Caches

    private func scanDevToolCaches() async -> CacheCategory {
        var paths: [(String, String)] = [
            ("Xcode DerivedData",    "\(home)/Library/Developer/Xcode/DerivedData"),
            ("Playwright",           "\(home)/Library/Caches/ms-playwright-go"),
            ("pip",                  "\(home)/Library/Caches/pip"),
            ("npm",                  "\(home)/.npm/_cacache"),
            ("yarn",                 "\(home)/.yarn/cache"),
            ("Gradle",               "\(home)/.gradle/caches"),
            ("Android Studio",       "\(home)/Library/Caches/com.google.android.studio"),
            ("CocoaPods",            "\(home)/Library/Caches/org.cocoapods"),
            ("Swift PM",             "\(home)/Library/Caches/org.swift.swiftpm"),
            ("Homebrew",             "\(home)/Library/Caches/Homebrew"),
        ]

        // iOS DeviceSupport: only old versions (keep latest)
        let deviceSupportDir = "\(home)/Library/Developer/Xcode/iOS DeviceSupport"
        if let versions = try? fm.contentsOfDirectory(atPath: deviceSupportDir) {
            let sorted = versions.sorted()
            // Keep the last (newest) version, offer to delete the rest
            let old = sorted.dropLast()
            for v in old {
                paths.append(("iOS DeviceSupport \(v)", "\(deviceSupportDir)/\(v)"))
            }
        }

        // Simulator Devices: only empty ones (< 50 MB)
        let simDir = "\(home)/Library/Developer/CoreSimulator/Devices"
        if let devices = try? fm.contentsOfDirectory(atPath: simDir) {
            for device in devices {
                let devicePath = "\(simDir)/\(device)"
                let size = await SafeDeleteService.shared.sizeOfItems(
                    [URL(fileURLWithPath: devicePath)]
                )
                if size < 50_000_000 {  // < 50 MB = essentially empty
                    paths.append(("Simulator (empty) \(device.prefix(8))",
                                  devicePath))
                }
            }
        }

        return await buildCategory(type: .devToolCache, paths: paths)
    }

    // MARK: - System Caches

    private func scanSystemCaches() async -> CacheCategory {
        var paths: [(String, String)] = [
            ("GeoServices",      "\(home)/Library/Caches/GeoServices"),
            ("helpd",            "\(home)/Library/Caches/com.apple.helpd"),
            ("mediaanalysisd",   "\(home)/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches"),
            ("wallpaper.agent",  "\(home)/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches"),
            ("CloudTelemetry",   "\(home)/Library/Caches/com.apple.CloudTelemetry"),
        ]

        // Top user caches (sorted by size, > 10 MB)
        let cachesDir = "\(home)/Library/Caches"
        if let entries = try? fm.contentsOfDirectory(atPath: cachesDir) {
            for entry in entries {
                let fullPath = "\(cachesDir)/\(entry)"
                // Skip already-added ones
                guard !paths.contains(where: { $0.1 == fullPath }) else { continue }
                let url = URL(fileURLWithPath: fullPath)
                let size = await SafeDeleteService.shared.sizeOfItems([url])
                if size > 10_000_000 {  // > 10 MB
                    paths.append((entry, fullPath))
                }
            }
        }

        return await buildCategory(type: .systemCache, paths: paths)
    }

    // MARK: - Media Assets

    private func scanMediaAssets() async -> CacheCategory {
        let paths: [(String, String)] = [
            ("Apple 動態桌布影片", "\(home)/Library/Application Support/com.apple.wallpaper/aerials/videos"),
            ("Apple 地圖快取",    "\(home)/Library/Caches/GeoServices"),
        ]
        return await buildCategory(type: .mediaAssets, paths: paths)
    }

    // MARK: - App Logs

    private func scanAppLogs() async -> CacheCategory {
        let paths: [(String, String)] = [
            ("用戶 Logs",           "\(home)/Library/Logs"),
            ("Xcode Server Logs",   "\(home)/Library/Application Support/xcs/logs"),
            ("診斷報告",            "\(home)/Library/Logs/DiagnosticReports"),
        ]
        return await buildCategory(type: .appLogs, paths: paths)
    }

    // MARK: - Other Junk

    private func scanOtherJunk() async -> CacheCategory {
        // NOTE: orphan-container detection has moved to MigrationScanner (where it
        // uses the new prefix-matching + Apple-system-service allowlist for accuracy).
        // CacheScanner only reports true junk that's not better classified elsewhere.
        let paths: [(String, String)] = [
            ("WebEx 舊版暫存", "\(home)/Library/Application Support/WebEx Folder"),
            ("pyinstaller",   "\(home)/Library/Application Support/pyinstaller"),
        ]
        return await buildCategory(type: .otherJunk, paths: paths)
    }

    // MARK: - Helper

    private func buildCategory(type: CacheCategoryType,
                                paths: [(String, String)]) async -> CacheCategory {
        var items: [CacheItem] = []
        for (name, path) in paths {
            // ── Skip .DS_Store and other dotfiles at the top of the path ──
            let lastComponent = (path as NSString).lastPathComponent
            if lastComponent == ".DS_Store" || lastComponent.hasPrefix(".DS_Store") { continue }

            // ── User whitelist: skip paths the user opted out of ──
            if UserWhitelist.shared.isWhitelisted(path) { continue }

            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { continue }
            let size = await SafeDeleteService.shared.sizeOfItems([url])
            // ── Noise threshold: < 1 KB is just metadata placeholder ──
            guard size >= 1024 else { continue }
            // Capture mtime cheaply (single `stat` call) so RecommendationEvaluator
            // can apply its "未存取 N 天" rules.
            let modDate = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            items.append(CacheItem(
                name: name, path: path, sizeBytes: size, modificationDate: modDate
            ))
        }
        items.sort { $0.sizeBytes > $1.sizeBytes }
        return CacheCategory(type: type, items: items)
    }
}

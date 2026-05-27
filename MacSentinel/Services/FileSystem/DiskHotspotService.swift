//
//  DiskHotspotService.swift
//  MacSentinel
//
//  Quick disk overview: sums the size of well-known "fat" directories that
//  are usually the biggest space hogs, plus uses Spotlight (`mdfind`) to
//  surface individual files larger than a threshold without walking the
//  filesystem ourselves.
//

import Foundation

/// One named directory hotspot (Xcode DerivedData, Docker, Trash, etc.).
struct DiskHotspot: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let path: String
    let sizeBytes: UInt64
    let recommendation: String
}

/// A single big-file hit from Spotlight.
struct LargeFileHit: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let sizeBytes: UInt64

    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

enum DiskHotspotService {

    /// Compute hotspots + large files concurrently. Returns when both finish.
    static func snapshot(minLargeFileSizeMB: Int = 1024) async
        -> (hotspots: [DiskHotspot], largeFiles: [LargeFileHit])
    {
        async let h = hotspots()
        async let l = mdfindLargeFiles(minSizeBytes: UInt64(minLargeFileSizeMB) * 1024 * 1024)
        return await (h, l)
    }

    // MARK: - Hotspots

    private struct HotspotSpec {
        let label: String
        let path: String
        let recommendation: String
    }

    private static func hotspots() async -> [DiskHotspot] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let specs: [HotspotSpec] = [
            .init(label: "Xcode DerivedData",
                  path: "\(home)/Library/Developer/Xcode/DerivedData",
                  recommendation: "Xcode 編譯快取，清除後下次 build 會自動重建。動輒數 GB。"),
            .init(label: "iOS Simulator",
                  path: "\(home)/Library/Developer/CoreSimulator",
                  recommendation: "iOS 模擬器映像檔。長期不寫 iOS App 可全部刪。"),
            .init(label: "Docker",
                  path: "\(home)/Library/Containers/com.docker.docker",
                  recommendation: "Docker Desktop 容器資料。Docker 內 `docker system prune -a` 可釋出更多。"),
            .init(label: "iOS Backups",
                  path: "\(home)/Library/Application Support/MobileSync/Backup",
                  recommendation: "iTunes/Finder 同步的 iPhone/iPad 備份。可在 Finder 內單個刪除。"),
            .init(label: "Trash",
                  path: "\(home)/.Trash",
                  recommendation: "垃圾桶。清空後才會真正釋放磁碟空間。"),
            .init(label: "Caches (使用者)",
                  path: "\(home)/Library/Caches",
                  recommendation: "所有應用程式快取總合。MacSentinel「快取清理」分頁可細部勾選。"),
            .init(label: "Logs (使用者)",
                  path: "\(home)/Library/Logs",
                  recommendation: "應用程式日誌。可全清。"),
            .init(label: "npm cache",
                  path: "\(home)/.npm/_cacache",
                  recommendation: "Node.js npm 套件快取。`npm cache clean --force` 也可。"),
            .init(label: "Gradle",
                  path: "\(home)/.gradle/caches",
                  recommendation: "Android/JVM 編譯快取。下次 build 會重新下載。"),
            .init(label: "Homebrew",
                  path: "\(home)/Library/Caches/Homebrew",
                  recommendation: "Homebrew 下載檔。`brew cleanup -s` 可釋出。")
        ]

        return await withTaskGroup(of: DiskHotspot?.self) { group in
            for spec in specs {
                group.addTask {
                    let url = URL(fileURLWithPath: spec.path)
                    guard FileManager.default.fileExists(atPath: spec.path) else { return nil }
                    let size = await SafeDeleteService.shared.sizeOfItems([url])
                    guard size > 1024 else { return nil }
                    return DiskHotspot(
                        label: spec.label,
                        path: spec.path,
                        sizeBytes: size,
                        recommendation: spec.recommendation
                    )
                }
            }
            var results: [DiskHotspot] = []
            for await item in group { if let item { results.append(item) } }
            return results.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    // MARK: - mdfind large files

    private static func mdfindLargeFiles(minSizeBytes: UInt64) async -> [LargeFileHit] {
        await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            // -onlyin ~ : only inside user home (faster + more relevant)
            task.arguments = [
                "-onlyin", FileManager.default.homeDirectoryForCurrentUser.path,
                "kMDItemFSSize > \(minSizeBytes)"
            ]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do { try task.run() } catch { return [] }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }

            let paths = text.split(separator: "\n").map(String.init)
            var hits: [LargeFileHit] = []
            for path in paths {
                // Skip whitelisted paths
                if UserWhitelist.shared.isWhitelisted(path) { continue }
                // Skip files inside .app bundles (those are just framework binaries)
                if path.contains(".app/") { continue }
                guard let size = (try? FileManager.default
                    .attributesOfItem(atPath: path)[.size]) as? NSNumber else { continue }
                hits.append(LargeFileHit(path: path, sizeBytes: size.uint64Value))
            }
            return hits.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(50).map { $0 }
        }.value
    }
}

import Foundation
import AppKit

// MARK: - App Residual Scanner (22 path patterns)

final class AppResidualScanner {

    static let shared = AppResidualScanner()
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private init() {}

    // MARK: - Scan All Apps in /Applications

    func scanInstalledApps() async -> [AppBundleInfo] {
        let appDir = "/Applications"
        guard let entries = try? fm.contentsOfDirectory(atPath: appDir) else { return [] }
        let appPaths = entries.filter { $0.hasSuffix(".app") }
            .map { "\(appDir)/\($0)" }

        return await withTaskGroup(of: AppBundleInfo?.self) { group in
            for path in appPaths {
                group.addTask { await self.scanApp(at: path) }
            }
            var results: [AppBundleInfo] = []
            for await info in group {
                if let info { results.append(info) }
            }
            return results.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
        }
    }

    // MARK: - Scan Single App

    func scanApp(at bundlePath: String) async -> AppBundleInfo? {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard let bundle = Bundle(url: bundleURL),
              let bundleID = bundle.bundleIdentifier else { return nil }

        let appName  = bundleURL.deletingPathExtension().lastPathComponent
        let version  = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let arch     = detectArchitecture(bundlePath: bundlePath, bundle: bundle)

        let bundleSize = await SafeDeleteService.shared.sizeOfItems([bundleURL])

        let residuals     = await findResiduals(bundleID: bundleID, appName: appName)
        let launchAgents  = findLaunchAgents(bundleID: bundleID, appName: appName)

        let residualSize = residuals.reduce(0) { $0 + $1.sizeBytes }
        let agentSize    = UInt64(0)  // agents are tiny plists

        return AppBundleInfo(
            name: appName,
            bundleID: bundleID,
            bundlePath: bundlePath,
            version: version,
            bundleSizeBytes: bundleSize,
            totalSizeBytes: bundleSize + residualSize + agentSize,
            architecture: arch,
            residuals: residuals,
            launchAgents: launchAgents
        )
    }

    // MARK: - Residual Path Patterns (22 patterns)

    private func findResiduals(bundleID: String, appName: String) async -> [ResidualItem] {
        let patterns: [(String, ResidualCategory)] = [
            // 1. Preferences
            ("\(home)/Library/Preferences/\(bundleID).plist",                       .preferences),
            ("\(home)/Library/Preferences/\(bundleID).LSSharedFileList.plist",      .preferences),

            // 2. Application Support
            ("\(home)/Library/Application Support/\(appName)",                      .applicationSupport),
            ("\(home)/Library/Application Support/\(bundleID)",                     .applicationSupport),

            // 3. Caches
            ("\(home)/Library/Caches/\(bundleID)",                                  .caches),
            ("\(home)/Library/Caches/\(appName)",                                   .caches),

            // 4. Container (sandbox)
            ("\(home)/Library/Containers/\(bundleID)",                              .container),

            // 5. Group Containers
            ("\(home)/Library/Group Containers/\(bundleID)",                        .groupContainer),

            // 6. Saved Application State
            ("\(home)/Library/Saved Application State/\(bundleID).savedState",      .savedState),

            // 7. WebKit storage
            ("\(home)/Library/WebKit/\(bundleID)",                                  .other),

            // 8. Cookies
            ("\(home)/Library/Cookies/\(bundleID).binarycookies",                   .other),

            // 9. Logs
            ("\(home)/Library/Logs/\(appName)",                                     .logs),
            ("\(home)/Library/Logs/\(bundleID)",                                    .logs),

            // 10. Crash Reporter
            ("\(home)/Library/Application Support/CrashReporter/\(appName)_*.crash", .logs),

            // 11. Internet Plug-Ins
            ("\(home)/Library/Internet Plug-Ins/\(appName).plugin",                 .other),
            ("\(home)/Library/Internet Plug-Ins/\(appName).webplugin",              .other),

            // 12. Mail Bundles
            ("\(home)/Library/Mail/Bundles/\(appName).mailbundle",                  .other),

            // 13. Application Scripts
            ("\(home)/Library/Application Scripts/\(bundleID)",                     .other),

            // 14. HTTPStorages / WebKit 2
            ("\(home)/Library/HTTPStorages/\(bundleID)",                            .caches),
            ("\(home)/Library/HTTPStorages/\(bundleID).binarycookies",              .caches),

            // 15. Package Receipts
            ("/Library/Receipts/\(bundleID).pkg",                                   .other),
        ]

        // Group container wildcard (prefix match)
        var items: [ResidualItem] = []
        let gcDir = "\(home)/Library/Group Containers"
        if let gcs = try? fm.contentsOfDirectory(atPath: gcDir) {
            for gc in gcs where gc.contains(bundleID) || gc.contains(appName) {
                let path = "\(gcDir)/\(gc)"
                let size = await sizeOf(path)
                if size > 0 {
                    items.append(ResidualItem(path: path, category: .groupContainer, sizeBytes: size))
                }
            }
        }

        // Evaluate each pattern
        for (path, category) in patterns {
            // Handle non-wildcard paths
            if !path.contains("*") {
                if fm.fileExists(atPath: path) {
                    let size = await sizeOf(path)
                    items.append(ResidualItem(path: path, category: category, sizeBytes: size))
                }
            } else {
                // Wildcard: expand with mdfind or glob
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                let pattern = URL(fileURLWithPath: path).lastPathComponent
                    .replacingOccurrences(of: "*", with: "")
                if let entries = try? fm.contentsOfDirectory(atPath: dir) {
                    for entry in entries where entry.hasPrefix(pattern) {
                        let fullPath = "\(dir)/\(entry)"
                        let size = await sizeOf(fullPath)
                        items.append(ResidualItem(path: fullPath, category: category, sizeBytes: size))
                    }
                }
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Launch Agents

    private func findLaunchAgents(bundleID: String, appName: String) -> [LaunchAgentInfo] {
        let searchPaths = [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
        ]

        var agents: [LaunchAgentInfo] = []
        for dir in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                guard entry.hasSuffix(".plist"),
                      (entry.contains(bundleID) || entry.lowercased().contains(appName.lowercased()))
                else { continue }

                let plistPath = "\(dir)/\(entry)"
                if let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] {
                    let label = plist["Label"] as? String ?? entry
                    let args  = plist["ProgramArguments"] as? [String] ?? []
                    let exec  = args.first ?? (plist["Program"] as? String ?? "")
                    let isLoaded = checkAgentLoaded(label: label)
                    let isOrphaned = !exec.isEmpty && !fm.fileExists(atPath: exec)

                    agents.append(LaunchAgentInfo(
                        label: label,
                        plistPath: plistPath,
                        executablePath: exec,
                        isLoaded: isLoaded,
                        isOrphaned: isOrphaned
                    ))
                }
            }
        }
        return agents
    }

    // MARK: - Architecture Detection

    private func detectArchitecture(bundlePath: String, bundle: Bundle) -> BinaryArchitecture {
        guard let execName = bundle.infoDictionary?["CFBundleExecutable"] as? String else {
            return .unknown
        }
        let execPath = "\(bundlePath)/Contents/MacOS/\(execName)"
        guard fm.fileExists(atPath: execPath) else { return .unknown }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-info", execPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        let hasArm   = output.contains("arm64")
        let hasIntel = output.contains("x86_64")

        switch (hasArm, hasIntel) {
        case (true, true):  return .universal2
        case (true, false): return .arm64
        case (false, true): return .x86Only
        default:            return .unknown
        }
    }

    // MARK: - Helpers

    private func checkAgentLoaded(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func sizeOf(_ path: String) async -> UInt64 {
        await SafeDeleteService.shared.sizeOfItems([URL(fileURLWithPath: path)])
    }
}

import Foundation
import AppKit

// MARK: - Migration Scan Results

struct MigrationScanResult {
    var rosettaApps: [AppBundleInfo]                = []
    var orphanedLaunchAgents: [OrphanedLaunchAgent] = []
    var orphanedContainers: [OrphanedContainer]     = []
    var legacyKexts: [LegacyKext]                   = []

    var totalOrphanBytes: UInt64 {
        orphanedContainers.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct OrphanedLaunchAgent: Identifiable {
    let id = UUID()
    var label: String
    var plistPath: String
    var missingExecutable: String
    var isUserAgent: Bool      // ~/Library vs /Library
}

struct OrphanedContainer: Identifiable {
    let id = UUID()
    var bundleID: String
    var containerPath: String
    var sizeBytes: UInt64
    var isGroupContainer: Bool

    var displaySize: String { ByteFormatter.format(sizeBytes) }
}

struct LegacyKext: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var bundleID: String
    var isLoaded: Bool
    var isAppleSigned: Bool
}

// MARK: - Migration Scanner

final class MigrationScanner {

    static let shared = MigrationScanner()
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private init() {}

    func fullScan() async -> MigrationScanResult {
        async let rosetta   = scanRosettaApps()
        async let agents    = scanOrphanedLaunchAgents()
        async let containers = scanOrphanedContainers()
        async let kexts     = scanLegacyKexts()

        return await MigrationScanResult(
            rosettaApps: rosetta,
            orphanedLaunchAgents: agents,
            orphanedContainers: containers,
            legacyKexts: kexts
        )
    }

    // MARK: - 1. Rosetta / Intel-Only Apps

    private func scanRosettaApps() async -> [AppBundleInfo] {
        let scanner = AppResidualScanner.shared
        let allApps = await scanner.scanInstalledApps()
        return allApps.filter { $0.architecture == .x86Only }
    }

    // MARK: - 2. Orphaned Launch Agents

    private func scanOrphanedLaunchAgents() async -> [OrphanedLaunchAgent] {
        let searchPaths: [(String, Bool)] = [
            ("\(home)/Library/LaunchAgents", true),
            ("/Library/LaunchAgents",        false),
            ("/Library/LaunchDaemons",       false),
        ]

        var orphans: [OrphanedLaunchAgent] = []

        for (dir, isUser) in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".plist") {
                let path = "\(dir)/\(entry)"
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }

                let label = plist["Label"] as? String ?? entry
                let args  = plist["ProgramArguments"] as? [String] ?? []
                let exec  = args.first ?? (plist["Program"] as? String ?? "")

                guard !exec.isEmpty else { continue }

                if !fm.fileExists(atPath: exec) {
                    orphans.append(OrphanedLaunchAgent(
                        label: label,
                        plistPath: path,
                        missingExecutable: exec,
                        isUserAgent: isUser
                    ))
                }
            }
        }
        return orphans
    }

    // MARK: - 3. Orphaned Containers

    private func scanOrphanedContainers() async -> [OrphanedContainer] {
        let containerDirs: [(String, Bool)] = [
            ("\(home)/Library/Containers",       false),
            ("\(home)/Library/Group Containers", true),
        ]

        // ── Pre-compute: every installed app's bundle ID for prefix matching ──
        let installedBundleIDs = await collectInstalledBundleIDs()

        var orphans: [OrphanedContainer] = []
        let ws = NSWorkspace.shared

        for (dir, isGroup) in containerDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                // ── Skip macOS system noise files ──
                if entry == ".DS_Store" || entry.hasPrefix(".") { continue }

                let containerPath = "\(dir)/\(entry)"
                let bundleID = entry.hasPrefix("group.") ? String(entry.dropFirst(6)) : entry

                // ── Filter 1: Apple system services (highest confidence) ──
                if AppleSystemServices.isAppleSystemService(bundleID) ||
                   AppleSystemServices.isAppleSystemService(entry) {
                    continue
                }

                // ── Filter 2: Direct bundle-ID lookup ──
                let hasApp = ws.urlForApplication(withBundleIdentifier: bundleID) != nil
                    || ws.urlForApplication(withBundleIdentifier: "group.\(bundleID)") != nil
                if hasApp { continue }

                // ── Filter 3: Prefix matching — is this a child helper of an installed app? ──
                // e.g. com.lemon.lvpro.tray is a sub-helper of com.lemon.lvpro (installed)
                //      com.chenhaowu.mac.utility.zip.MZPreviewExtension is from Oka Unarchiver
                let isChildHelper = installedBundleIDs.contains { installed in
                    bundleID.hasPrefix(installed + ".") && bundleID != installed
                }
                if isChildHelper { continue }

                // ── Filter 4: Apple Group Container team-ID prefixes ──
                let groupBundleID = entry  // For group containers, the full ID
                if AppleSystemServices.isAppleSystemService(groupBundleID) { continue }

                let size = await SafeDeleteService.shared.sizeOfItems(
                    [URL(fileURLWithPath: containerPath)]
                )
                // ── Filter 5: Skip < 1 KB noise (placeholder containers) ──
                guard size > 1024 else { continue }

                orphans.append(OrphanedContainer(
                    bundleID: entry,
                    containerPath: containerPath,
                    sizeBytes: size,
                    isGroupContainer: isGroup
                ))
            }
        }
        return orphans.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Build a set of every bundle ID for an installed app — used for prefix matching
    /// so that `com.lemon.lvpro.tray` is recognized as a child of installed `com.lemon.lvpro`.
    private func collectInstalledBundleIDs() async -> Set<String> {
        var ids = Set<String>()

        // Source 1: /Applications/*.app — fast metadata read, no full residual scan
        let appDirs = ["/Applications", "\(home)/Applications"]
        for appDir in appDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: appDir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let plistPath = "\(appDir)/\(entry)/Contents/Info.plist"
                if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
                   let bundleID = dict["CFBundleIdentifier"] as? String {
                    ids.insert(bundleID)
                }
            }
        }

        // Source 2: System apps (already covered by NSWorkspace lookups elsewhere,
        // but we also add running apps for completeness)
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id) }
        }

        return ids
    }

    // MARK: - 4. Legacy Kernel Extensions

    private func scanLegacyKexts() async -> [LegacyKext] {
        let kextDir = "/Library/Extensions"
        guard let entries = try? fm.contentsOfDirectory(atPath: kextDir) else { return [] }

        var kexts: [LegacyKext] = []
        for entry in entries where entry.hasSuffix(".kext") {
            let path = "\(kextDir)/\(entry)"
            let infoPlist = "\(path)/Contents/Info.plist"
            guard let plist = NSDictionary(contentsOfFile: infoPlist) as? [String: Any] else { continue }

            let bundleID = plist["CFBundleIdentifier"] as? String ?? entry
            // Skip Apple-signed kexts
            guard !bundleID.hasPrefix("com.apple.") else { continue }

            let isLoaded  = checkKextLoaded(bundleID: bundleID)
            let isSigned  = checkKextSigned(path: path)

            kexts.append(LegacyKext(
                name: entry.replacingOccurrences(of: ".kext", with: ""),
                path: path,
                bundleID: bundleID,
                isLoaded: isLoaded,
                isAppleSigned: isSigned
            ))
        }
        return kexts
    }

    // MARK: - Helpers

    private func checkKextLoaded(bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/kextstat")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        return output.contains(bundleID)
    }

    private func checkKextSigned(path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        return output.contains("Apple") || output.contains("Developer ID")
    }
}

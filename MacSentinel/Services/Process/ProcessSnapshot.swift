import Foundation
import AppKit

// MARK: - Process Snapshot Service

@Observable
final class ProcessSnapshotService {

    static let shared = ProcessSnapshotService()

    private(set) var processes: [ProcessInfo] = []
    private(set) var alerts: [ProcessAlert] = []

    private var timer: Timer?
    private var cpuHistory: [Int32: [Double]] = [:]           // PID -> last 5 CPU samples
    private var memHistory: [Int32: [UInt64]] = [:]           // PID -> last 5 mem samples
    private var prevCPUNs:  [Int32: (user: UInt64, sys: UInt64)] = [:]  // PID -> previous ns totals
    private var prevSampleTime: Date = Date()

    private let sampleInterval: TimeInterval = 3.0
    private let cpuWarningThreshold: Double  = 80.0
    private let memWarningBytes: UInt64      = 2_147_483_648  // 2 GB
    private let leakSamples                  = 5

    private init() {}

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        let prev = prevCPUNs
        let prevTime = prevSampleTime
        let now = Date()

        let snapshot = await Task.detached(priority: .utility) { [prev, prevTime, now] in
            self.collectProcesses(prevCPUNs: prev, prevTime: prevTime, now: now)
        }.value

        prevCPUNs = snapshot.newCPUNs
        prevSampleTime = now
        processes = snapshot.infos
        updateAlerts()
    }

    /// One-shot snapshot for callers that don't want timer-driven sampling
    /// (e.g. the MCP CLI). Takes two readings with a 1.5s gap so per-process
    /// CPU % is meaningful, then returns the list and stops.
    func snapshotOnce() async -> [ProcessInfo] {
        await refresh()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
        return await MainActor.run { processes }
    }

    private struct CollectResult {
        var infos: [ProcessInfo]
        var newCPUNs: [Int32: (user: UInt64, sys: UInt64)]
    }

    private func collectProcesses(
        prevCPUNs: [Int32: (user: UInt64, sys: UInt64)],
        prevTime: Date,
        now: Date
    ) -> CollectResult {
        let elapsed = max(0.1, now.timeIntervalSince(prevTime))  // seconds

        // 1. Get all PIDs
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return CollectResult(infos: [], newCPUNs: [:]) }
        var pids = [Int32](repeating: 0, count: Int(count))
        proc_listallpids(&pids, Int32(count) * Int32(MemoryLayout<Int32>.size))

        // 2. Running GUI apps for icon + bundleID lookup
        let runningApps = NSWorkspace.shared.runningApplications
        let appsByPID: [Int32: NSRunningApplication] = Dictionary(
            uniqueKeysWithValues: runningApps.map { (Int32($0.processIdentifier), $0) }
        )

        var infos: [ProcessInfo] = []
        var newCPUNs: [Int32: (user: UInt64, sys: UInt64)] = [:]

        for pid in pids where pid > 0 {
            guard let (info, cpuNs) = getProcessInfo(
                pid: pid, appsByPID: appsByPID,
                prevCPUNs: prevCPUNs, elapsedSec: elapsed
            ) else { continue }
            infos.append(info)
            newCPUNs[pid] = cpuNs
        }

        return CollectResult(
            infos: infos.sorted { $0.cpuPercent > $1.cpuPercent },
            newCPUNs: newCPUNs
        )
    }

    private func getProcessInfo(
        pid: Int32,
        appsByPID: [Int32: NSRunningApplication],
        prevCPUNs: [Int32: (user: UInt64, sys: UInt64)],
        elapsedSec: Double
    ) -> (ProcessInfo, (user: UInt64, sys: UInt64))? {
        // Task info (CPU + memory)
        var taskInfo = proc_taskinfo()
        let ret = proc_pidinfo(pid,
                               PROC_PIDTASKINFO,
                               0,
                               &taskInfo,
                               Int32(MemoryLayout<proc_taskinfo>.size))
        guard ret > 0 else { return nil }

        // Path
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
        let execPath = String(cString: pathBuf)
        guard !execPath.isEmpty else { return nil }

        let name = URL(fileURLWithPath: execPath).deletingPathExtension().lastPathComponent

        // CPU: delta nanoseconds / elapsed wall time → fraction → percent
        let curUser = UInt64(taskInfo.pti_total_user)
        let curSys  = UInt64(taskInfo.pti_total_system)
        var cpuPercent: Double = 0
        if let prev = prevCPUNs[pid] {
            let dUser = curUser &- prev.user
            let dSys  = curSys  &- prev.sys
            let deltaNs = Double(dUser + dSys)
            cpuPercent = min(100.0, deltaNs / (elapsedSec * 1_000_000_000.0) * 100.0)
        }
        let cpuNs = (user: curUser, sys: curSys)

        // Memory: resident set size
        let memBytes = UInt64(taskInfo.pti_resident_size)

        // BSDINFO for PPID
        var bsdInfo = proc_bsdinfo()
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo,
                     Int32(MemoryLayout<proc_bsdinfo>.size))

        let app = appsByPID[pid]

        return (ProcessInfo(
            id: pid,
            name: app?.localizedName ?? name,
            executablePath: execPath,
            cpuPercent: max(0, cpuPercent),
            memoryBytes: memBytes,
            parentPID: Int32(bsdInfo.pbi_ppid),
            isGUIApp: app != nil,
            bundleIdentifier: app?.bundleIdentifier,
            icon: nil
        ), cpuNs)
    }

    // MARK: - Alert Detection

    @MainActor
    private func updateAlerts() {
        var newAlerts: [ProcessAlert] = []

        for proc in processes {
            // Update history
            var cpuHist = cpuHistory[proc.id] ?? []
            cpuHist.append(proc.cpuPercent)
            if cpuHist.count > leakSamples { cpuHist.removeFirst() }
            cpuHistory[proc.id] = cpuHist

            var memHist = memHistory[proc.id] ?? []
            memHist.append(proc.memoryBytes)
            if memHist.count > leakSamples { memHist.removeFirst() }
            memHistory[proc.id] = memHist

            // High CPU (sustained)
            if cpuHist.count >= 3 && cpuHist.allSatisfy({ $0 >= cpuWarningThreshold }) {
                newAlerts.append(ProcessAlert(
                    pid: proc.id,
                    processName: proc.name,
                    type: .highCPU,
                    value: proc.cpuPercent
                ))
            }

            // High memory
            if proc.memoryBytes >= memWarningBytes {
                newAlerts.append(ProcessAlert(
                    pid: proc.id,
                    processName: proc.name,
                    type: .highMemory,
                    value: Double(proc.memoryBytes)
                ))
            }

            // Memory leak (consecutive increases > 10%)
            if memHist.count >= leakSamples {
                let pairs = zip(memHist, memHist.dropFirst())
                let isLeaking = pairs.allSatisfy { (prev: UInt64, curr: UInt64) -> Bool in
                    // Cast to Double FIRST to avoid UInt64 underflow when memory decreases
                    guard prev > 0, curr > prev else { return false }
                    return (Double(curr) - Double(prev)) / Double(prev) > 0.1
                }
                if isLeaking {
                    newAlerts.append(ProcessAlert(
                        pid: proc.id,
                        processName: proc.name,
                        type: .possibleMemoryLeak,
                        value: Double(proc.memoryBytes)
                    ))
                }
            }
        }

        alerts = newAlerts
    }

    // MARK: - Actions

    func quit(pid: Int32) {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid }) else {
            kill(pid, SIGTERM)
            return
        }
        app.terminate()
    }

    func forceQuit(pid: Int32) {
        kill(pid, SIGKILL)
        Task {
            await AuditLog.shared.record(.processKill(
                pid: pid,
                name: processes.first(where: { $0.id == pid })?.name ?? "unknown",
                caller: "gui"
            ))
        }
    }
}

// MARK: - Process Alert

struct ProcessAlert: Identifiable {
    let id = UUID()
    var pid: Int32
    var processName: String
    var type: AlertType
    var value: Double
    var timestamp = Date()

    enum AlertType {
        case highCPU
        case highMemory
        case possibleMemoryLeak

        var title: String {
            switch self {
            case .highCPU:            return "CPU 使用率過高"
            case .highMemory:         return "記憶體佔用過大"
            case .possibleMemoryLeak: return "疑似記憶體洩漏"
            }
        }

        var icon: String {
            switch self {
            case .highCPU:            return "cpu"
            case .highMemory:         return "memorychip"
            case .possibleMemoryLeak: return "exclamationmark.triangle"
            }
        }

        var alertLevel: AlertLevel {
            switch self {
            case .highCPU:            return .warning
            case .highMemory:         return .warning
            case .possibleMemoryLeak: return .critical
            }
        }
    }
}

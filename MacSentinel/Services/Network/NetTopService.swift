//
//  NetTopService.swift
//  MacSentinel
//
//  Streams `nettop -d` to produce per-process network throughput numbers.
//  Cheaper than NetworkExtension (which needs entitlement + system extension)
//  and gives the same data Activity Monitor shows. No sudo required.
//
//  Lifecycle:
//   • call `start()` when the Network drill-down appears
//   • call `stop()`  when it goes away
//   • observe `entries` (sorted, Top N) for display
//

import Foundation
import Observation

@MainActor
@Observable
final class NetTopService {

    struct Entry: Identifiable, Hashable {
        let id: Int32           // PID
        let name: String        // process name (without .PID suffix)
        let bytesInPerSec: UInt64
        let bytesOutPerSec: UInt64
        var totalPerSec: UInt64 { bytesInPerSec &+ bytesOutPerSec }
    }

    /// Per-process throughput from the latest 1-second sample. Sorted by
    /// totalPerSec descending. Only delta samples are kept (the first
    /// nettop sample is cumulative since boot and gets discarded).
    private(set) var entries: [Entry] = []

    /// Total instantaneous throughput across all entries (for sparkline).
    private(set) var totalInPerSec: UInt64 = 0
    private(set) var totalOutPerSec: UInt64 = 0

    /// Last 60 seconds of (in, out) for sparkline.
    private(set) var history: [(UInt64, UInt64)] = []

    /// Whether the underlying nettop process is currently running.
    private(set) var isRunning = false

    /// Last error message (e.g. nettop not found).
    private(set) var lastError: String?

    private var process: Process?
    private var stdoutTask: Task<Void, Never>?
    private var pendingRows: [(pid: Int32, name: String, bin: UInt64, bout: UInt64)] = []
    private var sampleCount = 0  // number of "time," header rows seen

    // MARK: - Public

    func start() {
        guard !isRunning else { return }
        sampleCount = 0
        pendingRows.removeAll()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P per-process only; -J bytes_in,bytes_out columns; -x raw numbers;
        // -L 0 unlimited logging in CSV; -d delta mode; -s 1 sample every 1s;
        // -t external skip loopback so localhost traffic doesn't pollute the view.
        p.arguments = ["-P", "-J", "bytes_in,bytes_out",
                       "-x", "-L", "0", "-d", "-s", "1", "-t", "external"]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        do {
            try p.run()
        } catch {
            lastError = "無法啟動 nettop: \(error.localizedDescription)"
            return
        }
        process = p
        isRunning = true
        lastError = nil

        let handle = pipe.fileHandleForReading
        stdoutTask = Task.detached(priority: .utility) { [weak self] in
            await self?.readLoop(handle)
        }
    }

    func stop() {
        stdoutTask?.cancel()
        stdoutTask = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        isRunning = false
    }

    // MARK: - Read loop

    private func readLoop(_ handle: FileHandle) async {
        var buffer = ""
        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            buffer.append(text)

            // Split lines, leave incomplete remainder in buffer
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer = String(buffer[buffer.index(after: nl)...])
                await processLine(line)
            }
        }
    }

    @MainActor
    private func processLine(_ line: String) async {
        // Header rows like "time,,bytes_in,bytes_out,"
        if line.hasPrefix("time,") {
            flushSample()
            sampleCount += 1
            return
        }
        // Data row: "07:27:00.291588,apsd.378,6357,12465,"
        let cols = line.split(separator: ",", omittingEmptySubsequences: false)
        guard cols.count >= 4 else { return }
        let processWithPID = String(cols[1])
        guard let dotIdx = processWithPID.lastIndex(of: ".") else { return }
        let name = String(processWithPID[..<dotIdx])
        let pidStr = String(processWithPID[processWithPID.index(after: dotIdx)...])
        guard let pid = Int32(pidStr) else { return }
        guard let bin = UInt64(cols[2].trimmingCharacters(in: .whitespaces)),
              let bout = UInt64(cols[3].trimmingCharacters(in: .whitespaces)) else { return }
        pendingRows.append((pid, name, bin, bout))
    }

    @MainActor
    private func flushSample() {
        // The FIRST sample after start is cumulative-since-boot — discard.
        guard sampleCount >= 2 else {
            pendingRows.removeAll()
            return
        }

        let new = pendingRows.map { row in
            Entry(id: row.pid, name: row.name,
                  bytesInPerSec: row.bin, bytesOutPerSec: row.bout)
        }
        entries = new.sorted { $0.totalPerSec > $1.totalPerSec }

        let tin  = new.reduce(UInt64(0)) { $0 &+ $1.bytesInPerSec }
        let tout = new.reduce(UInt64(0)) { $0 &+ $1.bytesOutPerSec }
        totalInPerSec  = tin
        totalOutPerSec = tout

        history.append((tin, tout))
        if history.count > 60 { history.removeFirst(history.count - 60) }

        pendingRows.removeAll()
    }
}

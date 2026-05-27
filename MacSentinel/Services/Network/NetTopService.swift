//
//  NetTopService.swift
//  MacSentinel
//
//  Streams `nettop -d` to produce per-process network throughput numbers.
//  No NetworkExtension entitlement / sudo required — same data Activity
//  Monitor's Network tab uses.
//
//  Threading: the class is intentionally NOT `@MainActor`. The read loop
//  blocks on FileHandle.availableData, so it MUST run on a background
//  queue. Every state mutation is bounced back to the main actor with
//  `MainActor.run { ... }` so SwiftUI bindings see consistent values.
//

import Foundation
import Observation

@Observable
final class NetTopService: @unchecked Sendable {

    struct Entry: Identifiable, Hashable {
        let id: Int32           // PID
        let name: String
        let bytesInPerSec: UInt64
        let bytesOutPerSec: UInt64
        var totalPerSec: UInt64 { bytesInPerSec &+ bytesOutPerSec }
    }

    // ─── @Observable surface (read on main thread by SwiftUI) ──────────────
    private(set) var entries: [Entry] = []
    private(set) var totalInPerSec: UInt64 = 0
    private(set) var totalOutPerSec: UInt64 = 0
    private(set) var history: [(UInt64, UInt64)] = []
    private(set) var isRunning = false
    private(set) var lastError: String?

    // ─── Background-only state (touched by the read loop, never SwiftUI) ──
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var readQueue = DispatchQueue(label: "macsentinel.nettop.read",
                                                              qos: .utility)
    @ObservationIgnored private var pendingRows: [(pid: Int32, name: String, bin: UInt64, bout: UInt64)] = []
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var lineBuffer = ""
    @ObservationIgnored private var shouldStop = false

    // MARK: - Public

    @MainActor
    func start() {
        guard !isRunning else { return }
        sampleCount = 0
        pendingRows.removeAll()
        lineBuffer = ""
        shouldStop = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
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

        // Pipe-based reading via DispatchIO would be ideal; for clarity we use
        // a plain background queue with availableData (which DOES block, hence
        // it must NEVER run on the main thread).
        let handle = pipe.fileHandleForReading
        readQueue.async { [weak self] in
            self?.readLoop(handle)
        }
    }

    @MainActor
    func stop() {
        shouldStop = true
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        isRunning = false
    }

    // MARK: - Read loop (runs on background queue ONLY)

    private func readLoop(_ handle: FileHandle) {
        while !shouldStop {
            let chunk = handle.availableData
            if chunk.isEmpty { break }     // pipe closed → exit
            guard let text = String(data: chunk, encoding: .utf8) else { continue }

            lineBuffer.append(text)
            while let nl = lineBuffer.firstIndex(of: "\n") {
                let line = String(lineBuffer[..<nl])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: nl)...])
                processLineBackground(line)
            }
        }
    }

    /// Parses one CSV line on the background queue, then hops to the main
    /// actor for any @Observable property mutation.
    private func processLineBackground(_ line: String) {
        if line.hasPrefix("time,") {
            // Sample boundary — flush whatever we accumulated.
            let rows = pendingRows
            pendingRows.removeAll()
            let count = sampleCount + 1
            sampleCount = count
            // First sample is cumulative-since-boot — discard.
            guard count >= 2 else { return }

            let entries = rows.map { row in
                Entry(id: row.pid, name: row.name,
                      bytesInPerSec: row.bin, bytesOutPerSec: row.bout)
            }
            .sorted { $0.totalPerSec > $1.totalPerSec }

            let tin  = entries.reduce(UInt64(0)) { $0 &+ $1.bytesInPerSec }
            let tout = entries.reduce(UInt64(0)) { $0 &+ $1.bytesOutPerSec }

            // Hop to MainActor to publish.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.entries = entries
                self.totalInPerSec = tin
                self.totalOutPerSec = tout
                self.history.append((tin, tout))
                if self.history.count > 60 {
                    self.history.removeFirst(self.history.count - 60)
                }
            }
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
}

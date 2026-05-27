//
//  NetTopService.swift
//  MacSentinel
//
//  Per-process network throughput via repeated short-lived `nettop -L 2`
//  invocations. WHY THIS DESIGN:
//
//    A long-running `nettop -L 0` piped into our app would let libc on
//    nettop's side block-buffer 16 KB before flushing — at typical idle
//    output rate (~500 B/s) that's a 30-second delay before the first
//    sample reaches us. PTY wrapping via /usr/bin/script doesn't work
//    because script requires its own stdin to be a tty (it isn't when
//    spawned by Process.standardInput == Pipe).
//
//    The reliable workaround: spawn nettop with `-L 2` (one cumulative
//    sample + one delta sample, then exit). At exit, libc flushes the
//    whole buffer. We parse, publish the delta, and immediately respawn
//    for the next round. Per-iteration spawn cost is ~10 ms; the 1-second
//    sample interval is the gate, so we deliver one update per second.
//
//  No PTY, no sudo, no third-party tooling.
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

    // ─── @Observable surface (main-thread reads) ──────────────────────────
    private(set) var entries: [Entry] = []
    private(set) var totalInPerSec: UInt64 = 0
    private(set) var totalOutPerSec: UInt64 = 0
    private(set) var history: [(UInt64, UInt64)] = []
    private(set) var isRunning = false
    private(set) var lastError: String?

    // ─── Background-only state ────────────────────────────────────────────
    @ObservationIgnored private let workQueue = DispatchQueue(label: "macsentinel.nettop.poll",
                                                              qos: .utility)
    @ObservationIgnored private var shouldStop = false
    @ObservationIgnored private var currentProcess: Process?

    // MARK: - Public

    @MainActor
    func start() {
        guard !isRunning else { return }
        shouldStop = false
        isRunning = true
        lastError = nil
        workQueue.async { [weak self] in self?.pollLoop() }
    }

    @MainActor
    func stop() {
        shouldStop = true
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
    }

    // MARK: - Poll loop

    /// Runs on `workQueue`. Spawns `nettop -L 2 -d` synchronously, waits for
    /// it to exit (~1 second), parses the captured output, publishes the
    /// delta sample. Loops until `shouldStop`.
    private func pollLoop() {
        while !shouldStop {
            let output = runOneShot()
            if shouldStop { return }
            let entries = parseDelta(output)
            publishOnMain(entries)
        }
    }

    /// Spawn `nettop -L 2 -d -s 1` and collect its complete stdout once it
    /// exits. Returns the raw multi-line string (or empty on failure).
    private func runOneShot() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = [
            "-P",                                  // per-process only
            "-J", "bytes_in,bytes_out",            // columns
            "-x",                                  // raw numbers
            "-L", "2",                             // 2 samples (cumulative + 1 delta), then exit
            "-d",                                  // delta mode
            "-s", "1",                             // 1-second interval
            "-t", "external"                       // skip loopback
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        currentProcess = p
        do { try p.run() } catch {
            publishError("無法啟動 nettop: \(error.localizedDescription)")
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        currentProcess = nil
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parsing

    /// nettop with `-L 2 -d` emits two CSV samples separated by a header
    /// line. The first sample is cumulative-since-boot; the second is the
    /// 1-second delta we actually want.
    private func parseDelta(_ raw: String) -> [Entry] {
        var inSecondBlock = false
        var headerSeen = 0
        var entries: [Entry] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r")
                ? String(rawLine.dropLast())
                : String(rawLine)
            if line.hasPrefix("time,") {
                headerSeen += 1
                inSecondBlock = (headerSeen == 2)
                continue
            }
            guard inSecondBlock else { continue }
            // "07:27:00.291588,apsd.378,6357,12465,"
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 4 else { continue }
            let procPid = String(cols[1])
            guard let dot = procPid.lastIndex(of: ".") else { continue }
            let name = String(procPid[..<dot])
            guard let pid = Int32(procPid[procPid.index(after: dot)...]) else { continue }
            guard let bin = UInt64(cols[2].trimmingCharacters(in: .whitespaces)),
                  let bout = UInt64(cols[3].trimmingCharacters(in: .whitespaces)) else { continue }
            entries.append(Entry(id: pid, name: name,
                                  bytesInPerSec: bin, bytesOutPerSec: bout))
        }
        return entries.sorted { $0.totalPerSec > $1.totalPerSec }
    }

    // MARK: - Publish

    private func publishOnMain(_ newEntries: [Entry]) {
        let tin  = newEntries.reduce(UInt64(0)) { $0 &+ $1.bytesInPerSec }
        let tout = newEntries.reduce(UInt64(0)) { $0 &+ $1.bytesOutPerSec }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries = newEntries
            self.totalInPerSec = tin
            self.totalOutPerSec = tout
            self.history.append((tin, tout))
            if self.history.count > 60 {
                self.history.removeFirst(self.history.count - 60)
            }
        }
    }

    private func publishError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = msg
        }
    }
}

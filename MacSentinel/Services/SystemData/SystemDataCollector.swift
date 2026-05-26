import Foundation
import Combine

// MARK: - CPU tick storage (per-core, per-state)
private struct CPUCoreTicks {
    var user: UInt32; var system: UInt32; var idle: UInt32; var nice: UInt32
}

// MARK: - System Data Collector (actor – background sampling thread)

@Observable
final class SystemDataCollector {

    static let shared = SystemDataCollector()

    // ── Published State ──────────────────────────────────────────────────────
    private(set) var latestSnapshot: SystemSnapshot?
    private(set) var history: [SystemSnapshot] = []          // last 60 snapshots (2 min)
    private(set) var systemAlerts: [SystemAlert] = []

    // ── Configuration ────────────────────────────────────────────────────────
    let sampleInterval: TimeInterval = 2.0
    let historyCapacity = 60

    // ── Private ──────────────────────────────────────────────────────────────
    private var timer: Timer?
    private var prevCPULoads: [CPUCoreTicks] = []
    private var prevDiskIO: DiskIOData = .init()
    private var prevNetStats: [String: (rx: UInt64, tx: UInt64)] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        // Immediate first sample
        Task { await sample() }
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { await self?.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One-shot start that immediately samples; pair with stopOnce(). Used by
    /// MCP `get_system_health` tool which needs a fresh snapshot from a CLI
    /// without running a long-lived timer.
    @MainActor
    func startOnce() async { await sample() }
    @MainActor
    func stopOnce() async {}

    // MARK: - Sampling

    @MainActor
    func sample() async {
        let snap = await Task.detached(priority: .utility) { [weak self] in
            self?.buildSnapshot()
        }.value

        guard let snap else { return }

        latestSnapshot = snap
        history.append(snap)
        if history.count > historyCapacity { history.removeFirst() }

        updateAlerts(from: snap)
    }

    private func buildSnapshot() -> SystemSnapshot {
        let cpu     = collectCPU()
        let memory  = collectMemory()
        let battery = collectBattery()
        let disk    = collectDisk()
        let network = collectNetwork()
        let thermal = collectThermal()

        return SystemSnapshot(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            battery: battery,
            disk: disk,
            network: network,
            thermal: thermal
        )
    }

    // MARK: - CPU Collection

    private func collectCPU() -> CPUSnapshot {
        var cpuCount: natural_t = 0
        var cpuLoad: processor_info_array_t?
        var cpuMsgCount: mach_msg_type_number_t = 0

        let ret = host_processor_info(mach_host_self(),
                                       PROCESSOR_CPU_LOAD_INFO,
                                       &cpuCount,
                                       &cpuLoad,
                                       &cpuMsgCount)
        guard ret == KERN_SUCCESS, let loads = cpuLoad else {
            return CPUSnapshot(usagePercent: 0, coreUsages: [], systemPercent: 0,
                               userPercent: 0, idlePercent: 100)
        }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuLoad), vm_size_t(cpuMsgCount)) }

        let count = Int(cpuCount)
        var coreUsages: [Double] = []
        var totalUser: Double = 0, totalSystem: Double = 0, totalIdle: Double = 0

        for i in 0..<count {
            let offset = i * Int(CPU_STATE_MAX)
            let curUser   = UInt32(loads[offset + Int(CPU_STATE_USER)])
            let curSystem = UInt32(loads[offset + Int(CPU_STATE_SYSTEM)])
            let curIdle   = UInt32(loads[offset + Int(CPU_STATE_IDLE)])
            let curNice   = UInt32(loads[offset + Int(CPU_STATE_NICE)])

            // Compute delta vs previous sample
            var dUser: Double = 0, dSystem: Double = 0, dIdle: Double = 0, dNice: Double = 0
            if i < prevCPULoads.count {
                let p = prevCPULoads[i]
                dUser   = Double(curUser   &- p.user)
                dSystem = Double(curSystem &- p.system)
                dIdle   = Double(curIdle   &- p.idle)
                dNice   = Double(curNice   &- p.nice)
            } else {
                // First sample — fall back to absolute (will be 0% effectively)
                dUser = Double(curUser); dSystem = Double(curSystem)
                dIdle = Double(curIdle); dNice   = Double(curNice)
            }

            let dTotal = dUser + dSystem + dIdle + dNice
            let usage = dTotal > 0 ? (dUser + dSystem + dNice) / dTotal * 100 : 0
            coreUsages.append(min(100, max(0, usage)))
            totalUser   += dUser + dNice
            totalSystem += dSystem
            totalIdle   += dIdle
        }

        // Store current ticks for next sample
        var newLoads: [CPUCoreTicks] = []
        for i in 0..<count {
            let offset = i * Int(CPU_STATE_MAX)
            newLoads.append(CPUCoreTicks(
                user:   UInt32(loads[offset + Int(CPU_STATE_USER)]),
                system: UInt32(loads[offset + Int(CPU_STATE_SYSTEM)]),
                idle:   UInt32(loads[offset + Int(CPU_STATE_IDLE)]),
                nice:   UInt32(loads[offset + Int(CPU_STATE_NICE)])
            ))
        }
        prevCPULoads = newLoads

        let grandTotal = totalUser + totalSystem + totalIdle
        let usagePercent  = grandTotal > 0 ? (totalUser + totalSystem) / grandTotal * 100 : 0
        let userPercent   = grandTotal > 0 ? totalUser   / grandTotal * 100 : 0
        let systemPercent = grandTotal > 0 ? totalSystem / grandTotal * 100 : 0
        let idlePercent   = grandTotal > 0 ? totalIdle   / grandTotal * 100 : 0

        return CPUSnapshot(
            usagePercent: min(100, max(0, usagePercent)),
            coreUsages: coreUsages,
            systemPercent: min(100, max(0, systemPercent)),
            userPercent: min(100, max(0, userPercent)),
            idlePercent: min(100, max(0, idlePercent))
        )
    }

    // MARK: - Memory Collection

    private func collectMemory() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let ret = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var totalRAM: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalRAM, &size, nil, 0)

        guard ret == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: totalRAM, usedBytes: 0, freeBytes: totalRAM,
                                   wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0,
                                   pressureLevel: .normal)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let wired    = UInt64(stats.wire_count)     * pageSize
        let active   = UInt64(stats.active_count)   * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free     = UInt64(stats.free_count)     * pageSize
        let used     = wired + active + inactive + compressed

        // Swap
        var swapInfo = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapInfo, &swapSize, nil, 0)
        let swapUsed = swapInfo.xsu_used

        // Pressure level (heuristic based on ratio)
        let usageRatio = totalRAM > 0 ? Double(used) / Double(totalRAM) : 0
        let pressure: MemoryPressureLevel = usageRatio > 0.95 ? .critical : usageRatio > 0.80 ? .warning : .normal

        return MemorySnapshot(
            totalBytes: totalRAM,
            usedBytes: used,
            freeBytes: free,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapUsedBytes: swapUsed,
            pressureLevel: pressure
        )
    }

    // MARK: - Battery Collection

    private func collectBattery() -> BatterySnapshot {
        let data = readBatteryData()
        guard data.isAvailable else {
            // Desktop Mac (Mac mini / Mac Studio) — no battery
            return BatterySnapshot(isAvailable: false, percentage: 100,
                                   isCharging: false, isPluggedIn: true,
                                   isFullyCharged: true, cycleCount: 0,
                                   healthPercent: 1.0, temperatureCelsius: -1,
                                   voltageVolts: 0, amperageAmps: 0)
        }

        // Health: prefer AppleRawMaxCapacity (mAh) ÷ DesignCapacity (mAh).
        // On Apple Silicon MaxCapacity is in %, so dividing it by designCapacity gives garbage.
        // Fall back to NominalChargeCapacity if raw is unavailable.
        let rawCapacityMAh: Int32 = data.rawMaxCapacity > 0
            ? data.rawMaxCapacity
            : data.nominalChargeCapacity
        let health: Double
        if data.designCapacity > 0 && rawCapacityMAh > 0 {
            health = Double(rawCapacityMAh) / Double(data.designCapacity)
        } else if data.designCapacity > 0 && data.maxCapacity > 100 {
            // Pre-Apple-Silicon path: MaxCapacity is in mAh
            health = Double(data.maxCapacity) / Double(data.designCapacity)
        } else {
            health = 1.0   // Cannot determine — assume healthy rather than scare the user
        }

        let tempC = data.temperature > 0 ? Double(data.temperature) / 100.0 : -1.0  // 0.01 °C units

        // Percentage: when MaxCapacity == 100, CurrentCapacity already IS the percentage
        let pct: Int
        if data.maxCapacity == 100 {
            pct = Int(min(100, max(0, data.currentCapacity)))
        } else if data.maxCapacity > 0 {
            pct = min(100, Int(Double(data.currentCapacity) / Double(data.maxCapacity) * 100))
        } else {
            pct = Int(data.currentCapacity)
        }

        return BatterySnapshot(
            isAvailable: true,
            percentage: pct,
            isCharging: data.isCharging,
            isPluggedIn: data.isPluggedIn,
            isFullyCharged: data.isFullyCharged,
            cycleCount: Int(data.cycleCount),
            healthPercent: min(1.0, max(0, health)),
            temperatureCelsius: tempC,
            voltageVolts: data.voltage,
            amperageAmps: data.amperage
        )
    }

    // MARK: - Disk Collection

    private func collectDisk() -> DiskSnapshot {
        var stat = statvfs()
        statvfs("/", &stat)
        let blockSize = UInt64(stat.f_frsize)
        let total  = UInt64(stat.f_blocks) * blockSize
        let free   = UInt64(stat.f_bavail) * blockSize
        let used   = total - free

        let ioData = readDiskIOData()
        var readPS: Double = 0
        var writePS: Double = 0
        if ioData.isAvailable && prevDiskIO.isAvailable {
            let dRead  = ioData.bytesRead    &- prevDiskIO.bytesRead
            let dWrite = ioData.bytesWritten &- prevDiskIO.bytesWritten
            readPS  = Double(dRead)  / sampleInterval
            writePS = Double(dWrite) / sampleInterval
        }
        prevDiskIO = ioData

        return DiskSnapshot(
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            readBytesPerSec: max(0, readPS),
            writeBytesPerSec: max(0, writePS)
        )
    }

    // MARK: - Network Collection

    private func collectNetwork() -> NetworkSnapshot {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        getifaddrs(&ifa)
        defer { freeifaddrs(ifa) }

        // Accumulate per-interface byte totals
        var ifaceStats: [String: (rx: UInt64, tx: UInt64)] = [:]
        var ptr = ifa
        while let p = ptr {
            let iface = p.pointee
            if iface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: iface.ifa_name)
                guard name.hasPrefix("en") || name.hasPrefix("utun") else {
                    ptr = iface.ifa_next; continue
                }
                if let d = iface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    let rx = UInt64(d.pointee.ifi_ibytes)
                    let tx = UInt64(d.pointee.ifi_obytes)
                    ifaceStats[name] = (rx: rx, tx: tx)
                }
            }
            ptr = iface.ifa_next
        }

        // Sum deltas across all matching interfaces
        var upPS: Double = 0, downPS: Double = 0
        var upTotal: UInt64 = 0, downTotal: UInt64 = 0
        var activeIface = "en0"

        for (name, cur) in ifaceStats {
            upTotal   += cur.tx
            downTotal += cur.rx
            if let prev = prevNetStats[name] {
                let dTx = cur.tx &- prev.tx
                let dRx = cur.rx &- prev.rx
                upPS   += Double(dTx) / sampleInterval
                downPS += Double(dRx) / sampleInterval
                if dTx > 0 || dRx > 0 { activeIface = name }
            }
        }
        prevNetStats = ifaceStats

        return NetworkSnapshot(
            uploadBytesPerSec:   max(0, upPS),
            downloadBytesPerSec: max(0, downPS),
            totalUploadBytes:   upTotal,
            totalDownloadBytes: downTotal,
            activeInterface: activeIface
        )
    }

    // MARK: - Thermal Collection
    //
    // Strategy:
    //   1. Try Apple Silicon HID-based sensors (works on M1/M2/M3+, no root)
    //   2. Fall back to legacy SMC keys (works on Intel Macs)
    //   3. If both fail, return -1 (UI shows "—")
    //
    // Fan/power readings still come from SMC even on Apple Silicon — IOHID
    // doesn't expose them. Power can be enriched later via XPC Helper +
    // powermetrics(8) when SMAppService is wired up.

    private func collectThermal() -> ThermalSnapshot {
        let hid = readAppleSiliconThermal()
        let smc = smcReadAll()

        let cpuTemp: Double = {
            if hid.isAvailable && hid.cpuTemperature > 0 { return hid.cpuTemperature }
            if smc.isAvailable && smc.cpuTemperature > 0 { return smc.cpuTemperature }
            return -1
        }()
        let gpuTemp: Double = {
            if hid.isAvailable && hid.gpuTemperature > 0 { return hid.gpuTemperature }
            if smc.isAvailable && smc.gpuTemperature > 0 { return smc.gpuTemperature }
            return -1
        }()
        let fan: Double = (smc.isAvailable && smc.fanSpeedRPM > 0) ? smc.fanSpeedRPM : -1
        let watts: Double = (smc.isAvailable && smc.totalPowerWatts > 0) ? smc.totalPowerWatts : -1

        return ThermalSnapshot(
            cpuTemperatureCelsius: cpuTemp,
            gpuTemperatureCelsius: gpuTemp,
            fanSpeedRPM: fan,
            totalPowerWatts: watts
        )
    }

    // MARK: - Alert Generation

    @MainActor
    private func updateAlerts(from snap: SystemSnapshot) {
        var alerts: [SystemAlert] = []

        if snap.cpu.alertLevel >= .warning {
            alerts.append(SystemAlert(
                id: "cpu_high",
                level: snap.cpu.alertLevel,
                title: "CPU 使用率過高",
                message: "目前 CPU 使用率 \(ByteFormatter.formatPercent(snap.cpu.usagePercent))",
                icon: "cpu"
            ))
        }
        if snap.memory.alertLevel >= .warning {
            alerts.append(SystemAlert(
                id: "mem_pressure",
                level: snap.memory.alertLevel,
                title: "記憶體壓力",
                message: "記憶體使用 \(ByteFormatter.formatPercent(snap.memory.usagePercent))",
                icon: "memorychip"
            ))
        }
        // Low charge alert — only fires when on battery AND ≤ 20%
        if snap.battery.lowBatteryAlertLevel >= .warning {
            alerts.append(SystemAlert(
                id: "battery_low",
                level: snap.battery.lowBatteryAlertLevel,
                title: "電池電量低",
                message: "剩餘 \(snap.battery.percentage)%，請接上電源",
                icon: "battery.25"
            ))
        }
        // Health alert — fires whenever maxCapacity / designCapacity < 80%
        if snap.battery.healthAlertLevel >= .warning {
            alerts.append(SystemAlert(
                id: "battery_health",
                level: snap.battery.healthAlertLevel,
                title: "電池健康度偏低",
                message: "電池健康度 \(ByteFormatter.formatPercent(snap.battery.healthPercent * 100))，循環次數 \(snap.battery.cycleCount)",
                icon: "heart.slash.fill"
            ))
        }
        if snap.disk.alertLevel >= .warning {
            alerts.append(SystemAlert(
                id: "disk_full",
                level: snap.disk.alertLevel,
                title: "磁碟空間不足",
                message: "磁碟使用率 \(ByteFormatter.formatPercent(snap.disk.usagePercent))",
                icon: "externaldrive.fill"
            ))
        }
        if snap.thermal.cpuAlertLevel >= .warning {
            alerts.append(SystemAlert(
                id: "temp_high",
                level: snap.thermal.cpuAlertLevel,
                title: "CPU 溫度過高",
                message: "CPU 溫度 \(ByteFormatter.formatTemp(snap.thermal.cpuTemperatureCelsius))",
                icon: "thermometer.sun.fill"
            ))
        }

        systemAlerts = alerts
    }
}

// MARK: - System Alert

struct SystemAlert: Identifiable {
    let id: String
    var level: AlertLevel
    var title: String
    var message: String
    var icon: String
    var timestamp = Date()
}

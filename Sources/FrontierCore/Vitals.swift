import Foundation
import IOKit.ps
import CoreWLAN

/// One reading of the machine's "cores". All levels are 0…1 where 1 is healthy.
public struct VitalSample: Equatable, Sendable {
    public var cpuFree: Double
    public var ramFree: Double
    public var battery: Double?
    public var charging: Bool
    public var wifi: Double?
    /// Raw readings behind the rings, for the hover readout.
    public var wifiRSSI: Int?
    public var ramTotalGB: Double

    public init(cpuFree: Double, ramFree: Double, battery: Double?, charging: Bool, wifi: Double?,
                wifiRSSI: Int? = nil, ramTotalGB: Double = 0) {
        self.cpuFree = cpuFree; self.ramFree = ramFree; self.battery = battery
        self.charging = charging; self.wifi = wifi; self.wifiRSSI = wifiRSSI; self.ramTotalGB = ramTotalGB
    }

    public var batteryText: String? {
        battery.map { "\(Int(($0 * 100).rounded()))%" }   // charging is already shown by the gold ring
    }

    public var wifiText: String? {
        guard let wifi else { return nil }
        guard let rssi = wifiRSSI, rssi < 0 else { return wifi > 0 ? "\(Int(wifi * 100))%" : "Off" }
        return "\(rssi) dBm"
    }

    public var ramText: String {
        guard ramTotalGB > 0 else { return "\(Int(((1 - ramFree) * 100).rounded()))% used" }
        return String(format: "%.1f / %.0f GB", (1 - ramFree) * ramTotalGB, ramTotalGB)
    }

    public var cpuText: String { "\(Int(((1 - cpuFree) * 100).rounded()))% load" }
}

/// The slow-moving inner "core": an exponential moving average of the fast ring.
public struct SlowCore: Equatable, Sendable {
    public private(set) var value: Double?
    public init() {}
    public mutating func update(_ x: Double, alpha: Double = 0.06) {
        value = value.map { $0 + alpha * (x - $0) } ?? x
    }
}

public enum VitalsMath {
    /// RSSI in dBm -> 0…1 signal quality (-90 dBm unusable, -40 dBm excellent).
    public static func wifiQuality(rssi: Int) -> Double {
        guard rssi < 0 else { return 0 }
        return min(1, max(0, (Double(rssi) + 90) / 50))
    }

    public static func cpuFree(prev: (busy: UInt64, total: UInt64), cur: (busy: UInt64, total: UInt64)) -> Double {
        guard cur.total > prev.total else { return 1 }
        let busy = Double(cur.busy &- prev.busy) / Double(cur.total - prev.total)
        return min(1, max(0, 1 - busy))
    }
}

public final class VitalsMonitor {
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private let wifi = CWWiFiClient.shared()

    public init() {}

    public func sample() -> VitalSample {
        let cur = Self.cpuTicks()
        let cpu = lastCPU.map { VitalsMath.cpuFree(prev: $0, cur: cur) } ?? 1
        lastCPU = cur
        let batt = Self.battery()
        let signal = wifiReading()
        return VitalSample(cpuFree: cpu, ramFree: Self.ramFree(), battery: batt?.level,
                           charging: batt?.charging ?? false, wifi: signal?.quality, wifiRSSI: signal?.rssi,
                           ramTotalGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    }

    private func wifiReading() -> (quality: Double, rssi: Int?)? {
        guard let iface = wifi.interface() else { return nil }
        guard iface.powerOn() else { return (0, nil) }
        let rssi = iface.rssiValue()
        return (VitalsMath.wifiQuality(rssi: rssi), rssi)
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + sys + nice, user + sys + nice + idle)
    }

    static func ramFree() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 1 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        // Same accounting as Activity Monitor's "Memory Used": app + wired + compressed.
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let usedPages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = Double(usedPages) * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return min(1, max(0, 1 - used / total))
    }

    static func battery() -> (level: Double, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let maxCap = d[kIOPSMaxCapacityKey] as? Int, maxCap > 0 else { continue }
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (min(1, Double(cur) / Double(maxCap)), onAC)
        }
        return nil
    }
}

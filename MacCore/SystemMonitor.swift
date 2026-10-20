import AppKit
import IOKit.ps

struct SystemSnapshot {
    var cpu: Double?
    var usedMemory: Int64?
    var totalMemory: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var diskFree: Int64?
    var diskTotal: Int64?
    var download: Double?
    var upload: Double?
    var battery: Int?
    var timeToFullChargeMinutes: Int?
    var onAC = true
    var charging = false
}

final class SystemMonitor {
    private var previousCPU: CPUSample?
    private var previousNetwork: NetworkSample?

    func sample() -> SystemSnapshot {
        var value = SystemSnapshot()
        if let cpu = cpuSample() {
            value.cpu = previousCPU.flatMap { cpu.utilization(since: $0) }
            previousCPU = cpu
        }
        if let network = networkSample() {
            if let previousNetwork, let rates = network.rates(since: previousNetwork) {
                value.download = rates.down
                value.upload = rates.up
            }
            previousNetwork = network
        }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            if host_page_size(host, &pageSize) == KERN_SUCCESS {
                value.usedMemory = min(value.totalMemory,
                    Int64(UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * Int64(pageSize))
            }
        }
        if let disk = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            value.diskFree = (disk[.systemFreeSize] as? NSNumber)?.int64Value
            value.diskTotal = (disk[.systemSize] as? NSNumber)?.int64Value
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = details[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    value.battery = min(100, max(0, current * 100 / maximum))
                }
                value.onAC = details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                value.charging = details[kIOPSIsChargingKey] as? Bool ?? false
                if value.charging, let minutes = details[kIOPSTimeToFullChargeKey] as? Int, minutes >= 0 {
                    value.timeToFullChargeMinutes = minutes
                }
            }
        }
        return value
    }

    private func cpuSample() -> CPUSample? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUSample(user: load.cpu_ticks.0, system: load.cpu_ticks.1, idle: load.cpu_ticks.2, nice: load.cpu_ticks.3)
    }

    private func networkSample() -> NetworkSample? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var interfaces = Set<String>()
        while let pointer = current {
            let interface = pointer.pointee
            defer { current = interface.ifa_next }
            let name = String(cString: interface.ifa_name)
            // Only physical en interfaces; counting utun as well double-counts VPN traffic.
            guard name.hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(stats.ifi_ibytes)
            sent += UInt64(stats.ifi_obytes)
            interfaces.insert(name)
        }
        return NetworkSample(received: received, sent: sent, time: ContinuousTime.now, interfaces: interfaces)
    }
}

import AppKit
import Darwin
import Foundation

public enum MemoryPressure: String, Sendable {
  case normal
  case warning
  case critical
  case unknown
}

public struct SwapUsage: Sendable, Equatable {
  public let totalBytes: UInt64
  public let usedBytes: UInt64
  public let isAvailable: Bool

  public init(totalBytes: UInt64, usedBytes: UInt64, isAvailable: Bool = true) {
    self.totalBytes = totalBytes
    self.usedBytes = min(usedBytes, totalBytes)
    self.isAvailable = isAvailable
  }

  public static let unavailable = SwapUsage(totalBytes: 0, usedBytes: 0, isAvailable: false)
}

public struct MemoryBreakdown: Sendable, Equatable {
  public let activeBytes: UInt64
  public let inactiveBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let freeBytes: UInt64
  public let speculativeBytes: UInt64
  public let purgeableBytes: UInt64

  public init(
    pageSize: UInt64,
    activePages: UInt64,
    inactivePages: UInt64,
    wiredPages: UInt64,
    compressedPages: UInt64,
    freePages: UInt64,
    speculativePages: UInt64,
    purgeablePages: UInt64
  ) {
    activeBytes = Self.multiply(activePages, pageSize)
    inactiveBytes = Self.multiply(inactivePages, pageSize)
    wiredBytes = Self.multiply(wiredPages, pageSize)
    compressedBytes = Self.multiply(compressedPages, pageSize)
    freeBytes = Self.multiply(freePages, pageSize)
    speculativeBytes = Self.multiply(speculativePages, pageSize)
    purgeableBytes = Self.multiply(purgeablePages, pageSize)
  }

  /// Active, wired, and compressed counters. This approximation deliberately does not sum inactive,
  /// speculative, free, or purgeable counters because those categories are not guaranteed disjoint.
  public var approximateUsedBytes: UInt64 {
    Self.sum([activeBytes, wiredBytes, compressedBytes])
  }

  private static func multiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    return result.overflow ? .max : result.partialValue
  }

  private static func sum(_ values: [UInt64]) -> UInt64 {
    values.reduce(0) { partial, value in
      let result = partial.addingReportingOverflow(value)
      return result.overflow ? .max : result.partialValue
    }
  }
}

public struct MemoryApplication: Identifiable, Sendable, Equatable {
  public let pid: pid_t
  public let name: String
  public let bundleIdentifier: String?
  public let bundleURL: URL?
  public let launchDate: Date?
  public let footprintBytes: UInt64

  public var id: pid_t { pid }
}

public struct MemorySnapshot: Sendable, Equatable {
  public let date: Date
  public let physicalBytes: UInt64
  public let breakdown: MemoryBreakdown
  public let swap: SwapUsage
  public let pressure: MemoryPressure
  public let applications: [MemoryApplication]

  public init(
    date: Date,
    physicalBytes: UInt64,
    breakdown: MemoryBreakdown,
    swap: SwapUsage,
    pressure: MemoryPressure,
    applications: [MemoryApplication]
  ) {
    self.date = date
    self.physicalBytes = physicalBytes
    self.breakdown = breakdown
    self.swap = swap
    self.pressure = pressure
    self.applications = applications
  }

  public var approximateUsedBytes: UInt64 { min(physicalBytes, breakdown.approximateUsedBytes) }
}

public enum MemoryMonitorError: LocalizedError {
  case systemCall(String, kern_return_t)

  public var errorDescription: String? {
    switch self {
    case .systemCall(let name, let result):
      return "\(name) failed with system result \(result)."
    }
  }
}

public enum MemoryMonitor {
  public static func snapshot(includeApplications: Bool = true) throws -> MemorySnapshot {
    MemorySnapshot(
      date: Date(),
      physicalBytes: try physicalMemory(),
      breakdown: try breakdown(),
      swap: swapUsage(),
      pressure: memoryPressure(),
      applications: includeApplications ? applicationMemory() : []
    )
  }

  private static func physicalMemory() throws -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    let result = sysctlbyname("hw.memsize", &value, &size, nil, 0)
    guard result == 0 else {
      throw MemoryMonitorError.systemCall("hw.memsize", kern_return_t(errno))
    }
    return value
  }

  private static func breakdown() throws -> MemoryBreakdown {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      throw MemoryMonitorError.systemCall("host_statistics64", result)
    }

    return MemoryBreakdown(
      pageSize: UInt64(vm_kernel_page_size),
      activePages: UInt64(statistics.active_count),
      inactivePages: UInt64(statistics.inactive_count),
      wiredPages: UInt64(statistics.wire_count),
      compressedPages: UInt64(statistics.compressor_page_count),
      freePages: UInt64(statistics.free_count),
      speculativePages: UInt64(statistics.speculative_count),
      purgeablePages: UInt64(statistics.purgeable_count)
    )
  }

  private static func swapUsage() -> SwapUsage {
    var value = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &value, &size, nil, 0) == 0 else {
      return .unavailable
    }
    return SwapUsage(totalBytes: value.xsu_total, usedBytes: value.xsu_used)
  }

  private static func memoryPressure() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
      return .unknown
    }
    if level >= 4 { return .critical }
    if level >= 2 { return .warning }
    return .normal
  }

  /// Sums every same-user process whose executable lives inside a running app's bundle, so
  /// Chromium/Electron helpers (renderers, GPU, XPC services) count toward their parent app.
  private static func applicationMemory() -> [MemoryApplication] {
    let applications = NSWorkspace.shared.runningApplications.filter {
      $0.processIdentifier > 0 && $0.activationPolicy == .regular
        && !($0.localizedName ?? "").isEmpty && $0.bundleURL != nil
    }
    let bundles = applications.map { $0.bundleURL!.standardizedFileURL.path }
    var totals = [String: UInt64]()
    for pid in allProcessIDs() {
      guard let path = executablePath(pid), let bundle = owningBundle(of: path, in: bundles),
        let bytes = footprint(pid)
      else { continue }
      totals[bundle, default: 0] &+= bytes
    }
    var seen = Set<String>()
    return applications.compactMap { application -> MemoryApplication? in
      let bundle = application.bundleURL!.standardizedFileURL.path
      guard seen.insert(bundle).inserted,
        let bytes = totals[bundle] ?? footprint(application.processIdentifier)
      else { return nil }
      return MemoryApplication(
        pid: application.processIdentifier,
        name: application.localizedName!,
        bundleIdentifier: application.bundleIdentifier,
        bundleURL: application.bundleURL,
        launchDate: application.launchDate,
        footprintBytes: bytes
      )
    }.sorted {
      if $0.footprintBytes != $1.footprintBytes { return $0.footprintBytes > $1.footprintBytes }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// Outermost bundle containing `path`, so nested helper bundles resolve to the parent app.
  static func owningBundle(of path: String, in bundles: [String]) -> String? {
    bundles.filter { path.hasPrefix($0 + "/") }.min { $0.count < $1.count }
  }

  private static func allProcessIDs() -> [pid_t] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
    let count = pids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    return Array(pids.prefix(Int(max(0, count))))
  }

  private static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  private static func footprint(_ pid: pid_t) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
      }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
  }
}

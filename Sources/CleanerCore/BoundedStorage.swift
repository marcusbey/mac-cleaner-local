import Darwin
import Foundation

/// Containers can block inside the OS access broker. Isolate that work so the UI scan has a deadline.
enum BoundedStorage {
  static func containerBytes(_ url: URL, timeout: TimeInterval = 0.5) -> Int64 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-sk", "-P", url.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return -1 }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      if process.isRunning { process.terminate() }
      if finished.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
      return -1
    }
    guard process.terminationStatus == 0,
      let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
      let first = text.split(whereSeparator: { $0.isWhitespace }).first,
      let kib = Int64(first), kib <= Int64.max / 1024
    else { return -1 }
    return kib * 1024
  }
}

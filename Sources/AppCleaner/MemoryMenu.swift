import AppKit
import CleanerCore
import SwiftUI

@MainActor final class MemoryMenuModel: ObservableObject {
  /// One model for the whole app, started at launch so Auto mode works with no window open.
  static let shared = MemoryMenuModel()
  @Published var snapshot: MemorySnapshot?
  @Published var busy = false
  @Published var result: String = "Ready when you need it"
  @Published var lastRun: Date?
  @Published var silentReady = false
  @Published var pendingQuit: pid_t?
  @Published var openAtLogin: Bool {
    didSet {
      UserDefaults.standard.set(openAtLogin, forKey: "openAtLogin")
      applyLoginItem()
    }
  }
  @Published var autoClean: Bool {
    didSet {
      UserDefaults.standard.set(autoClean, forKey: "memoryAutoClean")
      policy.reset()
      if autoClean, !silentReady, !busy { enableSilent() }
    }
  }
  @Published var threshold: Double {
    didSet {
      UserDefaults.standard.set(threshold, forKey: "memoryAutoThreshold")
      policy.threshold = threshold
      policy.reset()
    }
  }
  private var policy: AutoCleanPolicy
  private var monitor: Task<Void, Never>?
  var percent: Double {
    guard let snapshot, snapshot.physicalBytes > 0 else { return 0 }
    return 100 * Double(snapshot.approximateUsedBytes) / Double(snapshot.physicalBytes)
  }
  init() {
    // First launch: start at login by default, as a menu-bar-only background app.
    openAtLogin = UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true
    autoClean = UserDefaults.standard.bool(forKey: "memoryAutoClean")
    let stored = UserDefaults.standard.double(forKey: "memoryAutoThreshold")
    let value = stored == 0 ? 85 : min(95, max(60, stored))
    threshold = value
    policy = AutoCleanPolicy(threshold: value)
  }
  func start() {
    guard monitor == nil else { return }
    monitor = Task { [weak self] in
      self?.silentReady = await Task.detached { QuickMemoryCleanup.canPurgeSilently() }.value
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        if self.snapshot != nil, !self.busy, self.silentReady,
          self.policy.shouldAttempt(percent: self.percent, enabled: self.autoClean, now: Date())
        {
          self.clean(interactive: false)
        }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }
  /// Keeps the login agent pointing at this copy of the app (it may have moved), or removes it.
  func applyLoginItem() {
    let agent = LoginAgent.standard
    do {
      if openAtLogin {
        if let executable = Bundle.main.executablePath, agent.installedExecutable != executable {
          try agent.install(executable: executable)
        }
      } else {
        try agent.remove()
      }
    } catch {
      result = "Could not update Open at login: \(error.localizedDescription)"
    }
  }

  func refresh() async {
    do {
      snapshot = try await Task.detached(priority: .utility) {
        try MemoryMonitor.snapshot(includeApplications: true)
      }.value
    } catch {
      snapshot = nil
      result = "Memory reading unavailable"
    }
  }
  func clean(interactive: Bool = true) {
    guard !busy else { return }
    busy = true
    result = "Freeing memory…"
    policy.recordAttempt(at: Date())
    Task {
      do {
        let outcome = try await Task.detached(priority: .userInitiated) {
          try QuickMemoryCleanup.run(interactive: interactive)
        }.value
        result = outcome.message
        if outcome.ran {
          let delta = Int64(clamping: outcome.afterFree) - Int64(clamping: outcome.beforeFree)
          result += " Free RAM \(delta >= 0 ? "+" : "−")\(size(abs(delta)))."
        }
        lastRun = Date()
      } catch { result = error.localizedDescription }
      busy = false
      await refresh()
    }
  }
  func enableSilent() {
    busy = true
    result = "Approve once to allow cleaning without a password…"
    Task {
      do {
        try await Task.detached { try QuickMemoryCleanup.enableSilentPurge() }.value
        silentReady = await Task.detached { QuickMemoryCleanup.canPurgeSilently() }.value
        result = silentReady ? "Password-free cleaning enabled." : "Setup did not take effect."
      } catch { result = error.localizedDescription }
      busy = false
      if !silentReady { autoClean = false }
    }
  }
  func disableSilent() {
    Task {
      do {
        try await Task.detached { try QuickMemoryCleanup.disableSilentPurge() }.value
        silentReady = false
        autoClean = false
        result = "Password-free cleaning removed."
      } catch { result = error.localizedDescription }
    }
  }
  func quit(_ application: MemoryApplication) {
    pendingQuit = nil
    if let problem = requestQuit(application) { result = problem }
    Task {
      try? await Task.sleep(for: .seconds(1))
      await refresh()
    }
  }
}

/// Sends a normal Quit request after re-checking the process is the one the user saw.
/// Returns a user-facing problem, or nil when the request was sent.
@MainActor func requestQuit(_ application: MemoryApplication) -> String? {
  guard application.pid != getpid(), application.bundleIdentifier != "com.apple.finder" else {
    return "App Cleaner does not offer Quit for itself or critical system applications."
  }
  guard let running = NSRunningApplication(processIdentifier: application.pid) else {
    return "\(application.name) is no longer running."
  }
  guard running.bundleIdentifier == application.bundleIdentifier,
    running.bundleURL?.standardizedFileURL == application.bundleURL?.standardizedFileURL,
    running.launchDate == application.launchDate
  else {
    return "\(application.name) restarted or changed since the list was refreshed. Try again."
  }
  return running.terminate() ? nil : "\(application.name) did not accept the Quit request."
}

struct MemoryMenuView: View {
  @ObservedObject var model: MemoryMenuModel
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Image(systemName: "memorychip").foregroundStyle(.cyan)
        Text("Memory Usage").font(.headline)
        Spacer()
        Text(model.snapshot == nil ? "—" : "\(Int(model.percent.rounded()))%").font(
          .system(size: 26, weight: .semibold, design: .rounded)
        ).foregroundStyle(pressureColor)
      }
      ProgressView(value: model.percent, total: 100).tint(pressureColor)
      if let snapshot = model.snapshot {
        Text(
          "\(size(Int64(clamping: snapshot.approximateUsedBytes))) used of \(size(Int64(clamping: snapshot.physicalBytes))) · \(pressureText)"
        ).font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      Text("Heavy applications").font(.subheadline.bold())
      ForEach(heavy) { application in heavyRow(application) }
      if heavy.isEmpty {
        Text("Reading running applications…").font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      Toggle("Automatically free up", isOn: $model.autoClean).toggleStyle(.switch)
        .disabled(model.busy)
      HStack {
        Text("When usage reaches").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(Int(model.threshold))%").font(.caption.bold()).monospacedDigit()
      }
      Slider(value: $model.threshold, in: 60...95, step: 5).disabled(!model.autoClean)
      Button {
        model.clean()
      } label: {
        HStack {
          if model.busy { ProgressView().controlSize(.small) }
          Text(model.busy ? "Working…" : "Free up memory").fontWeight(.semibold)
        }.padding(.vertical, 7).frame(maxWidth: .infinity)
      }.buttonStyle(.borderedProminent).tint(.blue).disabled(model.busy)
      Text(model.result).font(.caption).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      if let date = model.lastRun {
        Text("Last cleaned \(date.formatted(date: .omitted, time: .shortened))").font(.caption2)
          .foregroundStyle(.secondary)
      }
      Text(
        model.silentReady
          ? "Flushes macOS file cache without a password. Never closes apps. Quit a heavy app above for bigger gains."
          : "Flushes macOS file cache (asks for your admin password). Auto mode needs one-time approval."
      ).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle("Open at login (runs in the menu bar)", isOn: $model.openAtLogin)
        .toggleStyle(.switch).font(.caption)
      Divider()
      HStack {
        Button("Open App Cleaner") {
          openWindow(id: "main")
          NSApp.activate(ignoringOtherApps: true)
        }
        Spacer()
        if model.silentReady {
          Button("Require password") { model.disableSilent() }.foregroundStyle(.secondary)
        }
        Button("Quit Completely") {
          CleanerApplicationDelegate.allowQuit = true
          NSApp.terminate(nil)
        }.foregroundStyle(.secondary)
          .help("Stops background monitoring and Auto mode until you open the app again")
      }.buttonStyle(.plain).font(.caption)
    }.padding(20).frame(width: 340).preferredColorScheme(.dark).background(navy)
  }
  var heavy: [MemoryApplication] { Array(model.snapshot?.applications.prefix(5) ?? []) }
  func heavyRow(_ application: MemoryApplication) -> some View {
    HStack(spacing: 8) {
      if let url = application.bundleURL {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(
          width: 18, height: 18)
      }
      Text(application.name).lineLimit(1)
      Spacer()
      Text(size(Int64(clamping: application.footprintBytes))).monospacedDigit()
        .foregroundStyle(.secondary)
      if model.pendingQuit == application.pid {
        Button("Confirm") { model.quit(application) }.tint(.red)
        Button("Cancel") { model.pendingQuit = nil }
      } else {
        Button("Quit") { model.pendingQuit = application.pid }
          .disabled(application.pid == getpid() || application.bundleIdentifier == "com.apple.finder")
      }
    }.font(.callout).controlSize(.small)
  }
  var pressureText: String {
    switch model.snapshot?.pressure {
    case .normal: "Normal pressure"
    case .warning: "Elevated pressure"
    case .critical: "Critical pressure"
    default: "Pressure unavailable"
    }
  }
  var pressureColor: Color {
    switch model.snapshot?.pressure {
    case .normal: .green
    case .warning: .orange
    case .critical: .red
    default: .gray
    }
  }
}

final class CleanerApplicationDelegate: NSObject, NSApplicationDelegate {
  /// Set by Quit Completely and by logout/shutdown; ⌘Q otherwise only hides to the menu bar.
  nonisolated(unsafe) static var allowQuit = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      MemoryMenuModel.shared.start()
      MemoryMenuModel.shared.applyLoginItem()
    }
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        // After the window state settles, show the Dock icon only while a real window is open.
        DispatchQueue.main.async { Self.updateActivationPolicy() }
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { _ in Self.allowQuit = true }
    if CommandLine.arguments.contains(LoginAgent.backgroundArgument) {
      NSApp.setActivationPolicy(.accessory)
      // shortcut: SwiftUI opens its first window a moment after launch with no hook to suppress it
      // on macOS 14, so keep closing it for the first seconds; upgrade to .defaultLaunchBehavior(.suppressed) at macOS 15+.
      for delay in [0.0, 0.3, 0.8, 1.5, 3.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          for window in Self.appWindows { window.close() }
          NSApp.setActivationPolicy(.accessory)
        }
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let reason = NSAppleEventManager.shared().currentAppleEvent?
      .attributeDescriptor(forKeyword: kAEQuitReason)
    if Self.allowQuit || reason != nil { return .terminateNow }
    // ⌘Q or Dock Quit: keep monitoring memory in the menu bar.
    for window in Self.appWindows { window.close() }
    NSApp.setActivationPolicy(.accessory)
    return .terminateCancel
  }

  private static var appWindows: [NSWindow] {
    NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
  }

  private static func updateActivationPolicy() {
    let wanted: NSApplication.ActivationPolicy = appWindows.isEmpty ? .accessory : .regular
    guard NSApp.activationPolicy() != wanted else { return }
    NSApp.setActivationPolicy(wanted)
    if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
  }
}

struct QuickMemoryCommands:Commands {
  @Environment(\.openWindow) private var openWindow
  var body:some Commands {
    CommandGroup(after:.windowArrangement) {
      Button("Quick Memory Clean") {openWindow(id:"quickMemory")}
        .keyboardShortcut("m",modifiers:[.command,.shift])
    }
  }
}

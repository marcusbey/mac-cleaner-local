import AppKit
import CleanerCore
import SwiftUI

struct MemoryView: View {
  @ObservedObject var memoryMenu: MemoryMenuModel
  @State private var snapshot: MemorySnapshot?
  @State private var errorMessage: String?
  @State private var search = ""
  @State private var pendingQuit: MemoryApplication?
  @State private var refreshing = false

  private var visibleApplications: [MemoryApplication] {
    guard let applications = snapshot?.applications else { return [] }
    guard !search.isEmpty else { return applications }
    return applications.filter {
      $0.name.localizedCaseInsensitiveContains(search)
        || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text("Memory").font(.largeTitle.bold())
          Text("Live macOS memory pressure and application footprints").foregroundStyle(.secondary)
        }
        Spacer()
        pressureBadge
        Button("Refresh") { Task { await refresh() } }.disabled(refreshing)
        Button(memoryMenu.busy ? "Working…" : "Free up memory") { memoryMenu.clean() }
          .buttonStyle(.borderedProminent).disabled(memoryMenu.busy)
      }
      if memoryMenu.lastRun != nil || memoryMenu.busy {
        Text(memoryMenu.result).font(.callout).foregroundStyle(.secondary)
      }

      if let snapshot {
        overview(snapshot)
        Text(
          "These are raw macOS VM counters and may overlap. Inactive memory can contain useful cached or recently used pages; it is not automatically waste."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
        }

        HStack {
          Image(systemName: "magnifyingglass")
          TextField("Search running applications", text: $search).textFieldStyle(.plain)
        }
        .padding(12)
        .background(panel, in: RoundedRectangle(cornerRadius: 10))

        HStack {
          Text("Running applications").font(.title3.bold())
          Spacer()
          Text("Physical footprint").font(.caption).foregroundStyle(.secondary)
        }
        applicationList
      } else if refreshing {
        Spacer()
        ProgressView("Reading memory statistics…").frame(maxWidth: .infinity)
        Spacer()
      } else {
        Spacer()
        ContentUnavailableView(
          "Memory statistics unavailable",
          systemImage: "memorychip",
          description: Text(errorMessage ?? "Refresh to try again."))
        Spacer()
      }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(3))
      }
    }
    .alert(item: $pendingQuit) { application in
      Alert(
        title: Text("Quit \(application.name)?"),
        message: Text(
          "This sends the application's normal Quit request. Unsaved work can still be lost if the app does not prompt before closing."
        ),
        primaryButton: .destructive(Text("Quit")) { quit(application) },
        secondaryButton: .cancel()
      )
    }
  }

  @ViewBuilder private var pressureBadge: some View {
    if let pressure = snapshot?.pressure {
      HStack(spacing: 6) {
        Circle().fill(pressureColor(pressure)).frame(width: 9, height: 9)
        Text(pressureTitle(pressure)).font(.callout.bold())
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(panel, in: Capsule())
    }
  }

  private func overview(_ snapshot: MemorySnapshot) -> some View {
    VStack(spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text(size(Int64(clamping: snapshot.approximateUsedBytes))).font(
          .system(size: 38, weight: .bold))
        Text("active + wired + compressed of \(size(Int64(clamping: snapshot.physicalBytes)))")
          .foregroundStyle(.secondary)
        Spacer()
        VStack(alignment: .trailing) {
          if snapshot.swap.isAvailable {
            Text("Swap \(size(Int64(clamping: snapshot.swap.usedBytes)))")
            Text("of \(size(Int64(clamping: snapshot.swap.totalBytes)))")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Text("Swap unavailable").foregroundStyle(.secondary)
          }
        }
      }
      GeometryReader { geometry in
        let fraction =
          snapshot.physicalBytes == 0
          ? 0 : min(1, Double(snapshot.approximateUsedBytes) / Double(snapshot.physicalBytes))
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.08))
          Capsule().fill(pressureColor(snapshot.pressure)).frame(
            width: geometry.size.width * fraction)
        }
      }.frame(height: 12)
      HStack(spacing: 10) {
        metric("Active", snapshot.breakdown.activeBytes, .blue)
        metric("Wired", snapshot.breakdown.wiredBytes, .purple)
        metric("Compressed", snapshot.breakdown.compressedBytes, .orange)
        metric("Inactive", snapshot.breakdown.inactiveBytes, .teal)
        metric("Free", snapshot.breakdown.freeBytes, .green)
      }
    }
    .padding(20)
    .background(panel, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(line))
  }

  private func metric(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(title).font(.caption).foregroundStyle(.secondary)
      }
      Text(size(Int64(clamping: bytes))).font(.callout.bold()).monospacedDigit()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }

  private var applicationList: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        ForEach(visibleApplications) { application in
          HStack(spacing: 12) {
            appIcon(application)
            VStack(alignment: .leading, spacing: 4) {
              Text(application.name).font(.headline)
              Text(application.bundleIdentifier ?? "Process \(application.pid)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(size(Int64(clamping: application.footprintBytes))).monospacedDigit()
            Button("Quit") { pendingQuit = application }
              .disabled(application.pid == getpid() || application.bundleIdentifier == "com.apple.finder")
          }
          .padding(14)
          .background(panel, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
        }
      }
    }
  }

  @ViewBuilder private func appIcon(_ application: MemoryApplication) -> some View {
    if let url = application.bundleURL {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable().frame(width: 36, height: 36)
    } else {
      Image(systemName: "app").font(.title2).frame(width: 36, height: 36)
    }
  }

  @MainActor private func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    let result = await Task.detached(priority: .utility) {
      Result { try MemoryMonitor.snapshot() }
    }.value
    refreshing = false
    guard !Task.isCancelled else { return }
    switch result {
    case .success(let value):
      snapshot = value
      errorMessage = nil
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  private func quit(_ application: MemoryApplication) {
    errorMessage = requestQuit(application)
    Task {
      try? await Task.sleep(for: .milliseconds(500))
      await refresh()
    }
  }

  private func pressureTitle(_ pressure: MemoryPressure) -> String {
    switch pressure {
    case .normal: "Normal pressure"
    case .warning: "Elevated pressure"
    case .critical: "Critical pressure"
    case .unknown: "Pressure unavailable"
    }
  }

  private func pressureColor(_ pressure: MemoryPressure) -> Color {
    switch pressure {
    case .normal: .green
    case .warning: .orange
    case .critical: .red
    case .unknown: .secondary
    }
  }
}

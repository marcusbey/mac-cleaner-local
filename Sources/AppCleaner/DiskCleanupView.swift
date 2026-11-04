import AppKit
import CleanerCore
import SwiftUI

@MainActor private final class DiskCleanupModel: ObservableObject {
  @Published var volume: DiskVolumeUsage?
  @Published var candidates: [DiskCleanupCandidate] = []
  @Published var ratings: [String: DiskCleanupSafety] = [:]
  @Published var issues: [DiskScanIssue] = []
  @Published var scanning = false
  @Published var cancelled = false
  @Published var truncated = false
  @Published var message = ""
  @Published var downloadsFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Downloads", isDirectory: true)
  private var task: Task<Void, Never>?

  func dropMissing(_ ids: [String]) {
    let gone = Set(ids.filter { !FileManager.default.fileExists(atPath: $0) })
    candidates.removeAll { gone.contains($0.id) }
  }

  func rating(_ candidate: DiskCleanupCandidate) -> DiskCleanupSafety {
    ratings[candidate.id] ?? DiskCleanupSafety.assess(candidate)
  }

  func refreshVolume() {
    volume = try? DiskVolumeUsage.read()
  }

  func scanJunk() {
    beginScan {
      DiskCleanupScanner.scanJunk()
    }
  }

  func scanDownloads() {
    let folder = downloadsFolder
    beginScan {
      DiskCleanupScanner.scanLargeFiles(folder: folder)
    }
  }

  func cancel() {
    task?.cancel()
  }

  func remove(_ selected: [DiskCleanupCandidate]) async -> Result<DiskCleanupTrashOutcome, Error> {
    let roots = Array(Set(selected.map(\.scopeRoot)))
    let result = await Task.detached(priority: .userInitiated) {
      Result { try DiskCleanupTrashService.moveToTrash(selected, allowedRoots: roots) }
    }.value
    refreshVolume()
    return result
  }

  private func beginScan(
    operation: @escaping @Sendable () -> DiskScanResult
  ) {
    task?.cancel()
    scanning = true
    candidates = []
    issues = []
    cancelled = false
    truncated = false
    task = Task {
      let worker = Task.detached(priority: .utility, operation: operation)
      let result = await withTaskCancellationHandler(
        operation: { await worker.value },
        onCancel: { worker.cancel() }
      )
      guard !Task.isCancelled else {
        scanning = false
        cancelled = true
        return
      }
      let found = result.candidates
      ratings = await Task.detached(priority: .utility) {
        let installed = DiskCleanupSafety.installedAppKeys()
        return Dictionary(
          uniqueKeysWithValues: found.map {
            ($0.id, DiskCleanupSafety.assess($0, installedApps: installed))
          })
      }.value
      candidates = found
      issues = result.errors
      cancelled = result.cancelled
      truncated = result.truncated
      scanning = false
      refreshVolume()
    }
  }
}

struct DiskCleanupView: View {
  @StateObject private var model = DiskCleanupModel()
  @State private var selected: Set<String> = []
  @State private var review = false
  @State private var removing = false

  private var chosen: [DiskCleanupCandidate] {
    model.candidates.filter { selected.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 7) {
          Text("Disk Cleanup").font(.largeTitle.bold())
          Text("Review caches, logs, and large Downloads files before moving anything to Trash.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.scanning {
          Button("Cancel", action: model.cancel)
        }
      }

      if let volume = model.volume {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Startup disk").font(.headline)
            Spacer()
            Text("\(size(volume.availableBytes)) available of \(size(volume.totalBytes))")
              .foregroundStyle(.secondary)
          }
          ProgressView(value: Double(volume.usedBytes), total: Double(max(1, volume.totalBytes)))
            .tint(.cyan)
        }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(line))
      }

      HStack(spacing: 12) {
        Button("Scan Caches & Logs", action: model.scanJunk).buttonStyle(.borderedProminent)
          .disabled(model.scanning || removing)
        Button("Scan Large Downloads", action: model.scanDownloads)
          .disabled(model.scanning || removing)
        Button("Choose Downloads Folder…", action: chooseFolder)
          .disabled(model.scanning || removing)
        Spacer()
        Text(model.downloadsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }

      Text(
        "Nothing is selected automatically. Cache and log folders may still be useful to their applications. Large Downloads are your documents; inspect every path before removal."
      ).font(.callout).foregroundStyle(.secondary)

      if model.scanning {
        Spacer()
        ProgressView("Scanning approved folders…").frame(maxWidth: .infinity)
        Spacer()
      } else if model.candidates.isEmpty {
        Spacer()
        ContentUnavailableView(
          model.cancelled ? "Scan cancelled" : "Choose a scan",
          systemImage: model.cancelled ? "xmark.circle" : "externaldrive",
          description: Text("Only the folders named above are inspected."))
        Spacer()
      } else {
        HStack {
          Text(
            "\(model.candidates.count) items · \(size(model.candidates.reduce(0) { $0 + $1.bytes }))"
          )
          .font(.headline)
          if model.truncated {
            Text("Some entries were skipped").font(.caption).foregroundStyle(.orange)
          }
          safetySummary
          Spacer()
          Button("Select safe items") {
            let safe = model.candidates.filter { model.rating($0).level == .safe }
            selected = Set(safe.map(\.id))
          }.help("Selects only items rated Safe")
          Button("Select all visible") { selected = Set(model.candidates.map(\.id)) }
          Button("Deselect All") { selected = [] }.disabled(selected.isEmpty)
        }
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(model.candidates) { candidate in
              candidateRow(candidate)
            }
          }
        }
      }

      if !model.issues.isEmpty {
        DisclosureGroup("\(model.issues.count) folders could not be scanned") {
          ForEach(model.issues) { issue in
            Text("\(issue.path): \(issue.message)").font(.caption).foregroundStyle(.orange)
              .textSelection(.enabled)
          }
        }
      }

      Divider()
      HStack {
        Text("\(chosen.count) selected · \(size(chosen.reduce(0) { $0 + $1.bytes }))")
          .foregroundStyle(.secondary)
        Spacer()
        Button(chosen.isEmpty ? "Clean Selected…" : "Clean \(chosen.count) Selected…") { review = true }.buttonStyle(.borderedProminent)
          .disabled(chosen.isEmpty || model.scanning || removing)
      }
    }.padding(28).frame(maxWidth: .infinity)
      .task { model.refreshVolume() }
      .onChange(of: model.candidates.map(\.id)) { _, ids in selected.formIntersection(ids) }
      .alert(
        "Disk Cleanup",
        isPresented: Binding(
          get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })
      ) {
        Button("OK") { model.message = "" }
      } message: {
        Text(model.message)
      }
      .sheet(isPresented: $review) { reviewSheet }
  }

  private func candidateRow(_ candidate: DiskCleanupCandidate) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        "Select \(candidate.url.lastPathComponent)",
        isOn: Binding(
          get: { selected.contains(candidate.id) },
          set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })
      ).labelsHidden().toggleStyle(.checkbox)
      Image(systemName: candidate.category == .largeDownload ? "doc" : "folder")
        .font(.title3).foregroundStyle(.cyan)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(candidate.url.lastPathComponent).font(.headline)
          Text(candidate.category.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        let safety = model.rating(candidate)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          SafetyBadge(level: safety.level)
          Text(safety.note).font(.caption).foregroundStyle(.secondary)
        }
        Text(candidate.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let modified = candidate.modified {
          Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(size(candidate.bytes)).monospacedDigit()
      Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
    }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(selected.contains(candidate.id) ? .blue : line))
  }

  private var safetySummary: some View {
    let levels: [DiskCleanupSafety.Level] = model.candidates.map { model.rating($0).level }
    return HStack(spacing: 10) {
      ForEach([DiskCleanupSafety.Level.safe, .likelySafe, .review], id: \.self) { level in
        let count = levels.filter { $0 == level }.count
        if count > 0 { SafetyBadge(level: level, count: count) }
      }
    }
  }

  private var reviewSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Review disk cleanup").font(.title2.bold())
      Text(
        "Move \(chosen.count) selected items (\(size(chosen.reduce(0) { $0 + $1.bytes }))) to Trash?"
      )
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(chosen) { candidate in
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.url.lastPathComponent).bold()
              Text(candidate.url.path).font(.caption).foregroundStyle(.secondary).textSelection(
                .enabled)
            }
          }
        }
      }.frame(minHeight: 120, maxHeight: 350)
      Text(
        "File identity and running application ownership are checked again. Items remain recoverable in Trash."
      )
      .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Cancel") { review = false }.keyboardShortcut(.cancelAction).disabled(removing)
        Spacer()
        if removing { ProgressView().controlSize(.small) }
        Button("Move to Trash", role: .destructive, action: remove)
          .buttonStyle(.borderedProminent).tint(.red).disabled(removing)
      }
    }.padding(28).frame(width: 680).interactiveDismissDisabled(removing)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.downloadsFolder
    if panel.runModal() == .OK, let url = panel.url {
      model.downloadsFolder = url
      selected = []
    }
  }

  private func remove() {
    removing = true
    let values = chosen
    Task {
      let result = await model.remove(values)
      removing = false
      review = false
      selected = []
      switch result {
      case .success(let outcome):
        model.message = "Moved \(outcome.moved.count) item(s) to Trash."
        if !outcome.skipped.isEmpty {
          model.message +=
            "\n\nSkipped \(outcome.skipped.count):\n"
            + outcome.skipped.prefix(5).map { "• \($0.url.lastPathComponent): \($0.reason)" }
            .joined(separator: "\n")
            + (outcome.skipped.count > 5 ? "\n…and \(outcome.skipped.count - 5) more" : "")
        }
        // Drop only the rows that left disk instead of rescanning, so the list keeps its scroll position.
        model.dropMissing(values.map(\.id))
      case .failure(let error): model.message = error.localizedDescription
      }
    }
  }
}

struct SafetyBadge: View {
  let level: DiskCleanupSafety.Level
  var count: Int?
  var body: some View {
    Label {
      Text(count.map { "\($0) \(title)" } ?? title)
    } icon: {
      Image(systemName: icon)
    }
    .font(.caption.bold()).foregroundStyle(color)
    .padding(.horizontal, 7).padding(.vertical, 2)
    .background(color.opacity(0.15), in: Capsule())
    .fixedSize()
  }
  private var title: String {
    switch level {
    case .safe: "Safe"
    case .likelySafe: "Likely safe"
    case .review: "Review"
    }
  }
  private var icon: String {
    switch level {
    case .safe: "checkmark.shield.fill"
    case .likelySafe: "checkmark.circle"
    case .review: "exclamationmark.triangle.fill"
    }
  }
  private var color: Color {
    switch level {
    case .safe: .green
    case .likelySafe: .yellow
    case .review: .orange
    }
  }
}

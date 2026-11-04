import AppKit
import CleanerCore
import SwiftUI

@MainActor final class CleanerModel: ObservableObject {
  @Published var apps: [AppRecord] = []
  @Published var selected: AppRecord?
  @Published var selectedGroup: VendorGroup?
  @Published var files: [RelatedFile] = []
  @Published var scanning = false
  @Published var loadingFiles = false
  @Published var message = ""
  @Published var reviewSelection: UninstallSelection?
  @Published var remaining: [RemainingFile] = []
  @Published var scanningRemaining = false
  @Published var remainingScanned = false
  @Published var updates: [UpdateResult] = []
  @Published var checkingUpdates = false
  @Published var checkedAt: Date?
  private var remainingGeneration = UUID()
  private var selectionGeneration = UUID()
  private var updateTask: Task<Void, Never>?
  func scan() {
    guard !scanning else { return }
    scanning = true
    remainingGeneration = UUID()
    scanningRemaining = false
    remaining = []
    remainingScanned = false
    updates = []
    checkedAt = nil
    updateTask?.cancel()
    checkingUpdates = false
    Task {
      let inventory = await Task.detached(priority: .utility) { AppScanner.scan(measureSizes:false) }.value
      apps = inventory
      let result = await Task.detached(priority: .utility) {
        AppScanner.scan(includeRelatedSizes: true)
      }.value
      apps = result
      scanning = false
      if let group = selectedGroup,
        let fresh = VendorGrouping.groups(for: result).first(where: {
          $0.id == group.id && $0.isGroup
        })
      {
        select(fresh)
      } else if let previous = selected, let fresh = result.first(where: { $0.id == previous.id }) {
        select(fresh)
      } else if let first = result.sorted(by: {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }).first {
        select(first)
      } else {
        selected = nil
        selectedGroup = nil
        files = []
      }
    }
  }
  func select(_ app: AppRecord) {
    selected = app
    selectedGroup = nil
    files = []
    loadingFiles = true
    let generation = UUID()
    selectionGeneration = generation
    Task {
      let found = await Task.detached(priority: .utility) { AppScanner.relatedFiles(for: app) }
        .value
      guard self.selectionGeneration == generation else { return }
      files = found
      loadingFiles = false
    }
  }
  func select(_ group: VendorGroup) {
    selectionGeneration = UUID()
    selectedGroup = group
    selected = nil
    files = []
    loadingFiles = false
  }
  func prepareReview(_ selectedApps: [AppRecord]) {
    guard !loadingFiles else { return }
    loadingFiles = true
    let installed = apps
    Task {
      let plan = await Task.detached(priority: .utility) {
        BatchUninstall.review(apps: selectedApps, installed: installed)
      }.value
      reviewSelection = plan
      loadingFiles = false
    }
  }
  func scanRemaining() {
    guard !scanning, !scanningRemaining else { return }
    scanningRemaining = true
    remaining = []
    let generation = UUID()
    remainingGeneration = generation
    let installed = apps
    Task {
      let result = await Task.detached(priority: .utility) {
        RemainingScanner.scan(installedApps: installed)
      }.value
      guard generation == remainingGeneration else { return }
      remaining = result
      remainingScanned = true
      scanningRemaining = false
    }
  }
  func checkUpdates() {
    guard !scanning, !checkingUpdates else { return }
    checkingUpdates = true
    updates = []
    checkedAt = nil
    let installed = apps
    updateTask = Task {
      let result = await UpdateService().check(apps: installed)
      guard !Task.isCancelled else { return }
      updates = result
      checkedAt = Date()
      checkingUpdates = false
    }
  }
  func cancelUpdates() {
    updateTask?.cancel()
    checkingUpdates = false
  }
}

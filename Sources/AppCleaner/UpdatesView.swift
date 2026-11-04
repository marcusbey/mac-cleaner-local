import AppKit
import CleanerCore
import SwiftUI

struct UpdatesView: View {
  @ObservedObject var model: CleanerModel
  @State private var query = ""
  @State private var showAll = false
  var available: [UpdateResult] { model.updates.filter { $0.status == .updateAvailable } }
  var visible: [UpdateResult] {
    model.updates.filter {
      (showAll || $0.status == .updateAvailable)
        && (query.isEmpty || $0.appName.localizedCaseInsensitiveContains(query))
    }.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("Updates").font(.largeTitle.bold())
          Text("App Store and developer appcast updates").foregroundStyle(.secondary)
        }
        Spacer()
        if model.checkingUpdates { Button("Cancel", action: model.cancelUpdates) }
        Button("Check for Updates", action: model.checkUpdates).buttonStyle(.borderedProminent)
          .disabled(model.scanning || model.checkingUpdates)
      }
      Text(
        "Checks contact the update feed declared by each app, or Apple for App Store apps. Use Open Update to complete installation through the publisher or App Store."
      ).font(.callout).foregroundStyle(.secondary)
      HStack {
        Image(systemName: "magnifyingglass")
        TextField("Search updates", text: $query).textFieldStyle(.plain)
        Toggle("Show all results", isOn: $showAll).toggleStyle(.checkbox)
      }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
      if model.checkingUpdates {
        Spacer()
        ProgressView("Checking supported applications…").frame(maxWidth: .infinity)
        Text(
          "Unsupported apps are reported separately; network failures are never marked up to date."
        ).font(.caption).foregroundStyle(.secondary)
        Spacer()
      } else if let date = model.checkedAt {
        Text(
          "\(available.count) updates · \(model.updates.filter {$0.status == .current}.count) current · \(model.updates.filter {$0.status == .unsupported}.count) unsupported · \(model.updates.filter {$0.status == .failed}.count) failed"
        ).font(.headline)
        Text("Checked \(date.formatted(date:.omitted,time:.shortened))").font(.caption)
          .foregroundStyle(.secondary)
        if visible.isEmpty {
          ContentUnavailableView(
            "No matching updates", systemImage: "checkmark.circle",
            description: Text(
              "Enable Show all results to inspect unsupported apps and failed checks."))
        }
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(visible) { result in
              HStack(spacing: 14) {
                if let app = model.apps.first(where: { $0.id == result.appID }) {
                  Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(
                    width: 42, height: 42)
                }
                VStack(alignment: .leading, spacing: 6) {
                  Text(result.appName).font(.headline)
                  Text(
                    "Installed \(result.installedVersion)\(result.latestVersion.map {" → \($0)"} ?? "")"
                  ).font(.callout)
                  Text(result.detail).font(.caption).foregroundStyle(.secondary).textSelection(
                    .enabled)
                }
                Spacer()
                Text(statusLabel(result.status)).font(.caption).foregroundStyle(
                  result.status == .updateAvailable ? Color.cyan : Color.secondary)
                if result.status == .updateAvailable, let url = result.actionURL {
                  Button("Open Update") { NSWorkspace.shared.open(url) }.buttonStyle(
                    .borderedProminent)
                }
              }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 12)).overlay(
                RoundedRectangle(cornerRadius: 12).stroke(line))
            }
          }
        }
      } else {
        Spacer()
        ContentUnavailableView(
          "Check your applications", systemImage: "arrow.triangle.2.circlepath",
          description: Text(
            model.scanning
              ? "Application inventory is still loading."
              : "Start a check to compare installed versions with supported publishers."))
        Spacer()
      }
      HStack {
        Button("Open App Store") {
          NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
        }
        Button("macOS Software Update") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
        }
        Spacer()
      }
    }.padding(28).frame(maxWidth: .infinity)
  }
  func statusLabel(_ status: UpdateStatus) -> String {
    switch status {
    case .updateAvailable: "Update available"
    case .current: "Up to date"
    case .unsupported: "Not supported"
    case .failed: "Check failed"
    }
  }
}

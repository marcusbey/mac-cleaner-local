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
          Text("App Updates").font(.largeTitle.bold())
          Text("Finds newer versions of the apps installed on this Mac.").foregroundStyle(.secondary)
        }
        Spacer()
        if model.checkingUpdates { Button("Cancel", action: model.cancelUpdates) }
        Button("Check for Updates", action: model.checkUpdates).buttonStyle(.borderedProminent)
          .disabled(model.scanning || model.checkingUpdates)
      }
      InfoCard(
        symbol: "questionmark.circle",
        title: "How it works",
        text:
          "Each app is checked against its own update source: the developer's update feed (Sparkle), the App Store, or its Electron release feed. Open Update takes you to the download or App Store page; this app never installs anything itself. Apps without a public update source show as Not supported.")
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
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          Text("\(available.count) update\(available.count == 1 ? "" : "s") available").font(.headline)
          Text("\(model.updates.filter {$0.status == .current}.count) up to date · \(model.updates.filter {$0.status == .unsupported}.count) not supported · \(model.updates.filter {$0.status == .failed}.count) failed")
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          Text("Checked \(date.formatted(date:.omitted,time:.shortened))").font(.caption)
            .foregroundStyle(.secondary)
        }
        if visible.isEmpty {
          ContentUnavailableView(
            "No matching updates", systemImage: "checkmark.circle",
            description: Text(
              "Enable Show all results to inspect unsupported apps and failed checks."))
        }
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(visible) { result in
              HStack(alignment: .center, spacing: 14) {
                Group {
                  if let app = model.apps.first(where: { $0.id == result.appID }) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable()
                  } else {
                    Image(systemName: "app.dashed").font(.system(size: 26)).foregroundStyle(.secondary)
                  }
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                  Text(result.appName).font(.headline).lineLimit(1)
                  Text(
                    "Installed \(result.installedVersion)\(result.latestVersion.map {" → \($0)"} ?? "")"
                  ).font(.callout).monospacedDigit()
                  if !result.detail.isEmpty {
                    Text(result.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                      .textSelection(.enabled)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
                statusPill(result.status).frame(width: 130, alignment: .trailing)
                Group {
                  if result.status == .updateAvailable, let url = result.actionURL {
                    Button("Open Update") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent)
                  } else {
                    Color.clear
                  }
                }.frame(width: 118, height: 28, alignment: .trailing)
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
  func statusPill(_ status: UpdateStatus) -> some View {
    let color: Color =
      switch status {
      case .updateAvailable: .cyan
      case .current: .green
      case .unsupported: .secondary
      case .failed: .orange
      }
    return Text(statusLabel(status)).font(.caption.bold()).foregroundStyle(color)
      .padding(.horizontal, 9).padding(.vertical, 4)
      .background(color.opacity(0.14), in: Capsule()).fixedSize()
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

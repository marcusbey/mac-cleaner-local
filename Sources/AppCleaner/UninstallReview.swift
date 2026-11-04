import CleanerCore
import SwiftUI

struct UninstallReview: View {
  let selection: UninstallSelection
  let installed: [AppRecord]
  let onClose: () -> Void
  let onFinished: (String) -> Void
  @State private var appIDs: Set<String> = []
  @State private var fileIDs: Set<String> = []
  @State private var candidates: [RelatedFile] = []
  @State private var protectedIDs: [String] = []
  @State private var busy = false
  @State private var refreshing = false
  var selectedApps: [AppRecord] { selection.apps.filter { appIDs.contains($0.id) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Review uninstall").font(.title2.bold())
      Text("\(selectedApps.count) applications · \(fileIDs.count) related items selected")
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(selection.apps) { app in
            Toggle(
              isOn: Binding(
                get: { appIDs.contains(app.id) },
                set: {
                  if $0 { appIDs.insert(app.id) } else { appIDs.remove(app.id) }
                  refreshFiles()
                })
            ) {
              VStack(alignment: .leading) {
                Text(app.name).bold()
                Text(app.url.path).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          Divider()
          Text("Related files").font(.headline)
          if refreshing { ProgressView("Refreshing selection…") }
          ForEach(candidates) { file in
            Toggle(
              isOn: Binding(
                get: { fileIDs.contains(file.id) },
                set: { if $0 { fileIDs.insert(file.id) } else { fileIDs.remove(file.id) } })
            ) {
              VStack(alignment: .leading) {
                Text("\(file.category) · \(size(file.bytes))")
                Text(file.url.path).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          if candidates.isEmpty && !refreshing {
            Text("No removable related files matched.").foregroundStyle(.secondary)
          }
          if !protectedIDs.isEmpty {
            Text(
              "Data preserved for another installed copy: \(protectedIDs.joined(separator:", "))"
            ).font(.caption).foregroundStyle(.orange)
          }
        }.padding(4)
      }.frame(minHeight: 120, maxHeight: 400).disabled(busy || refreshing)
      Text(
        "Quit selected apps first. Items move to Trash and can be restored. Shared vendor folders are preserved."
      ).font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction).disabled(busy)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button("Move to Trash", role: .destructive, action: remove).buttonStyle(.borderedProminent)
          .tint(.red).disabled(busy || refreshing || appIDs.isEmpty)
      }
    }.padding(28).frame(width: 650).interactiveDismissDisabled(busy)
      .onAppear {
        appIDs = Set(selection.apps.map(\.id))
        candidates = selection.files
        fileIDs = Set(selection.files.map(\.id))
        protectedIDs = selection.preservedSharedIDs
      }
  }
  func refreshFiles() {
    let requested = appIDs
    let apps = selectedApps
    refreshing = true
    Task {
      let result = await Task.detached(priority: .utility) {
        BatchUninstall.review(apps: apps, installed: installed)
      }.value
      guard requested == appIDs else { return }
      candidates = result.files
      fileIDs = Set(result.files.map(\.id))
      protectedIDs = result.preservedSharedIDs
      refreshing = false
    }
  }
  func remove() {
    busy = true
    let apps = selectedApps
    let files = candidates.filter { fileIDs.contains($0.id) }
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { try BatchUninstall.moveToTrash(apps: apps, files: files) }
      }.value
      busy = false
      switch result {
      case .success(let urls):
        onFinished("Moved \(urls.count) items to Trash. Restore them from Trash if needed.")
      case .failure(let error): onFinished(error.localizedDescription)
      }
    }
  }
}

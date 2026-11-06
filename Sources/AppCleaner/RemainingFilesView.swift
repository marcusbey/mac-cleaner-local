import AppKit
import CleanerCore
import SwiftUI

struct RemainingFilesView: View {
  @ObservedObject var model: CleanerModel
  @State private var query = ""
  @State private var largest = true
  @State private var selected: Set<String> = []
  @State private var reviewing = false
  @State private var busy = false
  var visible: [RemainingFile] {
    model.remaining.filter {
      query.isEmpty || $0.bundleID.localizedCaseInsensitiveContains(query)
        || $0.url.path.localizedCaseInsensitiveContains(query)
    }.sorted { largest ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
  }
  var chosen: [RemainingFile] { model.remaining.filter { selected.contains($0.id) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("App Leftovers").font(.largeTitle.bold())
          Text("Settings, caches, and support files left behind by apps you already deleted.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Rescan", action: rescan).disabled(model.scanningRemaining || model.scanning || busy)
      }
      HStack {
        Image(systemName: "magnifyingglass")
        TextField("Search leftovers", text: $query).textFieldStyle(.plain)
        Picker("Sort", selection: $largest) {
          Text("Largest first").tag(true)
          Text("Name").tag(false)
        }.frame(width: 180)
      }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
      InfoCard(
        symbol: "questionmark.circle",
        title: "How it works",
        text:
          "Dragging an app to Trash leaves its data in your Library. This finds folders named after an app (like com.spotify.client) when that app is no longer installed or running. Nothing is selected for you: command-line tools and shared components can still use some of these, so check each path before removing.")
      HStack {
        Text("\(visible.count) candidates · \(size(visible.reduce(0){$0 + max(0,$1.bytes)}))").font(
          .headline)
        Spacer()
        Button("Select All") { selected.formUnion(visible.map(\.id)) }.disabled(visible.isEmpty)
        Button("Deselect All") { selected = [] }.disabled(selected.isEmpty)
      }
      if model.scanning || model.scanningRemaining {
        Spacer()
        ProgressView(
          model.scanning ? "Waiting for application inventory…" : "Checking file ownership…"
        ).frame(maxWidth: .infinity)
        Spacer()
      } else if visible.isEmpty {
        Spacer()
        ContentUnavailableView(
          query.isEmpty ? "No possible leftovers found" : "No matching files",
          systemImage: "checkmark.shield",
          description: Text(
            "The scan covers readable user Library caches, preferences, support, saved state and logs."
          ))
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(visible) { file in
              HStack(alignment: .top, spacing: 12) {
                Toggle(
                  "Select \(file.bundleID) \(file.category)",
                  isOn: Binding(
                    get: { selected.contains(file.id) },
                    set: { if $0 { selected.insert(file.id) } else { selected.remove(file.id) } })
                ).labelsHidden().toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 5) {
                  Text(file.bundleID).font(.headline)
                  Text("\(file.category) · \(file.reason)").font(.caption).foregroundStyle(
                    .secondary)
                  Text(file.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(
                    .caption
                  ).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(size(file.bytes)).monospacedDigit()
                RowButton("Reveal", symbol: "magnifyingglass", help: "Reveal in Finder") {
                  NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
              }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 10)).overlay(
                RoundedRectangle(cornerRadius: 10).stroke(
                  selected.contains(file.id) ? Color.blue : line))
            }
          }
        }
      }
      Divider()
      HStack {
        Text("\(chosen.count) selected · \(size(chosen.reduce(0){$0 + max(0,$1.bytes)}))")
          .foregroundStyle(
            .secondary)
        Spacer()
        Button("Clean Selected…") { reviewing = true }.buttonStyle(.borderedProminent).disabled(
          chosen.isEmpty || model.scanningRemaining || model.scanning)
      }
    }.padding(28).frame(maxWidth: .infinity)
      .task { if !model.remainingScanned { model.scanRemaining() } }
      .onChange(of: model.scanning) { _, value in
        if !value && !model.remainingScanned { model.scanRemaining() }
      }
      .onChange(of: model.remaining.map(\.id)) { _, ids in selected.formIntersection(ids) }
      .sheet(isPresented: $reviewing) {
        VStack(alignment: .leading, spacing: 16) {
          Text("Review remaining files").font(.title2.bold())
          Text(
            "Move \(chosen.count) selected items (\(size(chosen.reduce(0){$0 + max(0,$1.bytes)}))) to Trash?"
          )
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(chosen) { file in Text(file.url.path).font(.callout).textSelection(.enabled) }
            }
          }.frame(minHeight: 100, maxHeight: 300)
          Text(
            "Ownership and file identity are checked again before removal. Restore from Trash if you need these files."
          ).foregroundStyle(.secondary)
          HStack {
            Button("Cancel") { reviewing = false }.keyboardShortcut(.cancelAction).disabled(busy)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Move to Trash", role: .destructive, action: remove).buttonStyle(
              .borderedProminent
            ).tint(.red).disabled(busy)
          }
        }.padding(28).frame(width: 650).interactiveDismissDisabled(busy)
      }
  }
  func rescan() {
    selected = []
    model.scanRemaining()
  }
  func remove() {
    busy = true
    let files = chosen
    let apps = model.apps
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { try RemainingTrashService.moveToTrash(files, installedApps: apps) }
      }.value
      busy = false
      reviewing = false
      selected = []
      switch result {
      case .success(let urls): model.message = "Moved \(urls.count) remaining items to Trash."
      case .failure(let error): model.message = error.localizedDescription
      }
      model.scanRemaining()
    }
  }
}

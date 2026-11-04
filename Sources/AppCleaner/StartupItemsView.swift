import AppKit
import CleanerCore
import SwiftUI

@MainActor private final class StartupItemsModel: ObservableObject {
  @Published var items: [StartupItem] = []
  @Published var loading = false
  @Published var working: Set<String> = []
  @Published var message = ""

  func load() {
    loading = true
    Task {
      items = await Task.detached(priority: .userInitiated) { StartupItems.scan() }.value
      loading = false
    }
  }

  func setEnabled(_ item: StartupItem, _ enabled: Bool) {
    working.insert(item.id)
    Task {
      let result = await Task.detached { Result { try StartupItems.setEnabled(item, enabled) } }.value
      if case .failure(let error) = result { message = error.localizedDescription }
      working.remove(item.id)
      load()
    }
  }

  func remove(_ item: StartupItem) {
    Task {
      let result = await Task.detached { Result { try StartupItems.remove(item) } }.value
      switch result {
      case .success: message = "Stopped \(item.owner) and moved its startup file to Trash."
      case .failure(let error): message = error.localizedDescription
      }
      load()
    }
  }
}

struct StartupItemsView: View {
  @StateObject private var model = StartupItemsModel()
  @State private var query = ""
  @State private var scope: StartupScope?
  @State private var pendingRemoval: StartupItem?

  private var visible: [StartupItem] {
    model.items.filter {
      (scope == nil || $0.scope == scope)
        && (query.isEmpty || $0.owner.localizedCaseInsensitiveContains(query)
          || $0.label.localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Startup Items").font(.largeTitle.bold())
          Text("Apps and helpers that start by themselves when you log in or your Mac starts.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.load()
        } label: {
          Label("Rescan", systemImage: "arrow.clockwise")
        }.disabled(model.loading)
        Button("Login Items Settings") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }.help("Apps added as Login Items are managed in System Settings")
      }
      summary
      HStack(spacing: 12) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search startup items", text: $query).textFieldStyle(.plain)
        }.padding(10).background(panel, in: RoundedRectangle(cornerRadius: 9))
        Picker("Scope", selection: $scope) {
          Text("All").tag(StartupScope?.none)
          ForEach(StartupScope.allCases, id: \.self) { Text($0.rawValue).tag(StartupScope?.some($0)) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
      }
      if model.loading && model.items.isEmpty {
        Spacer()
        ProgressView("Reading startup items…").frame(maxWidth: .infinity)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
            ForEach(StartupScope.allCases, id: \.self) { group in
              let rows = visible.filter { $0.scope == group }
              if !rows.isEmpty {
                SwiftUI.Section {
                  ForEach(rows) { row($0) }
                } header: {
                  sectionHeader(group, count: rows.count)
                }
              }
            }
          }.padding(.bottom, 8)
        }
      }
    }
    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { if model.items.isEmpty { model.load() } }
    .confirmationDialog(
      "Remove \(pendingRemoval?.owner ?? "") from startup?",
      isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      presenting: pendingRemoval
    ) { item in
      Button("Stop and Move to Trash", role: .destructive) {
        model.remove(item)
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: { item in
      Text("\(item.url.lastPathComponent) moves to Trash. The app itself is not removed.")
    }
    .alert(
      "Startup Items",
      isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })
    ) {
      Button("OK") { model.message = "" }
    } message: {
      Text(model.message)
    }
  }

  private var summary: some View {
    let items = model.items
    return HStack(spacing: 10) {
      stat("\(items.count)", "items", .white)
      stat("\(items.filter(\.isRunning).count)", "running now", .green)
      stat("\(items.filter(\.startsAtLogin).count)", "start automatically", .cyan)
      stat("\(items.filter { !$0.isEnabled }.count)", "turned off", .secondary)
      if items.contains(where: \.programMissing) {
        stat("\(items.filter(\.programMissing).count)", "broken leftovers", .orange)
      }
    }
  }

  private func stat(_ value: String, _ title: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(panel, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
  }

  private func sectionHeader(_ scope: StartupScope, count: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(scope.rawValue).font(.headline)
        Text("\(count)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
          .background(Color.white.opacity(0.1), in: Capsule())
      }
      Text(scopeExplanation(scope)).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    .background(navy)
  }

  private func scopeExplanation(_ scope: StartupScope) -> String {
    switch scope {
    case .user: "Installed only for you. Turn off or remove without a password."
    case .allUsers: "Runs in every user's session. Turning it off affects only your account."
    case .system: "Background services for the whole Mac. Changes ask for your administrator password."
    }
  }

  private func row(_ item: StartupItem) -> some View {
    HStack(spacing: 12) {
      icon(item).frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(item.owner).font(.headline).lineLimit(1)
          Text(item.vendor).font(.caption).foregroundStyle(.secondary)
        }
        Text(item.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      HStack(spacing: 6) {
        if item.programMissing {
          pill("Broken leftover", "exclamationmark.triangle.fill", .orange)
            .help("The program it launches no longer exists. Safe to remove or turn off.")
        } else if item.isRunning {
          pill("Running", "circle.fill", .green)
        }
        if item.startsAtLogin { pill("At login", "power", .cyan) }
      }
      if model.working.contains(item.id) {
        ProgressView().controlSize(.small).frame(width: 40)
      } else {
        Toggle(
          "Enabled",
          isOn: Binding(get: { item.isEnabled }, set: { model.setEnabled(item, $0) })
        ).toggleStyle(.switch).labelsHidden().controlSize(.small).frame(width: 40)
          .help(item.scope.needsAdmin ? "Asks for your administrator password" : "Turn on or off for your account")
      }
      Menu {
        Button("Reveal Startup File") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        if let program = item.program, !item.programMissing {
          Button("Reveal Program") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program)])
          }
        }
        if item.scope == .user {
          Divider()
          Button("Remove…", role: .destructive) { pendingRemoval = item }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(panel, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10).stroke(item.programMissing ? Color.orange.opacity(0.5) : line))
    .opacity(item.isEnabled ? 1 : 0.6)
  }

  @ViewBuilder private func icon(_ item: StartupItem) -> some View {
    if let program = item.program, let range = program.range(of: ".app/") {
      Image(nsImage: NSWorkspace.shared.icon(forFile: String(program[..<range.lowerBound]) + ".app"))
        .resizable()
    } else {
      Image(systemName: "gearshape.2.fill").font(.system(size: 18)).foregroundStyle(.secondary)
    }
  }

  private func pill(_ title: String, _ symbol: String, _ color: Color) -> some View {
    Label(title, systemImage: symbol).font(.caption2.bold()).foregroundStyle(color)
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(color.opacity(0.14), in: Capsule())
      .labelStyle(.titleAndIcon).fixedSize()
  }
}

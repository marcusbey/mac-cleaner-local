import AppKit
import CleanerCore
import SwiftUI

@main struct CleanerApp: App {
  @NSApplicationDelegateAdaptor(CleanerApplicationDelegate.self) var delegate
  @StateObject private var memoryMenu = MemoryMenuModel.shared
  var body: some Scene {
    WindowGroup(id: "main") { ContentView(memoryMenu: memoryMenu) }.windowStyle(
      .hiddenTitleBar
    ).defaultSize(width: 1240, height: 820)
    .commands { QuickMemoryCommands() }
    Window("Quick Memory Clean", id: "quickMemory") { MemoryMenuView(model: memoryMenu) }
      .windowResizability(.contentSize)
    MenuBarExtra {
      MemoryMenuView(model: memoryMenu)
    } label: {
      // Sparkle (the app icon) plus live memory use, so the menu bar item explains itself.
      Text(
        memoryMenu.snapshot == nil
          ? "\(Image(systemName: "sparkles"))"
          : "\(Image(systemName: "sparkles")) \(Int(memoryMenu.percent.rounded()))%"
      ).monospacedDigit()
        .accessibilityLabel("Mac Cleaner, memory \(Int(memoryMenu.percent.rounded())) percent used")
    }.menuBarExtraStyle(.window)
  }
}
let navy = Color(red: 0.045, green: 0.16, blue: 0.245)
let panel = Color(red: 0.035, green: 0.135, blue: 0.21)
let line = Color(red: 0.08, green: 0.27, blue: 0.40)
func size(_ bytes: Int64) -> String {
  bytes < 0 ? "Unavailable" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

enum Section: String, CaseIterable {
  case memory = "Memory"
  case cleanup = "Disk Cleanup"
  case spaceMap = "Space Map"
  case aiModels = "AI Models"
  case applications = "Applications"
  case startup = "Startup Items"
  case extensions = "Extensions"
  case remaining = "App Leftovers"
  case updates = "App Updates"
  var icon: String {
    switch self {
    case .memory: "memorychip"
    case .cleanup: "internaldrive"
    case .spaceMap: "chart.pie"
    case .aiModels: "cpu"
    case .applications: "app.badge"
    case .startup: "power"
    case .extensions: "puzzlepiece.extension"
    case .remaining: "doc.text.magnifyingglass"
    case .updates: "arrow.triangle.2.circlepath"
    }
  }
}
struct ContentView: View {
  @ObservedObject var memoryMenu: MemoryMenuModel
  @StateObject private var model = CleanerModel()
  @State private var section: Section = .applications
  @State private var query = ""
  @State private var expert = false
  @AppStorage("sortLargestFirst") private var largest = true
  @State private var checkedApps: Set<String> = []
  @State private var collapsedSections: Set<String> = []
  @State private var collapsedGroups: Set<String> = []
  @State private var expanded: Set<String> = []
  @AppStorage("groupByVendor") private var groupByVendor = true
  @State private var selectedFiles: Set<String> = []
  @State private var utilityItems: [URL] = []
  var filtered: [AppRecord] {
    model.apps.filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        || $0.bundleID.localizedCaseInsensitiveContains(query)
    }.sorted {
      largest ? $0.bytes > $1.bytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  var body: some View {
    HStack(spacing: 0) {
      sidebar
      if section == .memory {
        MemoryView(memoryMenu: memoryMenu)
      } else if section == .cleanup {
        DiskCleanupView()
      } else if section == .spaceMap {
        SpaceMapView()
      } else if section == .aiModels {
        AIModelsView()
      } else if section == .applications {
        applicationList
        details
      } else if section == .startup {
        StartupItemsView()
      } else if section == .remaining {
        RemainingFilesView(model: model)
      } else if section == .updates {
        UpdatesView(model: model)
      } else {
        utilityView
      }
    }
    .background(navy).foregroundStyle(.white).preferredColorScheme(.dark)
    .frame(minWidth: 1000, minHeight: 650)
    .task { model.scan() }
    .sheet(item: $model.reviewSelection) { selection in
      UninstallReview(selection: selection, installed: model.apps) {
        model.reviewSelection = nil
      } onFinished: { message in
        model.reviewSelection = nil
        model.message = message
        model.scan()
      }
    }
    .alert(
      "App Cleaner",
      isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })
    ) {
      Button("OK") { model.message = "" }
    } message: {
      Text(model.message)
    }
  }
  var sidebar: some View {
    SidePanel(selection: $section) { loadUtility() }
  }
  var applicationList: some View {
    VStack(spacing: 12) {
      HStack {
        Text("App Cleaner & Uninstaller").font(.headline)
        Spacer()
        Button {
          model.scan()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.disabled(model.scanning).help("Rescan applications")
      }.padding(.top, 25)
      HStack {
        Image(systemName: "magnifyingglass")
        TextField("Search applications", text: $query).textFieldStyle(.plain)
        Menu {
          Button("Name") { largest = false }
          Button("Largest first") { largest = true }
        } label: {
          Text(largest ? "Size" : "Name").font(.caption)
          Image(systemName: "chevron.down").font(.caption)
        }
      }.foregroundStyle(.secondary)
      HStack {
        Text(
          model.scanning
            ? "Scanning applications…"
            : "\(filtered.count) application\(filtered.count == 1 ? "" : "s")")
        Spacer()
        if model.scanning { ProgressView().controlSize(.small) }
      }.font(.caption).foregroundStyle(.secondary)
      Toggle("Group by vendor", isOn: $groupByVendor).font(.caption).toggleStyle(.checkbox)
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(
            ApplicationHierarchy.sections(
              groups: VendorGrouping.groups(
                for: model.apps, query: query, largestFirst: largest, enabled: groupByVendor),
              bySize: largest && !model.scanning)
          ) { section in
            VStack(spacing: 6) {
              if largest {
                Button {
                  if collapsedSections.contains(section.id) {
                    collapsedSections.remove(section.id)
                  } else {
                    collapsedSections.insert(section.id)
                  }
                } label: {
                  HStack {
                    Image(
                      systemName: collapsedSections.contains(section.id)
                        ? "chevron.right" : "chevron.down")
                    Text(section.title).font(.headline)
                    Spacer()
                  }.padding(12).background(panel).contentShape(Rectangle()).overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(line))
                }.buttonStyle(.plain).accessibilityLabel("\(section.title) section")
              }
              if !collapsedSections.contains(section.id) || !largest {
                ForEach(section.groups) { group in
                  if group.isGroup {
                    vendorRow(group)
                  } else if let app = group.apps.first {
                    selectableApplicationRow(app)
                  }
                }
              }
            }
          }
        }
      }
      if !checkedApps.isEmpty {
        HStack {
          Text("\(checkedApps.count) selected").font(.caption)
          Button("Deselect All") { checkedApps = [] }
          Spacer()
          Button("Review Selected") {
            model.prepareReview(model.apps.filter { checkedApps.contains($0.id) })
          }.buttonStyle(.borderedProminent).disabled(model.scanning || model.loadingFiles)
        }.padding(.vertical, 8)
      }
    }.padding(.horizontal, 14).frame(width: 380).background(panel.opacity(0.5))
      .onChange(of: model.apps.map(\.id)) { _, ids in checkedApps.formIntersection(ids) }
  }
  func selectableApplicationRow(_ app: AppRecord, nested: Bool = false) -> some View {
    HStack(spacing: 10) {
      Toggle(
        "Select \(app.name)",
        isOn: Binding(
          get: { checkedApps.contains(app.id) },
          set: { if $0 { checkedApps.insert(app.id) } else { checkedApps.remove(app.id) } })
      ).labelsHidden().toggleStyle(.checkbox).disabled(
        app.bundleID.hasPrefix("com.apple.") || app.url == Bundle.main.bundleURL)
      Button {
        model.select(app)
      } label: {
        HStack(spacing: 10) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(
            width: 30, height: 30)
          VStack(alignment: .leading, spacing: 4) {
            Text(app.name).lineLimit(1)
            Text(app.modified?.formatted(date: .abbreviated, time: .omitted) ?? "Application").font(
              .caption
            ).foregroundStyle(.secondary)
          }
          Spacer(minLength: 3)
          Text(model.scanning ? "…" : size(app.totalBytes) + (app.sizeIncomplete ? "+" : "")).font(
            .system(size: 12, weight: .medium)
          ).monospacedDigit()
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
    }.padding(.vertical, 11).padding(.leading, nested ? 38 : 12).padding(.trailing, 12)
      .background(
        model.selected?.id == app.id && model.selectedGroup == nil
          ? Color.blue.opacity(0.35) : panel
      )
      .clipShape(RoundedRectangle(cornerRadius: nested ? 0 : 12))
      .overlay { if !nested { RoundedRectangle(cornerRadius: 12).stroke(line) } }
  }
  func vendorRow(_ group: VendorGroup) -> some View {
    let eligible = Set(
      group.apps.filter { !$0.bundleID.hasPrefix("com.apple.") && $0.url != Bundle.main.bundleURL }
        .map(\.id))
    let selectedCount = checkedApps.intersection(eligible).count
    let opened = !collapsedGroups.contains(group.id)
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        Toggle(
          "Select \(group.name) group, \(selectedCount) of \(eligible.count) selected",
          isOn: Binding(
            get: { !eligible.isEmpty && eligible.isSubset(of: checkedApps) },
            set: {
              if $0 { checkedApps.formUnion(eligible) } else { checkedApps.subtract(eligible) }
            })
        ).labelsHidden().toggleStyle(.checkbox).disabled(eligible.isEmpty)
        Image(systemName: "folder.fill").font(.system(size: 29)).foregroundStyle(.cyan)
        Button {
          if opened { collapsedGroups.insert(group.id) } else { collapsedGroups.remove(group.id) }
        } label: {
          Image(systemName: opened ? "chevron.down" : "chevron.right").frame(width: 15, height: 32)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(
          "\(opened ? "Collapse":"Expand") \(group.name) group")
        Button {
          model.select(group)
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text("Common \(group.name) Applications").lineLimit(1)
              Text(
                selectedCount > 0 ? "\(selectedCount) selected" : "\(group.apps.count) applications"
              ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Text(model.scanning ? "…" : size(group.bytes) + (group.sizeIncomplete ? "+" : "")).font(
              .system(size: 12, weight: .medium))
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
      }.padding(12).background(
        model.selectedGroup?.id == group.id ? Color.blue.opacity(0.35) : panel)
      if opened {
        ForEach(group.apps) { app in
          Divider().overlay(line).padding(.leading, 20)
          selectableApplicationRow(app, nested: true)
        }
      }
    }.clipShape(RoundedRectangle(cornerRadius: 12)).overlay(
      RoundedRectangle(cornerRadius: 12).stroke(line))
  }

  var details: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Toggle("Expert Mode", isOn: $expert).toggleStyle(.switch).controlSize(.small)
        Spacer()
        Button {
          model.message =
            "Scans /Applications and ~/Applications. Related files are matched by exact bundle identifier in selected user Library folders. Shared group containers are excluded. A + beside a size means a protected container could not be measured. Container sizes use allocated disk space."
        } label: {
          Image(systemName: "questionmark.circle")
        }
      }.padding(.top, 23)
      if let group = model.selectedGroup {
        groupDetails(group)
      } else if let app = model.selected {
        HStack(spacing: 20) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(
            width: 100, height: 100)
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(app.name).font(.title2.bold())
              Spacer()
              Text(size(app.bytes + model.files.reduce(0) { $0 + max(0, $1.bytes) })).font(
                .title3.bold())
            }
            Divider()
            Text("\(model.files.count) related files and folders").foregroundStyle(.secondary)
            Text(app.bundleID).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
          }
        }.padding(24).frame(maxWidth: .infinity).background(
          panel, in: RoundedRectangle(cornerRadius: 12)
        ).overlay(RoundedRectangle(cornerRadius: 12).stroke(line))
        Text("General").font(.title3.bold())
        metadata("Version", app.version)
        metadata("Modified", app.modified?.formatted() ?? "Unknown")
        metadata("Application bundle", size(app.bytes))
        metadata("Related storage", size(model.files.reduce(0) { $0 + max(0, $1.bytes) }))
        HStack {
          Text("Location").foregroundStyle(.secondary)
          Spacer()
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }.font(.callout)
        if expert {
          HStack {
            Text("Related Files").font(.title3.bold())
            Spacer()
            if model.loadingFiles { ProgressView().controlSize(.small) }
          }
          ScrollView {
            VStack(spacing: 0) {
              ForEach(model.files) { file in
                HStack {
                  Image(systemName: "doc")
                  VStack(alignment: .leading) {
                    Text(file.category)
                    Text(file.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(
                      .caption
                    ).foregroundStyle(.secondary).lineLimit(2)
                  }
                  Spacer()
                  Text(size(file.bytes))
                }.padding(.vertical, 10)
                Divider()
              }
            }
          }
          Text("Only exact bundle-ID matches are included. Shared vendor folders are preserved.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              app.bundleID.hasPrefix("com.apple.")
                ? "System application protected" : "Review before removing"
            ).font(.callout)
            Text("Files are moved to Trash.").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            model.prepareReview([app])
          } label: {
            Text("Review Uninstall").font(.headline).padding(.horizontal, 24).padding(.vertical, 9)
          }.buttonStyle(.borderedProminent).tint(.blue).disabled(
            model.loadingFiles || model.scanning || app.bundleID.hasPrefix("com.apple.")
              || app.url == Bundle.main.bundleURL)
        }.padding(.bottom, 18)
      } else {
        Spacer()
        ContentUnavailableView(
          model.scanning ? "Finding your applications" : "No applications found",
          systemImage: "app.dashed",
          description: Text("Applications appear here after a local scan."))
        Spacer()
      }
    }.padding(.horizontal, 24).frame(maxWidth: .infinity)
  }
  func metadata(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).textSelection(.enabled)
    }.font(.callout)
  }
  func applicationRow(_ app: AppRecord) -> some View {
    Button {
      model.select(app)
    } label: {
      HStack(spacing: 12) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(
          width: 35, height: 35)
        VStack(alignment: .leading, spacing: 5) {
          Text(app.name).lineLimit(1)
          Text(app.modified?.formatted(date: .abbreviated, time: .omitted) ?? "Application").font(
            .caption
          ).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Text(model.scanning ? "…" : size(app.totalBytes) + (app.sizeIncomplete ? "+" : "")).font(
          .system(size: 12, weight: .medium)
        ).monospacedDigit()
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
        model.selected?.id == app.id && model.selectedGroup == nil
          ? Color(red: 0.08, green: 0.32, blue: 0.54) : panel,
        in: RoundedRectangle(cornerRadius: 12)
      ).overlay(RoundedRectangle(cornerRadius: 12).stroke(line))
    }.buttonStyle(.plain)
  }
  func groupDetails(_ group: VendorGroup) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 20) {
        Image(systemName: "folder.fill").font(.system(size: 80)).foregroundStyle(.cyan)
        VStack(alignment: .leading, spacing: 12) {
          Text("Common \(group.name) Applications Group").font(.title2.bold())
          Divider()
          Text(
            "\(group.apps.count) applications · \(size(group.bytes) + (group.sizeIncomplete ? "+" : ""))"
          ).foregroundStyle(
            .secondary)
        }
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(
        panel, in: RoundedRectangle(cornerRadius: 12)
      ).overlay(RoundedRectangle(cornerRadius: 12).stroke(line))
      Text("Applications in this group").font(.title3.bold())
      Text("Grouped by bundle namespace: \(group.id). Shared vendor folders are preserved.").font(
        .caption
      ).foregroundStyle(.secondary)
      ScrollView { VStack(spacing: 8) { ForEach(group.apps) { app in applicationRow(app) } } }
      Divider()
      HStack {
        Text("Choose what to remove in the review.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Review Group Uninstall") {
          model.prepareReview(
            group.apps.filter {
              !$0.bundleID.hasPrefix("com.apple.") && $0.url != Bundle.main.bundleURL
            })
        }.buttonStyle(
          .borderedProminent
        ).disabled(
          model.loadingFiles || model.scanning
            || group.apps.allSatisfy {
              $0.bundleID.hasPrefix("com.apple.") || $0.url == Bundle.main.bundleURL
            })
      }.padding(.bottom, 18)
    }
  }
  var utilityView: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(section.rawValue).font(.largeTitle.bold()).padding(.top, 30)
      Text(utilityDescription).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(utilityItems, id: \.path) { url in
            HStack {
              Image(systemName: section.icon)
              VStack(alignment: .leading) {
                Text(url.lastPathComponent)
                Text(url.path).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.padding().background(panel, in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
      if utilityItems.isEmpty {
        Text("No readable entries found in the inspected folders.").foregroundStyle(.secondary)
      }
      Spacer()
      if section == .startup {
        Button("Manage Login Items in System Settings") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
      }
    }.padding(30).frame(maxWidth: .infinity)
  }
  var utilityDescription: String {
    switch section {
    case .startup:
      "Launch agents and daemons found in user and local Library folders. Use System Settings to manage modern login items."
    case .extensions:
      "Locally installed preference panes, Quick Look generators, and internet plug-ins. Reveal an item to inspect it in Finder."
    case .remaining: "Unowned data is never automatically assumed safe to delete."
    case .updates:
      "macOS updates are managed by Software Update. Third-party applications retain their own update mechanisms."
    case .applications: ""
    case .memory: "Live memory usage"
    case .cleanup: "Review files before cleanup"
    case .spaceMap: "Disk space map"
    case .aiModels: "Local AI models"
    }
  }
  func loadUtility() {
    let home = NSHomeDirectory()
    let paths =
      section == .startup
      ? ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
      : [
        "\(home)/Library/QuickLook", "/Library/QuickLook", "\(home)/Library/PreferencePanes",
        "/Library/PreferencePanes", "/Library/Internet Plug-Ins",
      ]
    utilityItems = paths.flatMap {
      (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: $0), includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
        ?? []
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

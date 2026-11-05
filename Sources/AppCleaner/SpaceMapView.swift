import AppKit
import CleanerCore
import SwiftUI

@MainActor private final class SpaceMapModel: ObservableObject {
  /// Lives for the whole app run, so a scan keeps going and its results stay when you switch screens.
  static let shared = SpaceMapModel()
  @Published var root: SizeNode?
  @Published var path: [String] = []
  @Published var scanning = false
  @Published var scannedFiles = 0
  @Published var scannedBytes: Int64 = 0
  @Published var currentFolder = ""
  @Published var startedAt = Date()
  /// Last time the scanner reported anything; a long gap usually means a macOS permission prompt.
  @Published var lastProgressAt = Date()
  /// Bytes in use on the volume, so whole-disk scans can show a real progress fraction.
  @Published var expectedBytes: Int64?
  private var lastWholeDisk = false
  @Published var unreadable: [String] = []
  @Published var target = FileManager.default.homeDirectoryForCurrentUser
  @Published var message = ""
  private var task: Task<Void, Never>?

  /// Current drill-down node, resolved from ids so it stays valid after the tree changes.
  var focus: SizeNode? {
    guard var node = root else { return nil }
    for id in path {
      guard let next = node.children.first(where: { $0.id == id }) else { break }
      node = next
    }
    return node
  }
  var trail: [SizeNode] {
    guard var node = root else { return [] }
    var result = [node]
    for id in path {
      guard let next = node.children.first(where: { $0.id == id }) else { break }
      node = next
      result.append(node)
    }
    return result
  }

  func scan(_ url: URL, wholeDisk: Bool = false) {
    task?.cancel()
    target = url
    root = nil
    path = []
    unreadable = []
    scannedFiles = 0
    scannedBytes = 0
    currentFolder = url.path
    startedAt = Date()
    lastProgressAt = Date()
    expectedBytes = wholeDisk ? (try? DiskVolumeUsage.read(for: url)).map(\.usedBytes) : nil
    lastWholeDisk = wholeDisk
    scanning = true
    task = Task {
      let worker = Task.detached(priority: .userInitiated) { [weak self] in
        SizeTree.scan(url, minimumBytes: 1_000_000) { update in
          Task { @MainActor in self?.apply(update) }
        }
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      scanning = false
      guard !result.cancelled else {
        message = "Scan cancelled. The map shows what was measured so far."
        return
      }
      root = result.root
      unreadable = result.unreadableFolders
      scannedFiles = result.fileCount
      scannedBytes = result.root.bytes
    }
  }
  private func apply(_ update: SizeTreeProgress) {
    guard scanning else { return }
    root = update.partial
    scannedFiles = update.files
    scannedBytes = update.bytes
    currentFolder = update.currentFolder
    lastProgressAt = Date()
  }
  func cancel() { task?.cancel() }
  func rescan() { scan(target, wholeDisk: lastWholeDisk) }
  func open(_ node: SizeNode) {
    guard node.isDirectory, !node.children.isEmpty else { return }
    path = trail.dropFirst().map(\.id) + [node.id]
  }
  func up(to index: Int) { path = Array(path.prefix(index)) }
  func trash(_ node: SizeNode) {
    guard let url = node.url else { return }
    Task {
      let result = await Task.detached { Result { try SizeTree.moveToTrash(url) } }.value
      switch result {
      case .success:
        root = root?.removing(id: node.id)
        message = "Moved \(node.name) (\(size(node.bytes))) to Trash. Empty Trash to free the space."
      case .failure(let error): message = error.localizedDescription
      }
    }
  }
}

struct SpaceMapView: View {
  @ObservedObject private var model = SpaceMapModel.shared
  @State private var hovered: SizeNode?
  /// Last segment under the pointer; survives the pointer moving into the context menu.
  @State private var menuTarget: SizeNode?
  @State private var pendingTrash: SizeNode?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if model.scanning { scanStatus }
      if let focus = model.focus {
        breadcrumb
        HStack(alignment: .top, spacing: 24) {
          VStack(spacing: 10) {
            Sunburst(focus: focus, hovered: $hovered, onOpen: model.open) {
              if model.path.count > 0 { model.up(to: model.path.count - 1) }
            }
            .onChange(of: hovered?.id) { _, _ in if let hovered { menuTarget = hovered } }
            .contextMenu { if let node = menuTarget { menu(for: node) } }
            .frame(minWidth: 300, maxWidth: 560).aspectRatio(1, contentMode: .fit)
            Text(hovered.map { "\($0.name) · \(size($0.bytes))" } ?? "Hover a segment · click to open")
              .font(.callout).foregroundStyle(.secondary).lineLimit(1)
          }
          list(focus)
        }
      } else if !model.scanning {
        Spacer()
        ContentUnavailableView(
          "See what fills your disk", systemImage: "chart.pie",
          description: Text("Scan your home folder, the whole disk, or any folder."))
        Spacer()
      }
    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
      .confirmationDialog(
        "Move \(pendingTrash?.name ?? "") to Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
        presenting: pendingTrash
      ) { node in
        Button("Move to Trash (\(size(node.bytes)))", role: .destructive) {
          model.trash(node)
          pendingTrash = nil
        }
        Button("Cancel", role: .cancel) { pendingTrash = nil }
      } message: { node in
        Text(node.url?.path ?? "")
      }
      .alert(
        "Space Map",
        isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })
      ) {
        Button("OK") { model.message = "" }
      } message: {
        Text(model.message)
      }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 6) {
        Text("Space Map").font(.largeTitle.bold())
        Text("Every folder and file sized by the disk space it actually uses.")
          .foregroundStyle(.secondary)
      }
      Spacer()
      if model.scanning {
        Button("Cancel", action: model.cancel)
      } else {
        if model.root != nil {
          Button {
            model.rescan()
          } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
          }.buttonStyle(.borderedProminent).help("Scan the same location again")
        }
        Button("Home Folder") { model.scan(FileManager.default.homeDirectoryForCurrentUser) }
        Button("Entire Disk") {
          model.scan(URL(fileURLWithPath: "/System/Volumes/Data"), wholeDisk: true)
        }
        Button("Choose Folder…", action: chooseFolder)
      }
    }
  }

  private var scanStatus: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Scanning").font(.headline)
          Text("\(model.scannedFiles.formatted()) files · \(size(model.scannedBytes)) found")
            .monospacedDigit()
          Spacer()
          Text(elapsed(since: model.startedAt, now: context.date)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        if let expected = model.expectedBytes, expected > 0 {
          ProgressView(value: min(1, Double(model.scannedBytes) / Double(expected)))
            .tint(.cyan)
        }
        Text(model.currentFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
          .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
        if context.date.timeIntervalSince(model.lastProgressAt) > 8 {
          Label(
            "No progress for a few seconds. macOS may be asking for permission to read a folder; check for a dialog.",
            systemImage: "hand.raised.fill"
          ).font(.caption).foregroundStyle(.orange)
        }
      }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
    }
  }

  private func elapsed(since start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private var breadcrumb: some View {
    HStack(spacing: 4) {
      ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, node in
        if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
        Button(index == 0 ? model.target.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : node.name) {
          model.up(to: index)
        }.buttonStyle(.plain).foregroundStyle(index == model.trail.count - 1 ? .white : .secondary)
      }
      Spacer()
      if !model.scanning {
        Text("\(size(model.focus?.bytes ?? 0)) · \(model.scannedFiles.formatted()) files scanned")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !model.unreadable.isEmpty {
        Button("\(model.unreadable.count) folders unreadable · Grant Full Disk Access") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }.font(.caption).foregroundStyle(.orange).buttonStyle(.plain)
      }
    }.font(.callout)
  }

  private func list(_ focus: SizeNode) -> some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(Array(focus.children.enumerated()), id: \.element.id) { index, node in
          row(node, color: Sunburst.topColor(index: index, node: node), total: focus.bytes)
        }
      }
    }
  }

  private func row(_ node: SizeNode, color: Color, total: Int64) -> some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
      Image(systemName: node.isAggregate ? "ellipsis.circle" : node.isDirectory ? "folder.fill" : "doc")
        .foregroundStyle(.cyan).frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text(node.name).lineLimit(1).truncationMode(.middle)
        GeometryReader { geometry in
          Capsule().fill(color.opacity(0.8))
            .frame(width: geometry.size.width * share(node.bytes, of: total))
        }.frame(height: 4)
      }.frame(minWidth: 70, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
      Text(size(node.bytes)).monospacedDigit().lineLimit(1).fixedSize()
      Text(String(format: "%.1f%%", share(node.bytes, of: total) * 100)).font(.caption)
        .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
      if let url = node.url {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: { Image(systemName: "magnifyingglass") }.help("Reveal in Finder")
        Button {
          pendingTrash = node
        } label: { Image(systemName: "trash") }.help("Move to Trash")
          .disabled(model.scanning || !SizeTree.canTrash(url))
      }
    }.controlSize(.small).padding(10).contentShape(Rectangle())
      .background(hovered?.id == node.id ? Color.blue.opacity(0.25) : panel, in: RoundedRectangle(cornerRadius: 8))
      .onTapGesture { model.open(node) }
      .onHover { hovered = $0 ? node : nil }
      .contextMenu { menu(for: node) }
  }

  @ViewBuilder private func menu(for node: SizeNode) -> some View {
    if let url = node.url {
      Text("\(node.name) · \(size(node.bytes))")
      Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      if node.isDirectory {
        Button("Open Folder") { NSWorkspace.shared.open(url) }
        Button("Show in Map") { model.open(node) }.disabled(node.children.isEmpty)
      }
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
      }
      Divider()
      Button("Move to Trash…", role: .destructive) { pendingTrash = node }
        .disabled(model.scanning || !SizeTree.canTrash(url))
    } else {
      Text("\(node.name) · \(size(node.bytes))")
      Text("Merged small items; open the parent folder to see them")
    }
  }

  private func share(_ bytes: Int64, of total: Int64) -> Double {
    total > 0 ? min(1, Double(bytes) / Double(total)) : 0
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = model.target
    if panel.runModal() == .OK, let url = panel.url { model.scan(url) }
  }
}

/// Rings of folders around the focused folder: angle ∝ size, ring = depth.
private struct Sunburst: View {
  let focus: SizeNode
  @Binding var hovered: SizeNode?
  let onOpen: (SizeNode) -> Void
  let onUp: () -> Void
  static let depth = 4
  static let minimumSweep = 0.004  // radians; slivers below this are not drawn

  struct Arc {
    let node: SizeNode
    let depth: Int
    let start: Double
    let end: Double
    /// Hue of the top-level branch this arc belongs to.
    let hue: Double
    /// Sibling shade (0–2) so neighbors in one branch stay distinguishable without changing hue.
    let tone: Int
  }

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
      let ring = side / 2 / Double(Self.depth + 1)
      let arcs = Self.arcs(for: focus)
      ZStack {
        Canvas { context, _ in
          var highlight: Path?
          for arc in arcs {
            let shape = Self.shape(arc, center: center, ring: ring)
            let inner = ring * Double(arc.depth)
            // Lighter toward the center of each ring gives the tiles a little depth.
            context.fill(
              shape,
              with: .radialGradient(
                Gradient(colors: [
                  Self.color(hue: arc.hue, depth: arc.depth, tone: arc.tone, node: arc.node, lift: 0.08),
                  Self.color(hue: arc.hue, depth: arc.depth, tone: arc.tone, node: arc.node),
                ]), center: center, startRadius: inner, endRadius: inner + ring))
            context.stroke(shape, with: .color(.white.opacity(0.22)), lineWidth: 0.8)
            if hovered?.id == arc.node.id { highlight = shape }
          }
          if let highlight {
            context.fill(highlight, with: .color(.white.opacity(0.25)))
            context.stroke(highlight, with: .color(.white), lineWidth: 2.5)
          }
          let hub = Path(
            ellipseIn: CGRect(x: center.x - ring + 3, y: center.y - ring + 3, width: 2 * ring - 6, height: 2 * ring - 6))
          context.fill(
            hub,
            with: .linearGradient(
              Gradient(colors: [Color(red: 0.10, green: 0.22, blue: 0.36), panel]),
              startPoint: CGPoint(x: center.x, y: center.y - ring),
              endPoint: CGPoint(x: center.x, y: center.y + ring)))
          context.stroke(hub, with: .color(.white.opacity(0.22)), lineWidth: 0.8)
        }
        VStack(spacing: 4) {
          Text(focus.name).font(.headline).lineLimit(1).truncationMode(.middle)
          Text(size(focus.bytes)).font(.title3.bold()).monospacedDigit()
        }.frame(width: ring * 1.7)
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        if case .active(let point) = phase {
          hovered = Self.hit(point, center: center, ring: ring, arcs: arcs)
        } else {
          hovered = nil
        }
      }
      .gesture(
        SpatialTapGesture().onEnded { value in
          let distance = hypot(value.location.x - center.x, value.location.y - center.y)
          if distance < ring { onUp() } else if let node = Self.hit(value.location, center: center, ring: ring, arcs: arcs) {
            onOpen(node)
          }
        })
    }
  }

  static func arcs(for focus: SizeNode) -> [Arc] {
    var result: [Arc] = []
    func walk(_ node: SizeNode, depth: Int, start: Double, sweep: Double, hue: Double?) {
      guard depth <= Self.depth, node.bytes > 0 else { return }
      var angle = start
      for (index, child) in node.children.enumerated() {
        let childSweep = sweep * Double(child.bytes) / Double(node.bytes)
        guard childSweep >= minimumSweep else {
          angle += childSweep
          continue
        }
        // Each top-level folder owns one hue family; everything inside it keeps that hue and
        // only varies in shade, so branches read as harmonious, related colors.
        let branchHue = hue ?? palette[index % palette.count]
        let tone = hue == nil ? 0 : index % 3
        result.append(
          Arc(
            node: child, depth: depth, start: angle - .pi / 2, end: angle + childSweep - .pi / 2,
            hue: branchHue, tone: tone))
        walk(child, depth: depth + 1, start: angle, sweep: childSweep, hue: branchHue)
        angle += childSweep
      }
    }
    walk(focus, depth: 1, start: 0, sweep: 2 * .pi, hue: nil)
    return result
  }

  /// Ten hues in color-wheel order (coral → orange → amber → lime → green → sky → blue → indigo →
  /// violet → pink): neighbors on the map sit next to each other on the wheel yet stay distinct.
  static let palette: [Double] = [0.0, 0.08, 0.14, 0.26, 0.40, 0.53, 0.61, 0.70, 0.80, 0.90]

  static func topColor(index: Int, node: SizeNode) -> Color {
    color(hue: palette[index % palette.count], depth: 1, tone: 0, node: node)
  }

  static func color(hue: Double, depth: Int, tone: Int, node: SizeNode, lift: Double = 0) -> Color {
    if node.isAggregate { return Color(white: 0.55 + lift, opacity: 0.55) }
    // Tiny analogous shift per tone (never accumulated across levels).
    let shifted = hue + Double(tone - 1) * 0.012 * (tone == 0 && depth == 1 ? 0 : 1)
    let level = Double(depth - 1)
    let saturation = max(0.42, 0.80 - level * 0.08) * (node.isDirectory ? 1 : 0.65)
    let brightness = min(1, 0.96 - Double(tone) * 0.08 + level * 0.015)
    return Color(
      hue: shifted - floor(shifted), saturation: max(0.18, saturation - lift),
      brightness: min(1, brightness + lift))
  }

  static func shape(_ arc: Arc, center: CGPoint, ring: Double) -> Path {
    let inner = ring * Double(arc.depth)
    var shape = Path()
    shape.addArc(
      center: center, radius: inner + ring - 1, startAngle: .radians(arc.start),
      endAngle: .radians(arc.end), clockwise: false)
    shape.addArc(
      center: center, radius: inner, startAngle: .radians(arc.end),
      endAngle: .radians(arc.start), clockwise: true)
    shape.closeSubpath()
    return shape
  }

  static func hit(_ point: CGPoint, center: CGPoint, ring: Double, arcs: [Arc]) -> SizeNode? {
    let dx = point.x - center.x
    let dy = point.y - center.y
    let depth = Int(hypot(dx, dy) / ring)
    guard depth >= 1 else { return nil }
    var angle = atan2(dy, dx)
    if angle < -.pi / 2 { angle += 2 * .pi }
    return arcs.first { $0.depth == depth && angle >= $0.start && angle < $0.end }?.node
  }
}

import Darwin
import Foundation

public struct SizeNode: Identifiable, Sendable {
  public let id: String
  public let name: String
  /// Nil for the merged "smaller items" node, which has no single location.
  public var url: URL? { isAggregate ? nil : URL(fileURLWithPath: id) }
  public let bytes: Int64
  public let isDirectory: Bool
  public let isAggregate: Bool
  public let unreadable: Bool
  public let children: [SizeNode]

  /// Copy of this tree without `id`, with every ancestor's size reduced accordingly.
  public func removing(id target: String) -> SizeNode {
    guard let index = children.firstIndex(where: { $0.id == target || target.hasPrefix($0.id + "/") })
    else { return self }
    var updated = children
    if children[index].id == target {
      updated.remove(at: index)
    } else {
      updated[index] = children[index].removing(id: target)
    }
    return SizeNode(
      id: id, name: name, bytes: updated.reduce(0) { $0 + $1.bytes },
      isDirectory: isDirectory, isAggregate: isAggregate, unreadable: unreadable,
      children: updated)
  }
}

public struct SizeTreeResult: Sendable {
  public let root: SizeNode
  public let fileCount: Int
  public let unreadableFolders: [String]
  public let cancelled: Bool
}

/// Live scan state: everything finished so far plus the folders still being read.
public struct SizeTreeProgress: Sendable {
  public let partial: SizeNode
  public let files: Int
  public let bytes: Int64
  public let currentFolder: String
}

public enum SizeTreeError: LocalizedError {
  case notAllowed(URL)
  public var errorDescription: String? {
    switch self {
    case .notAllowed(let url):
      "Only items inside a folder of your home directory can be moved to Trash here: \(url.path)"
    }
  }
}

/// Builds an allocated-size tree of a folder for the space map. Each folder keeps its largest
/// children; anything under `minimumShare` of the folder or `minimumBytes` is merged into one
/// "N smaller items" node so whole-disk scans stay small in memory.
public enum SizeTree {
  struct Entry {
    let name: String
    let isDirectory: Bool
    let bytes: Int64
  }

  /// One folder via getattrlistbulk(2): names, types and allocated sizes in batched syscalls,
  /// several times faster than per-item resource lookups. Symlinks and special files are dropped.
  static func list(_ path: String) -> [Entry]? {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr =
      attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
      | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
    request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
    let capacity = 256 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
    defer { buffer.deallocate() }
    var entries: [Entry] = []
    while true {
      let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
      if count < 0 { return entries.isEmpty ? nil : entries }
      if count == 0 { return entries }
      var record = buffer
      for _ in 0..<count {
        let length = Int(record.loadUnaligned(as: UInt32.self))
        var field = record + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        var failed = false
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
          failed = field.loadUnaligned(as: UInt32.self) != 0
          field += MemoryLayout<UInt32>.size
        }
        var name = ""
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
          let reference = field.loadUnaligned(as: attrreference_t.self)
          name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
          field += MemoryLayout<attrreference_t>.size
        }
        var type = UInt32(VNON.rawValue)
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
          type = field.loadUnaligned(as: fsobj_type_t.self)
          field += MemoryLayout<fsobj_type_t>.size
        }
        var bytes: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
          bytes = field.loadUnaligned(as: off_t.self)
        }
        if !failed, !name.isEmpty {
          if type == UInt32(VDIR.rawValue) {
            entries.append(Entry(name: name, isDirectory: true, bytes: 0))
          } else if type == UInt32(VREG.rawValue) {
            entries.append(Entry(name: name, isDirectory: false, bytes: bytes))
          }
        }
        record += length
      }
    }
  }

  public static func scan(
    _ url: URL,
    minimumShare: Double = 0.002,
    minimumBytes: Int64 = 0,
    maxChildren: Int = 60,
    updateInterval: TimeInterval = 0.4,
    shouldCancel: () -> Bool = { Task.isCancelled },
    progress: ((SizeTreeProgress) -> Void)? = nil
  ) -> SizeTreeResult {
    var state = ScanState(
      minimumShare: minimumShare, minimumBytes: minimumBytes, maxChildren: maxChildren,
      updateInterval: updateInterval, progress: progress, device: device(of: url))
    let root = state.directory(url.standardizedFileURL.path, shouldCancel: shouldCancel)
    return SizeTreeResult(
      root: root, fileCount: state.fileCount, unreadableFolders: state.unreadable,
      cancelled: state.cancelled)
  }

  /// Trash is offered only below a top-level home folder (e.g. ~/Downloads/x, not ~/Downloads).
  public static func canTrash(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> Bool
  {
    let path = url.standardizedFileURL.path
    let homePath = home.standardizedFileURL.path
    guard path.hasPrefix(homePath + "/") else { return false }
    return path.dropFirst(homePath.count + 1).split(separator: "/").count >= 2
  }

  public static func moveToTrash(_ url: URL) throws -> URL {
    guard canTrash(url) else { throw SizeTreeError.notAllowed(url) }
    try TrashService.validateCanonicalNonSymlink(url)
    var result: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    return (result as URL?) ?? url
  }

  static func device(of url: URL) -> dev_t? {
    var information = stat()
    return lstat(url.path, &information) == 0 ? information.st_dev : nil
  }

  private struct ScanState {
    let minimumShare: Double
    let minimumBytes: Int64
    let maxChildren: Int
    let updateInterval: TimeInterval
    let progress: ((SizeTreeProgress) -> Void)?
    let device: dev_t?
    var fileCount = 0
    var byteCount: Int64 = 0
    var unreadable: [String] = []
    var cancelled = false
    /// Folders currently open, outermost first, with the children finished so far.
    var stack: [(path: String, children: [SizeNode])] = []
    var lastUpdate = 0.0

    mutating func directory(_ path: String, shouldCancel: () -> Bool) -> SizeNode {
      if cancelled || shouldCancel() {
        cancelled = true
        return node(path, bytes: 0, isDirectory: true, unreadable: false, children: [])
      }
      guard let listing = SizeTree.list(path) else {
        unreadable.append(path)
        return node(path, bytes: 0, isDirectory: true, unreadable: true, children: [])
      }
      stack.append((path, []))
      let prefix = path.hasSuffix("/") ? path : path + "/"
      for entry in listing {
        if cancelled { break }
        let child = prefix + entry.name
        if entry.isDirectory {
          // Stay on one volume so mounted disks and firmlinks are not counted twice.
          guard SizeTree.device(of: URL(fileURLWithPath: child)) == device else { continue }
          let finished = directory(child, shouldCancel: shouldCancel)
          stack[stack.count - 1].children.append(finished)
        } else {
          fileCount += 1
          byteCount += entry.bytes
          stack[stack.count - 1].children.append(
            node(child, bytes: entry.bytes, isDirectory: false, unreadable: false, children: []))
        }
      }
      let children = stack.removeLast().children
      if stack.isEmpty || !children.isEmpty { report(folder: path) }
      let total = children.reduce(Int64(0)) { $0 + $1.bytes }
      return node(
        path, bytes: total, isDirectory: true, unreadable: false,
        children: prune(children, parent: path, total: total))
    }

    /// Throttled: folds the open-folder stack into one tree so the map can draw mid-scan.
    mutating func report(folder: String) {
      guard let progress, !stack.isEmpty else { return }
      let now = CFAbsoluteTimeGetCurrent()
      guard now - lastUpdate >= updateInterval else { return }
      lastUpdate = now
      var inner: SizeNode?
      for frame in stack.reversed() {
        let kids = frame.children + (inner.map { [$0] } ?? [])
        let total = kids.reduce(Int64(0)) { $0 + $1.bytes }
        inner = node(
          frame.path, bytes: total, isDirectory: true, unreadable: false,
          children: prune(kids, parent: frame.path, total: total))
      }
      progress(
        SizeTreeProgress(partial: inner!, files: fileCount, bytes: byteCount, currentFolder: folder))
    }

    func prune(_ children: [SizeNode], parent: String, total: Int64) -> [SizeNode] {
      let sorted = children.sorted {
        $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes
      }
      let floor = max(minimumBytes, Int64(Double(total) * minimumShare))
      let kept = Array(sorted.prefix { $0.bytes >= floor }.prefix(maxChildren))
      let rest = sorted.dropFirst(kept.count)
      guard rest.count > 1 else { return sorted }
      return kept + [
        SizeNode(
          id: parent + "/#smaller", name: "\(rest.count) smaller items",
          bytes: rest.reduce(0) { $0 + $1.bytes }, isDirectory: false, isAggregate: true,
          unreadable: false, children: [])
      ]
    }

    func node(_ path: String, bytes: Int64, isDirectory: Bool, unreadable: Bool, children: [SizeNode])
      -> SizeNode
    {
      let name = (path as NSString).lastPathComponent
      return SizeNode(
        id: path, name: name.isEmpty ? path : name, bytes: bytes, isDirectory: isDirectory,
        isAggregate: false, unreadable: unreadable, children: children)
    }
  }
}

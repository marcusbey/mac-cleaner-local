import Foundation

public enum AIModelProvider: Hashable, Sendable {
  case ollama, lmStudio, huggingFace, gpt4all, jan, whisper
  /// A model file stored by an app in Application Support, named after that app.
  case app(String)

  public var displayName: String {
    switch self {
    case .ollama: "Ollama"
    case .lmStudio: "LM Studio"
    case .huggingFace: "Hugging Face"
    case .gpt4all: "GPT4All"
    case .jan: "Jan"
    case .whisper: "Whisper"
    case .app(let name): name
    }
  }
}

public enum AIModelKind: String, Sendable {
  case language = "Language"
  case speech = "Speech"
  case image = "Image"
  case embedding = "Embedding"
}

public struct AIModel: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let provider: AIModelProvider
  public let kind: AIModelKind
  public let format: String
  public let parameters: String?
  public let quantization: String?
  public let bytes: Int64
  public let modified: Date?
  /// What Reveal in Finder shows.
  public let location: URL
  /// Everything removal moves to Trash (Ollama: manifest + blobs; shared blobs are kept).
  public let files: [URL]

  public init(
    id: String, name: String, provider: AIModelProvider, kind: AIModelKind, format: String,
    parameters: String?, quantization: String?, bytes: Int64, modified: Date?, location: URL,
    files: [URL]
  ) {
    self.id = id
    self.name = name
    self.provider = provider
    self.kind = kind
    self.format = format
    self.parameters = parameters
    self.quantization = quantization
    self.bytes = bytes
    self.modified = modified
    self.location = location
    self.files = files
  }
}

public struct AIModelScanResult: Sendable {
  public let models: [AIModel]
  public let searched: [String]
}

public enum AIModelError: LocalizedError {
  case outsideHome(URL)
  public var errorDescription: String? {
    switch self {
    case .outsideHome(let url): "Only models inside your home folder can be removed: \(url.path)"
    }
  }
}

/// Finds local AI models from common runtimes and model files that apps keep in Application Support.
public enum AIModelScanner {
  static let modelExtensions: Set<String> = ["gguf", "safetensors", "onnx", "pt", "pth", "ggml"]
  static let bundleExtensions: Set<String> = ["mlmodelc", "mlpackage"]

  public static func scan(
    home: URL = FileManager.default.homeDirectoryForCurrentUser, minimumBytes: Int64 = 50_000_000
  ) -> AIModelScanResult {
    let home = home.standardizedFileURL
    let support = home.appendingPathComponent("Library/Application Support")
    var models = ollama(home)
    for path in [".lmstudio/models", ".cache/lm-studio/models"] {
      models += nested(home.appendingPathComponent(path), depth: 2, provider: .lmStudio)
    }
    models += huggingFace(home.appendingPathComponent(".cache/huggingface/hub"))
    models += nested(home.appendingPathComponent("jan/models"), depth: 1, provider: .jan)
    models += nested(support.appendingPathComponent("Jan/data/models"), depth: 1, provider: .jan)
    models += files(in: support.appendingPathComponent("nomic.ai/GPT4All"), provider: .gpt4all)
    models += files(in: home.appendingPathComponent(".cache/whisper"), provider: .whisper)
    models += appModels(support, skipping: ["nomic.ai", "Jan"], minimumBytes: minimumBytes)
    return AIModelScanResult(
      models: models.sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes },
      searched: [
        "~/.ollama", "~/.lmstudio", "~/.cache/huggingface", "~/.cache/whisper", "~/jan",
        "~/Library/Application Support",
      ])
  }

  /// Moves a model to Trash. Ollama blobs still used by another model are left in place.
  public static func moveToTrash(
    _ model: AIModel, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> [URL] {
    let homePath = home.standardizedFileURL.path + "/"
    var targets = model.files
    if model.provider == .ollama, let manifest = model.files.first {
      let shared = ollamaManifests(home.standardizedFileURL)
        .filter { $0.manifest.standardizedFileURL != manifest.standardizedFileURL }
        .reduce(into: Set<String>()) { $0.formUnion($1.blobs.map(\.lastPathComponent)) }
      targets = targets.filter { $0 == manifest || !shared.contains($0.lastPathComponent) }
    }
    for url in targets where !url.standardizedFileURL.path.hasPrefix(homePath) {
      throw AIModelError.outsideHome(url)
    }
    var moved: [URL] = []
    for url in targets where FileManager.default.fileExists(atPath: url.path) {
      try TrashService.validateCanonicalNonSymlink(url)
      var result: NSURL?
      try FileManager.default.trashItem(at: url, resultingItemURL: &result)
      moved.append((result as URL?) ?? url)
    }
    return moved
  }

  // MARK: Name details

  public static func details(for fileName: String) -> (
    format: String, parameters: String?, quantization: String?
  ) {
    let lower = fileName.lowercased()
    let ext = (lower as NSString).pathExtension
    let format: String
    switch ext {
    case "gguf": format = "GGUF"
    case "safetensors": format = "Safetensors"
    case "onnx": format = "ONNX"
    case "pt", "pth": format = "PyTorch"
    case "mlmodelc", "mlpackage": format = "Core ML"
    default: format = lower.hasPrefix("ggml") || ext == "ggml" ? "GGML" : ""
    }
    return (
      format,
      firstMatch(#"(?<![A-Za-z0-9.])(\d+(?:\.\d+)?[Bb])(?![A-Za-z])"#, in: fileName).map { $0.uppercased() },
      firstMatch(#"(?<=[-_.])(I?Q\d(?:_[A-Za-z0-9]+)*|BF16|FP16|F16|F32)(?=$|[-.])"#, in: fileName)
    )
  }

  public static func kind(for name: String) -> AIModelKind {
    let lower = name.lowercased()
    if ["whisper", "parakeet", "speech", "asr", "tts", "ggml-tiny", "ggml-base", "ggml-small",
      "ggml-medium", "ggml-large"].contains(where: lower.contains)
    {
      return .speech
    }
    if ["diffusion", "sdxl", "flux", "stable-", "dall"].contains(where: lower.contains) {
      return .image
    }
    if lower.contains("embed") { return .embedding }
    return .language
  }

  private static func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  // MARK: Providers

  struct OllamaManifest {
    let manifest: URL
    let name: String
    let blobs: [URL]
    let bytes: Int64
  }

  static func ollamaManifests(_ home: URL) -> [OllamaManifest] {
    let models = home.appendingPathComponent(".ollama/models")
    let root = models.appendingPathComponent("manifests").standardizedFileURL
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var result: [OllamaManifest] = []
    while let url = walker.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      // manifests/<registry>/<namespace>/<model>/<tag>
      let parts = url.standardizedFileURL.path.dropFirst(root.path.count + 1).split(separator: "/")
      guard parts.count == 4 else { continue }
      let registry = parts[0] == "registry.ollama.ai" ? "" : "\(parts[0])/"
      let namespace = parts[1] == "library" ? "" : "\(parts[1])/"
      let layers = ((json["layers"] as? [[String: Any]]) ?? []) + [json["config"] as? [String: Any] ?? [:]]
      var blobs: [URL] = []
      var bytes: Int64 = 0
      for layer in layers {
        guard let digest = layer["digest"] as? String else { continue }
        blobs.append(models.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-")))
        bytes += (layer["size"] as? NSNumber)?.int64Value ?? 0
      }
      result.append(
        OllamaManifest(manifest: url.standardizedFileURL, name: "\(registry)\(namespace)\(parts[2]):\(parts[3])", blobs: blobs, bytes: bytes))
    }
    return result
  }

  private static func ollama(_ home: URL) -> [AIModel] {
    ollamaManifests(home).map { entry in
      model(
        name: entry.name, provider: .ollama, format: "Ollama", detailsFrom: entry.name,
        bytes: entry.bytes, location: entry.manifest, files: [entry.manifest] + entry.blobs)
    }
  }

  /// One model per folder `depth` levels below `root` (LM Studio: publisher/repo).
  private static func nested(_ root: URL, depth: Int, provider: AIModelProvider) -> [AIModel] {
    var folders = [root]
    for _ in 0..<depth { folders = folders.flatMap(directories) }
    return folders.map { folder in
      let weights = largestFile(in: folder)
      return model(
        name: folder.lastPathComponent, provider: provider,
        format: weights.map { details(for: $0.lastPathComponent).format } ?? "",
        detailsFrom: weights?.lastPathComponent ?? folder.lastPathComponent,
        bytes: size(of: folder), location: folder, files: [folder])
    }
  }

  private static func huggingFace(_ hub: URL) -> [AIModel] {
    directories(hub).filter { $0.lastPathComponent.hasPrefix("models--") }.map { folder in
      let name = folder.lastPathComponent.dropFirst("models--".count)
        .replacingOccurrences(of: "--", with: "/")
      return model(
        name: name, provider: .huggingFace, format: "", detailsFrom: name,
        bytes: size(of: folder), location: folder, files: [folder])
    }
  }

  private static func files(in folder: URL, provider: AIModelProvider) -> [AIModel] {
    let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return items.filter { isModelFile($0) }.map { fileModel($0, provider: provider) }
  }

  private static func appModels(_ support: URL, skipping: Set<String>, minimumBytes: Int64) -> [AIModel] {
    var models: [AIModel] = []
    for app in directories(support) where !skipping.contains(app.lastPathComponent) {
      guard
        let walker = FileManager.default.enumerator(
          at: app, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      let provider = AIModelProvider.app(appName(app.lastPathComponent))
      // Core ML models often ship as several bundles (Encoder, Decoder…) in one model folder.
      var grouped = Set<String>()
      while let url = walker.nextObject() as? URL {
        if walker.level > 6 {
          walker.skipDescendants()
          continue
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if grouped.contains(parent.path) { continue }
        if bundleExtensions.contains(url.pathExtension.lowercased()) {
          walker.skipDescendants()
          let found: AIModel
          if parent.path != app.standardizedFileURL.path {
            grouped.insert(parent.path)
            found = model(
              name: parent.lastPathComponent, provider: provider, format: "Core ML",
              detailsFrom: parent.lastPathComponent, bytes: size(of: parent), location: parent,
              files: [parent])
          } else {
            found = fileModel(url, provider: provider)
          }
          if found.bytes >= minimumBytes { models.append(found) }
        } else if isModelFile(url) {
          let found = fileModel(url, provider: provider)
          if found.bytes >= minimumBytes { models.append(found) }
        }
      }
    }
    return models
  }

  // MARK: Helpers

  /// "ru.starmel.OpenSuperWhisper" → "OpenSuperWhisper"; plain folder names stay as they are.
  static func appName(_ folder: String) -> String {
    let parts = folder.split(separator: ".")
    return parts.count >= 3 ? String(parts.last!) : folder
  }

  private static func isModelFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return false }
    let name = url.lastPathComponent.lowercased()
    return modelExtensions.contains(url.pathExtension.lowercased())
      || (name.hasPrefix("ggml") && url.pathExtension.lowercased() == "bin")
  }

  private static func fileModel(_ url: URL, provider: AIModelProvider) -> AIModel {
    let info = details(for: url.lastPathComponent)
    return model(
      name: url.deletingPathExtension().lastPathComponent, provider: provider, format: info.format,
      detailsFrom: url.lastPathComponent, bytes: size(of: url), location: url, files: [url])
  }

  private static func model(
    name: String, provider: AIModelProvider, format: String, detailsFrom source: String,
    bytes: Int64, location: URL, files: [URL]
  ) -> AIModel {
    let info = details(for: source)
    let modified = (try? location.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    return AIModel(
      id: location.standardizedFileURL.path, name: name, provider: provider,
      kind: kind(for: name + " " + source), format: format.isEmpty ? info.format : format,
      parameters: info.parameters, quantization: info.quantization, bytes: bytes,
      modified: modified, location: location, files: files)
  }

  private static func directories(_ url: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])) ?? [])
      .filter {
        let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
      }
  }

  private static func largestFile(in folder: URL) -> URL? {
    let items = (try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return items.filter(isModelFile).max {
      ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        < ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
  }

  private static func size(of url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
    if values?.isRegularFile == true { return Int64(values?.totalFileAllocatedSize ?? 0) }
    return SizeTree.scan(url, minimumShare: 1, maxChildren: 0).root.bytes
  }
}

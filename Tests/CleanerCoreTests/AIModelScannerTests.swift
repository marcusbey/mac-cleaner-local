import Foundation
import XCTest

@testable import CleanerCore

final class AIModelScannerTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIModels-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let home { try? FileManager.default.removeItem(at: home) }
  }

  @discardableResult
  private func file(_ path: String, bytes: Int = 4096) throws -> URL {
    let url = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
  }

  private func ollamaManifest(_ path: String, layers: [(String, Int)]) throws {
    let json: [String: Any] = [
      "config": ["digest": "sha256:cfg\(path.count)", "size": 10],
      "layers": layers.map { ["digest": "sha256:\($0.0)", "size": $0.1] },
    ]
    let url = home.appendingPathComponent(".ollama/models/manifests/registry.ollama.ai/\(path)")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    for (digest, size) in layers {
      try file(".ollama/models/blobs/sha256-\(digest)", bytes: size)
    }
    try file(".ollama/models/blobs/sha256-cfg\(path.count)", bytes: 10)
  }

  func testOllamaModelsAreNamedFromManifestsAndSharedBlobsSurviveRemoval() throws {
    try ollamaManifest("library/llama3/8b", layers: [("shared", 2000), ("llamaweights", 9000)])
    try ollamaManifest("someone/coder/latest", layers: [("shared", 2000), ("coderweights", 5000)])

    let models = AIModelScanner.scan(home: home, minimumBytes: 0).models
    let ollama = models.filter { $0.provider == .ollama }
    XCTAssertEqual(Set(ollama.map(\.name)), ["llama3:8b", "someone/coder:latest"])
    let llama = try XCTUnwrap(ollama.first { $0.name == "llama3:8b" })
    XCTAssertEqual(llama.bytes, 2000 + 9000 + 10)

    let moved = try AIModelScanner.moveToTrash(llama, home: home)
    XCTAssertFalse(moved.isEmpty)
    let blobs = home.appendingPathComponent(".ollama/models/blobs")
    XCTAssertTrue(FileManager.default.fileExists(atPath: blobs.appendingPathComponent("sha256-shared").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appendingPathComponent("sha256-llamaweights").path))
    XCTAssertEqual(
      AIModelScanner.scan(home: home, minimumBytes: 0).models.filter { $0.provider == .ollama }.map(\.name),
      ["someone/coder:latest"])
    for url in moved { try? FileManager.default.removeItem(at: url) }
  }

  func testHuggingFaceLMStudioAndAppModelsAreFound() throws {
    try file(".cache/huggingface/hub/models--meta-llama--Llama-3.1-8B/blobs/abc", bytes: 8000)
    try file(".cache/huggingface/hub/datasets--squad/blobs/x", bytes: 8000)
    try file(".lmstudio/models/lmstudio-community/Qwen2.5-7B-GGUF/Qwen2.5-7B-Instruct-Q4_K_M.gguf", bytes: 6000)
    try file("Library/Application Support/Screen Studio/models/ggml-small.bin", bytes: 5000)
    try file("Library/Application Support/Some App/readme.txt", bytes: 9000)

    let models = AIModelScanner.scan(home: home, minimumBytes: 0).models
    let names = Dictionary(uniqueKeysWithValues: models.map { ($0.name, $0) })

    XCTAssertEqual(names["meta-llama/Llama-3.1-8B"]?.provider, .huggingFace)
    XCTAssertNil(names["squad"])
    let qwen = try XCTUnwrap(names["Qwen2.5-7B-GGUF"])
    XCTAssertEqual(qwen.provider, .lmStudio)
    XCTAssertEqual(qwen.quantization, "Q4_K_M")
    XCTAssertEqual(qwen.parameters, "7B")
    XCTAssertEqual(qwen.format, "GGUF")
    let whisper = try XCTUnwrap(names["ggml-small"])
    XCTAssertEqual(whisper.provider, .app("Screen Studio"))
    XCTAssertEqual(whisper.format, "GGML")
    XCTAssertFalse(models.contains { $0.name == "readme" })
  }

  func testMetadataParsingAndKinds() {
    let info = AIModelScanner.details(for: "Meta-Llama-3-8B-Instruct-Q4_K_M.gguf")
    XCTAssertEqual(info.parameters, "8B")
    XCTAssertEqual(info.quantization, "Q4_K_M")
    XCTAssertEqual(info.format, "GGUF")
    XCTAssertEqual(AIModelScanner.kind(for: "ggml-large-v3-turbo"), .speech)
    XCTAssertEqual(AIModelScanner.kind(for: "stable-diffusion-xl"), .image)
    XCTAssertEqual(AIModelScanner.kind(for: "llama3:8b"), .language)
  }

  func testRemovalRefusesFilesOutsideHome() throws {
    let outside = AIModel(
      id: "/tmp/x", name: "x", provider: .huggingFace, kind: .language, format: "",
      parameters: nil, quantization: nil, bytes: 1, modified: nil,
      location: URL(fileURLWithPath: "/tmp/x"), files: [URL(fileURLWithPath: "/tmp/x")])
    XCTAssertThrowsError(try AIModelScanner.moveToTrash(outside, home: home))
  }

  func testCoreMLPartsInOneFolderAreOneModel() throws {
    let base = "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml"
    try file("\(base)/Encoder.mlmodelc/weights/weight.bin", bytes: 7000)
    try file("\(base)/Decoder.mlmodelc/weights/weight.bin", bytes: 3000)

    let models = AIModelScanner.scan(home: home, minimumBytes: 0).models
    XCTAssertEqual(models.map(\.name), ["parakeet-tdt-0.6b-v3-coreml"])
    let parakeet = try XCTUnwrap(models.first)
    XCTAssertEqual(parakeet.kind, .speech)
    XCTAssertEqual(parakeet.parameters, "0.6B")
    XCTAssertEqual(parakeet.format, "Core ML")
    XCTAssertEqual(parakeet.files.map(\.lastPathComponent), ["parakeet-tdt-0.6b-v3-coreml"])
  }
}

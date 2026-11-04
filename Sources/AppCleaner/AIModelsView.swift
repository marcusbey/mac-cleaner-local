import AppKit
import CleanerCore
import SwiftUI

@MainActor private final class AIModelsModel: ObservableObject {
  @Published var models: [AIModel] = []
  @Published var searched: [String] = []
  @Published var scanning = false
  @Published var scanned = false
  @Published var message = ""

  var total: Int64 { models.reduce(0) { $0 + $1.bytes } }
  var largest: Int64 { models.map(\.bytes).max() ?? 1 }
  var byProvider: [(AIModelProvider, Int64)] {
    Dictionary(grouping: models, by: \.provider)
      .map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }) }
      .sorted { $0.1 > $1.1 }
  }

  func scan() {
    guard !scanning else { return }
    scanning = true
    Task {
      let result = await Task.detached(priority: .userInitiated) { AIModelScanner.scan() }.value
      models = result.models
      searched = result.searched
      scanning = false
      scanned = true
    }
  }

  func remove(_ model: AIModel) {
    Task {
      let result = await Task.detached { Result { try AIModelScanner.moveToTrash(model) } }.value
      switch result {
      case .success:
        models.removeAll { $0.id == model.id }
        message = "Moved \(model.name) (\(size(model.bytes))) to Trash. Empty Trash to free the space."
      case .failure(let error): message = error.localizedDescription
      }
    }
  }
}

struct AIModelsView: View {
  @StateObject private var model = AIModelsModel()
  @State private var pendingRemoval: AIModel?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("AI Models").font(.largeTitle.bold())
          Text("Local models from Ollama, LM Studio, Hugging Face, Whisper, and apps.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.scan()
        } label: {
          Label(model.scanned ? "Rescan" : "Scan", systemImage: "arrow.clockwise")
        }.buttonStyle(.borderedProminent).disabled(model.scanning)
      }
      if model.scanning && model.models.isEmpty {
        Spacer()
        ProgressView("Looking for models…").frame(maxWidth: .infinity)
        Spacer()
      } else if model.models.isEmpty {
        Spacer()
        ContentUnavailableView(
          "No local AI models found", systemImage: "cpu",
          description: Text("Searched \(model.searched.joined(separator: ", ")). Models under 50 MB inside apps are skipped."))
        Spacer()
      } else {
        summary
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
            ForEach(model.models) { card($0) }
          }.padding(.bottom, 8)
        }
      }
    }
    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { if !model.scanned { model.scan() } }
    .confirmationDialog(
      "Move \(pendingRemoval?.name ?? "") to Trash?",
      isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      presenting: pendingRemoval
    ) { item in
      Button("Move to Trash (\(size(item.bytes)))", role: .destructive) {
        model.remove(item)
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: { item in
      Text(removalNote(item))
    }
    .alert(
      "AI Models",
      isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })
    ) {
      Button("OK") { model.message = "" }
    } message: {
      Text(model.message)
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(size(model.total)).font(.system(size: 34, weight: .bold, design: .rounded))
        Text("in \(model.models.count) model\(model.models.count == 1 ? "" : "s")")
          .foregroundStyle(.secondary)
        Spacer()
      }
      GeometryReader { geometry in
        HStack(spacing: 2) {
          ForEach(model.byProvider, id: \.0) { provider, bytes in
            Rectangle().fill(providerColor(provider))
              .frame(width: max(4, geometry.size.width * Double(bytes) / Double(max(1, model.total))))
          }
        }.clipShape(Capsule())
      }.frame(height: 10)
      HStack(spacing: 14) {
        ForEach(model.byProvider, id: \.0) { provider, bytes in
          HStack(spacing: 6) {
            Circle().fill(providerColor(provider)).frame(width: 8, height: 8)
            Text(provider.displayName).font(.caption.bold())
            Text(size(bytes)).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(18)
    .background(panel, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(line))
  }

  private func card(_ item: AIModel) -> some View {
    let color = providerColor(item.provider)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 9).fill(
            LinearGradient(colors: [color, color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
          Image(systemName: kindIcon(item.kind)).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
        }.frame(width: 36, height: 36)
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name).font(.headline).lineLimit(2).truncationMode(.middle)
          Text("\(item.provider.displayName) · \(item.kind.rawValue)").font(.caption)
            .foregroundStyle(color)
        }
        Spacer(minLength: 0)
      }
      HStack(spacing: 6) {
        ForEach([item.format, item.parameters, item.quantization].compactMap { $0 }.filter { !$0.isEmpty }, id: \.self) {
          Text($0).font(.caption2.bold().monospaced())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(size(item.bytes)).font(.system(size: 22, weight: .semibold, design: .rounded))
          .monospacedDigit()
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.07))
            Capsule().fill(color)
              .frame(width: max(6, geometry.size.width * Double(item.bytes) / Double(max(1, model.largest))))
          }
        }.frame(height: 6)
      }
      HStack {
        Text(item.modified.map { "Updated \($0.formatted(date: .abbreviated, time: .omitted))" } ?? " ")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([item.location])
        } label: {
          Image(systemName: "magnifyingglass")
        }.help("Reveal in Finder")
        Button(role: .destructive) {
          pendingRemoval = item
        } label: {
          Image(systemName: "trash")
        }.help("Move to Trash")
      }
    }
    .padding(16)
    .background(panel, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.35)))
    .contextMenu {
      Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.location]) }
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.location.path, forType: .string)
      }
      Divider()
      Button("Move to Trash…", role: .destructive) { pendingRemoval = item }
    }
  }

  private func removalNote(_ item: AIModel) -> String {
    switch item.provider {
    case .ollama:
      "Removes the model from Ollama. Layers shared with other models are kept. Download again with ollama pull."
    case .app(let app):
      "\(app) uses this model. The app may stop that feature or download the model again."
    default:
      "\(item.location.path)\nYou can download it again from \(item.provider.displayName)."
    }
  }

  private func kindIcon(_ kind: AIModelKind) -> String {
    switch kind {
    case .language: "text.bubble.fill"
    case .speech: "waveform"
    case .image: "photo.fill"
    case .embedding: "point.3.connected.trianglepath.dotted"
    }
  }

  private func providerColor(_ provider: AIModelProvider) -> Color {
    switch provider {
    case .ollama: Color(hue: 0.47, saturation: 0.7, brightness: 0.85)
    case .lmStudio: Color(hue: 0.75, saturation: 0.6, brightness: 0.95)
    case .huggingFace: Color(hue: 0.12, saturation: 0.8, brightness: 1.0)
    case .gpt4all: Color(hue: 0.3, saturation: 0.65, brightness: 0.85)
    case .jan: Color(hue: 0.57, saturation: 0.7, brightness: 1.0)
    case .whisper: Color(hue: 0.92, saturation: 0.6, brightness: 1.0)
    case .app(let name):
      // Stable color per app name.
      Color(
        hue: Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }) / 997,
        saturation: 0.6, brightness: 0.95)
    }
  }
}

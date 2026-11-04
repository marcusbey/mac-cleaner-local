import AppKit
import SwiftUI

extension Section {
  var tint: Color {
    switch self {
    case .memory: Color(hue: 0.55, saturation: 0.65, brightness: 0.95)
    case .cleanup: Color(hue: 0.47, saturation: 0.65, brightness: 0.85)
    case .spaceMap: Color(hue: 0.75, saturation: 0.55, brightness: 0.95)
    case .aiModels: Color(hue: 0.88, saturation: 0.55, brightness: 0.95)
    case .applications: Color(hue: 0.60, saturation: 0.65, brightness: 1.0)
    case .startup: Color(hue: 0.10, saturation: 0.70, brightness: 1.0)
    case .remaining: Color(hue: 0.02, saturation: 0.60, brightness: 1.0)
    case .extensions: Color(hue: 0.30, saturation: 0.55, brightness: 0.85)
    case .updates: Color(hue: 0.52, saturation: 0.60, brightness: 0.95)
    }
  }
}

/// Left navigation: grouped rows with colored icon tiles, an accent pill for the current section.
struct SidePanel: View {
  @Binding var selection: Section
  let onSelect: () -> Void
  @State private var hovered: Section?

  static let groups: [(String, [Section])] = [
    ("Clean Up", [.memory, .cleanup, .spaceMap, .aiModels]),
    ("Applications", [.applications, .startup, .remaining, .extensions, .updates]),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.top, 38).padding(.bottom, 22)
      ForEach(Self.groups, id: \.0) { title, sections in
        Text(title.uppercased())
          .font(.system(size: 10.5, weight: .semibold)).tracking(1.1)
          .foregroundStyle(Color.white.opacity(0.45))
          .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
        VStack(spacing: 2) {
          ForEach(sections, id: \.self) { row($0) }
        }
      }
      Spacer()
      Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
        .padding(.horizontal, 12).padding(.bottom, 18)
    }
    .padding(.horizontal, 12)
    .frame(width: 212)
    .background(
      LinearGradient(
        colors: [Color(red: 0.03, green: 0.10, blue: 0.17), Color(red: 0.01, green: 0.06, blue: 0.11)],
        startPoint: .top, endPoint: .bottom)
    )
    .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 1) {
        Text("Mac Cleaner").font(.system(size: 15, weight: .bold))
        Text("Local").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.5))
      }
    }.padding(.horizontal, 10)
  }

  private func row(_ item: Section) -> some View {
    let isSelected = selection == item
    return Button {
      selection = item
      onSelect()
    } label: {
      HStack(spacing: 11) {
        ZStack {
          RoundedRectangle(cornerRadius: 7)
            .fill(isSelected ? Color.white.opacity(0.22) : item.tint.opacity(0.18))
          Image(systemName: item.icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected ? .white : item.tint)
        }.frame(width: 26, height: 26)
        Text(item.rawValue)
          .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(isSelected ? .white : Color.white.opacity(0.86))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 9).fill(
          isSelected
            ? AnyShapeStyle(
              LinearGradient(
                colors: [Color(red: 0.20, green: 0.45, blue: 0.95), Color(red: 0.42, green: 0.32, blue: 0.95)],
                startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(Color.white.opacity(hovered == item ? 0.07 : 0)))
      }
      .contentShape(RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
    .accessibilityLabel(item.rawValue)
  }
}

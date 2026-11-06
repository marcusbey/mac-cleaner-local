import SwiftUI

/// The app's standard row action: 30 pt tall, readable label, hover feedback, red tint when destructive.
struct RowButton: View {
  let title: String?
  let symbol: String
  var destructive = false
  let help: String
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  init(
    _ title: String?, symbol: String, destructive: Bool = false, help: String,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.symbol = symbol
    self.destructive = destructive
    self.help = help
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        if let title { Text(title).font(.system(size: 13, weight: .medium)) }
      }
      .padding(.horizontal, title == nil ? 0 : 11)
      .frame(minWidth: 32, minHeight: 30)
      .foregroundStyle(destructive ? Color(red: 1, green: 0.55, blue: 0.55) : .white)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(
          destructive
            ? Color.red.opacity(hovering ? 0.30 : 0.16)
            : Color.white.opacity(hovering ? 0.17 : 0.09)))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.35)
    .onHover { hovering = $0 && isEnabled }
    .help(help)
    .accessibilityLabel(title ?? help)
    .fixedSize()
  }
}

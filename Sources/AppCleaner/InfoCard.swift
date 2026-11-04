import SwiftUI

/// "How it works" explainer shown at the top of screens whose purpose isn't obvious.
struct InfoCard: View {
  let symbol: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.cyan)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.bold())
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.25)))
  }
}

import SwiftUI

struct EmptyStateCard: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(LensTheme.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LensTheme.secondaryText)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .panelStyle(cornerRadius: 18)
    }
}

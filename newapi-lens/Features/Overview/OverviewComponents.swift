import SwiftUI

struct TopModelsCard: View {
    let models: [TopModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Top 模型")
                .font(.headline)
                .foregroundStyle(LensTheme.primaryText)

            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(LensTheme.secondaryText)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(LensTheme.primaryText)
                        Text("token \(model.tokens.formatted(.number.grouping(.automatic)))")
                            .font(.caption)
                            .foregroundStyle(LensTheme.secondaryText)
                    }

                    Spacer()

                    Text(String(format: "¥ %.2f", model.amount))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(LensTheme.primaryText)
                }
                .padding(.vertical, 2)
            }
        }
        .panelStyle(cornerRadius: 18)
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
            Text(value)
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(LensTheme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(LensTheme.contentBackground)
        }
    }
}

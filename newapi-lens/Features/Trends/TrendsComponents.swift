import SwiftUI

struct ExpandableReportCard: View {
    let report: ReportGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(LensTheme.primaryText)
                        Text("token \(report.tokens.formatted(.number.grouping(.automatic)))")
                            .font(.caption)
                            .foregroundStyle(LensTheme.secondaryText)
                    }

                    Spacer()

                    Text(String(format: "¥ %.2f", report.amount))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(LensTheme.primaryText)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(LensTheme.secondaryText)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)

                VStack(spacing: 0) {
                    ForEach(report.children) { item in
                        HStack {
                            Text(item.label)
                                .foregroundStyle(LensTheme.secondaryText)
                            Spacer()
                            Text("token \(item.tokens.formatted(.number.grouping(.automatic)))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LensTheme.secondaryText)
                            Text(String(format: "¥ %.2f", item.amount))
                                .frame(width: 90, alignment: .trailing)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(LensTheme.primaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        if item.id != report.children.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LensTheme.contentBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LensTheme.cardStroke, lineWidth: 1)
        }
    }
}

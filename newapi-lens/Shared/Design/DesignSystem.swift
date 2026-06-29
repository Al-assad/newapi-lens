import SwiftUI
#if os(macOS)
import AppKit
#endif

enum LensTheme {
    static let windowBackground = Color.dynamic(light: 0xF5F7FB, dark: 0x11151C)
    static let contentBackground = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1F29)
    static let sidebarBackground = Color.dynamic(light: 0xEEF3FA, dark: 0x151A22)
    static let cardStroke = Color.dynamic(light: 0xD9E2EC, dark: 0x2D3748)
    static let primaryText = Color.dynamic(light: 0x16202A, dark: 0xF4F7FB)
    static let secondaryText = Color.dynamic(light: 0x5B6B7D, dark: 0xA4B0BF)
    static let tertiaryText = Color.dynamic(light: 0x7C8A99, dark: 0x8894A2)
    static let chipBackground = Color.dynamic(light: 0xE8EEF7, dark: 0x242C37)
    static let mutedFill = Color.dynamic(light: 0xDCE5F0, dark: 0x2B3440)
    static let overlayBackground = Color.dynamic(light: 0xF8FAFD, dark: 0x202733)
    static let barBackground = Color.dynamic(light: 0xF3F6FB, dark: 0x181D26)
}

struct LensBackground: View {
    var body: some View {
        LensTheme.windowBackground
            .ignoresSafeArea()
    }
}

struct FilterChip: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(LensTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(LensTheme.chipBackground)
            }
    }
}

struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }
}

struct StatCard: View {
    let title: String
    let primary: String
    let secondary: String
    let tint: Color
    var comparison: PeriodComparison? = nil
    var previousPeriodLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LensTheme.secondaryText)
                Spacer()
                if let previousPeriodLabel, let comparison {
                    PreviousPeriodBadge(
                        label: previousPeriodLabel,
                        amountText: currency(comparison.previousAmount)
                    )
                } else if let comparison {
                    ComparisonBadge(comparison: comparison, tint: tint)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle()
                                .fill(tint)
                                .frame(width: 8, height: 8)
                        }
                }
            }

            Text(primary)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LensTheme.primaryText)

            Text(secondary)
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .panelStyle()
    }

    private func currency(_ value: Double) -> String {
        String(format: "¥ %.2f", value)
    }
}

struct ComparisonBadge: View {
    let comparison: PeriodComparison
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
            Text(labelText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(foregroundColor.opacity(0.14))
        )
    }

    private var iconName: String {
        switch comparison.direction {
        case .up:
            return "arrow.up.right"
        case .down:
            return "arrow.down.right"
        case .flat:
            return "minus"
        case .unknown:
            return "questionmark"
        }
    }

    private var labelText: String {
        if let percent = comparison.percentChange {
            return String(format: "%.1f%%", abs(percent))
        }
        if comparison.currentAmount == 0, comparison.previousAmount == 0 {
            return "0.0%"
        }
        return "无对比"
    }

    private var foregroundColor: Color {
        switch comparison.direction {
        case .up:
            return .red
        case .down:
            return .green
        case .flat:
            return LensTheme.secondaryText
        case .unknown:
            return tint
        }
    }
}

struct PreviousPeriodBadge: View {
    let label: String
    let amountText: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
            Text(amountText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(LensTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }
}

extension View {
    func panelStyle(cornerRadius: CGFloat = 18) -> some View {
        self
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LensTheme.contentBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LensTheme.cardStroke, lineWidth: 1)
            }
    }

    #if os(macOS)
    func hoverCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
    #endif
}

extension Color {
    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let best = appearance.bestMatch(from: [.darkAqua, .aqua])
                return best == .darkAqua ? nsColor(hex: dark) : nsColor(hex: light)
            }
        )
    }

    fileprivate static func nsColor(hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return NSColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

#if os(macOS)
private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard hovering != isHovering else { return }

            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }

            isHovering = hovering
        }
    }
}
#endif

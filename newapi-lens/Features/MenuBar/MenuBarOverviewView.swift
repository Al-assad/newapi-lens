import SwiftUI

struct MenuBarOverviewView: View {
    @EnvironmentObject private var store: LensStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            actionBar
        }
        .padding(12)
        .frame(width: 328)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NewAPI Usage")
                    .font(.headline)
                    .foregroundStyle(LensTheme.primaryText)

                Text(store.latestSyncText)
                    .font(.caption)
                    .foregroundStyle(LensTheme.secondaryText)
            }

            Spacer()

            Button {
                Task {
                    await store.refresh()
                }
            } label: {
                ZStack {
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.accentColor)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading || !store.hasConfiguredAccounts)
            .opacity(store.isLoading ? 0.72 : 1)
            .menuBarCard(cornerRadius: 10, fillOpacity: 0.12, strokeOpacity: 0.16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .menuBarCard(cornerRadius: 18)
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasAccounts {
            emptyState(
                title: "还没有账户",
                message: "先添加账户后，menubar 才会显示余额和消耗。"
            )
        } else if !store.hasConfiguredAccounts {
            emptyState(
                title: "账户未配置完成",
                message: "请补全 host、user ID 和 token。"
            )
        } else if store.isLoading && store.dashboardData == nil {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView("正在加载数据...")
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if let errorMessage = store.errorMessage, store.dashboardData == nil {
            emptyState(
                title: "加载失败",
                message: errorMessage
            )
        } else {
            VStack(spacing: 10) {
                MenuBarMetricSection(
                    title: "当前余额",
                    primary: currency(store.snapshot.balanceAmount),
                    secondary: "quota \(number(store.snapshot.balanceQuota))",
                    comparison: nil,
                    previousPeriodLabel: nil
                )

                MenuBarMetricSection(
                    title: "今日消耗",
                    primary: currency(store.snapshot.todayAmount),
                    secondary: "token \(number(store.snapshot.todayTokens))",
                    comparison: store.snapshot.comparisons.today,
                    previousPeriodLabel: nil
                )

                MenuBarMetricSection(
                    title: "本周消耗",
                    primary: currency(store.snapshot.weekAmount),
                    secondary: "token \(number(store.snapshot.weekTokens))",
                    comparison: store.snapshot.comparisons.week,
                    previousPeriodLabel: "上周"
                )

                MenuBarMetricSection(
                    title: "本月消耗",
                    primary: currency(store.snapshot.monthAmount),
                    secondary: "token \(number(store.snapshot.monthTokens))",
                    comparison: store.snapshot.comparisons.month,
                    previousPeriodLabel: "上月"
                )
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                actionButton("主界面", systemImage: "macwindow") {
                    store.selectedSection = .data
                    openWindow(id: "main")
                }

                actionButton("退出", systemImage: "power") {
                    #if os(macOS)
                    NSApplication.shared.terminate(nil)
                    #endif
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .menuBarCard(cornerRadius: 14, fillOpacity: 0.12, strokeOpacity: 0.16)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LensTheme.primaryText)

            Text(message)
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .menuBarCard(cornerRadius: 18)
    }

    private func currency(_ value: Double) -> String {
        String(format: "¥ %.2f", value)
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private struct MenuBarMetricSection: View {
    let title: String
    let primary: String
    let secondary: String
    let comparison: PeriodComparison?
    let previousPeriodLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(LensTheme.secondaryText)

                Spacer()

                if let previousPeriodLabel, let comparison {
                    PreviousPeriodBadge(
                        label: previousPeriodLabel,
                        amountText: currency(comparison.previousAmount)
                    )
                } else if let comparison {
                    ComparisonBadge(comparison: comparison, tint: .blue)
                }
            }

            Text(primary)
                .font(.system(size: 23, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LensTheme.primaryText)

            Text(secondary)
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .menuBarCard(cornerRadius: 18)
    }

    private func currency(_ value: Double) -> String {
        String(format: "¥ %.2f", value)
    }
}

private extension View {
    func menuBarCard(
        cornerRadius: CGFloat,
        fillOpacity: Double = 0.08,
        strokeOpacity: Double = 0.14
    ) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(fillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            }
    }
}

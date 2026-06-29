import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: LensStore

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !store.hasAccounts {
                    EmptyStateCard(
                        title: "还没有账户",
                        message: "先添加一个 new-api 账户，才能查看余额、消费和模型统计。",
                        actionTitle: "去添加账户"
                    ) {
                        store.showAccounts()
                    }
                } else if !store.hasConfiguredAccounts {
                    EmptyStateCard(
                        title: "账户尚未配置完成",
                        message: "请补全服务地址、用户 ID 和访问令牌，然后再刷新统计数据。",
                        actionTitle: "去完善账户"
                    )
                    {
                        store.showAccounts()
                    }
                } else if store.isLoading && store.dashboardData == nil {
                    ProgressView("正在加载数据...")
                        .padding(.vertical, 40)
                } else if let errorMessage = store.errorMessage, store.dashboardData == nil {
                    errorCard(errorMessage)
                } else {
                    spotlight
                    metricsStrip

                    LazyVGrid(columns: columns, spacing: 16) {
                        StatCard(
                            title: "当前余额",
                            primary: currency(store.snapshot.balanceAmount),
                            secondary: "quota \(number(store.snapshot.balanceQuota))",
                            tint: .blue
                        )

                        StatCard(
                            title: "今日消耗",
                            primary: currency(store.snapshot.todayAmount),
                            secondary: "token \(number(store.snapshot.todayTokens))",
                            tint: .orange
                        )

                        StatCard(
                            title: "本周消耗",
                            primary: currency(store.snapshot.weekAmount),
                            secondary: "token \(number(store.snapshot.weekTokens))",
                            tint: .pink
                        )

                        StatCard(
                            title: "本月消耗",
                            primary: currency(store.snapshot.monthAmount),
                            secondary: "token \(number(store.snapshot.monthTokens))",
                            tint: .teal
                        )
                    }

                    TopModelsCard(models: store.topModels)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LensTheme.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("总览")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LensTheme.primaryText)
            }

            Spacer()

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spotlight: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("本月概览")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LensTheme.secondaryText)
                Text(currency(store.snapshot.monthAmount))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LensTheme.primaryText)
                Text("本月累计 \(number(store.snapshot.monthTokens)) token")
                    .font(.callout)
                    .foregroundStyle(LensTheme.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                FilterChip(title: "\(store.accounts.count) 个账户", icon: "server.rack")
            }
        }
        .panelStyle(cornerRadius: 18)
    }

    private var metricsStrip: some View {
        HStack(spacing: 10) {
            MetricPill(title: "今日", value: currency(store.snapshot.todayAmount), tint: .orange)
            MetricPill(title: "本周", value: currency(store.snapshot.weekAmount), tint: .pink)
            MetricPill(title: "本月", value: currency(store.snapshot.monthAmount), tint: .teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currency(_ value: Double) -> String {
        String(format: "¥ %.2f", value)
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("加载失败")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LensTheme.secondaryText)
            Text("请使用数据页右上角的刷新数据重新同步。")
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .panelStyle(cornerRadius: 18)
    }
}

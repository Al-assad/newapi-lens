import SwiftUI

struct TrendsView: View {
    @EnvironmentObject private var store: LensStore
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !store.hasAccounts {
                    EmptyStateCard(
                        title: "还没有账户",
                        message: "先添加一个 new-api 账户，才能查看趋势图和周期报表。",
                        actionTitle: "去添加账户"
                    ) {
                        store.showAccounts()
                    }
                } else if !store.hasConfiguredAccounts {
                    EmptyStateCard(
                        title: "账户尚未配置完成",
                        message: "请补全服务地址、用户 ID 和访问令牌，然后再查看趋势数据。",
                        actionTitle: "去完善账户"
                    )
                    {
                        store.showAccounts()
                    }
                } else {
                    controls
                    chartCard
                    reportSection
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
        VStack(alignment: .leading, spacing: 0) {
            Text("趋势")
                .font(.title2.weight(.semibold))
                .foregroundStyle(LensTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let coverageText = store.selectedCoverageText {
                Text(coverageText)
                    .font(.caption)
                    .foregroundStyle(LensTheme.secondaryText)
            }

            HStack(spacing: 12) {
                Picker("指标", selection: $store.selectedMetric) {
                    ForEach(MetricKind.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Picker("维度", selection: $store.selectedGranularity) {
                    ForEach(TrendGranularity.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Picker("范围", selection: $store.selectedPreset) {
                    ForEach([TimePreset.thisWeek, .lastWeek, .thisMonth, .sixMonths]) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            HStack(spacing: 12) {
                Picker("token_name", selection: $store.selectedTokenName) {
                    ForEach(store.tokenOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 220)

                Picker("model_name", selection: $store.selectedModelName) {
                    ForEach(store.modelOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 220)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartCard: some View {
        let points = selectedTrend
        let maxValue = max(1, points.map(chartValue).max() ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("柱状图")
                    .font(.headline)
                    .foregroundStyle(LensTheme.primaryText)
                Spacer()
                Text(summaryText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(LensTheme.secondaryText)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(points) { point in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: max(8, 200 * chartValue(point) / maxValue))

                        Text(point.label)
                            .font(.caption)
                            .foregroundStyle(LensTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 224)
        }
        .panelStyle(cornerRadius: 18)
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("表格")
                    .font(.headline)
                    .foregroundStyle(LensTheme.primaryText)

                Spacer()

                Picker("模式", selection: $store.selectedReportMode) {
                    ForEach(ReportMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            ForEach(reports) { report in
                ExpandableReportCard(
                    report: report,
                    isExpanded: expanded.contains(report.id),
                    onToggle: { toggle(report.id) }
                )
            }
        }
        .panelStyle(cornerRadius: 18)
    }

    private var selectedTrend: [TrendPoint] {
        switch store.selectedGranularity {
        case .day:
            store.dayTrend
        case .week:
            store.weekTrend
        case .month:
            store.monthTrend
        }
    }

    private var reports: [ReportGroup] {
        switch store.selectedReportMode {
        case .weekly:
            store.weeklyReports
        case .monthly:
            store.monthlyReports
        }
    }

    private var summaryText: String {
        let amount = selectedTrend.map(\.amount).reduce(0, +)
        let tokens = selectedTrend.map(\.tokens).reduce(0, +)
        if store.selectedMetric == .amount {
            return String(format: "总金额 ¥ %.2f", amount)
        }
        return "总 Token \(tokens.formatted(.number.grouping(.automatic)))"
    }

    private func chartValue(_ point: TrendPoint) -> Double {
        switch store.selectedMetric {
        case .amount: point.amount
        case .tokens: Double(point.tokens)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

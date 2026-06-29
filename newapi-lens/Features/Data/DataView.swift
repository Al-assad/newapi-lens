import Charts
import SwiftUI

struct DataView: View {
    @EnvironmentObject private var store: LensStore
    @State private var highlightedDistributionID: String?
    @State private var hoveredTrendID: String?

    private let panelSpacing: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(compact: proxy.size.width < 760)

                    if !store.hasAccounts {
                        EmptyStateCard(
                            title: "还没有账户",
                            message: "先添加一个 new-api 账户，才能查看数据统计和趋势分析。",
                            actionTitle: "去添加账户"
                        ) {
                            store.showAccounts()
                        }
                    } else if !store.hasConfiguredAccounts {
                        EmptyStateCard(
                            title: "账户尚未配置完成",
                            message: "请补全服务地址、用户 ID 和访问令牌，然后再刷新统计数据。",
                            actionTitle: "去完善账户"
                        ) {
                            store.showAccounts()
                        }
                    } else {
                        summarySection(width: proxy.size.width)
                        filtersSection(width: proxy.size.width)
                        trendSection
                        modelDistributionSection(width: proxy.size.width)
                        periodDetailSection(width: proxy.size.width)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LensTheme.windowBackground)
    }

    private func header(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    Text("数据")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LensTheme.primaryText)

                    HStack(spacing: 10) {
                        Text(store.latestSyncText)
                            .font(.caption)
                            .foregroundStyle(LensTheme.secondaryText)
                        refreshButton
                    }
                }
            } else {
                HStack(alignment: .top) {
                    Text("数据")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LensTheme.primaryText)

                    Spacer()

                    HStack(spacing: 10) {
                        Text(store.latestSyncText)
                            .font(.caption)
                            .foregroundStyle(LensTheme.secondaryText)
                        refreshButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refreshButton: some View {
        Button {
            Task {
                await store.refresh()
            }
        } label: {
            HStack(spacing: 6) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(store.isLoading ? "刷新中..." : "刷新数据")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isLoading || !store.hasConfiguredAccounts)
    }

    private func summarySection(width: CGFloat) -> some View {
        let columns = summaryColumns(for: width)

        return LazyVGrid(columns: columns, spacing: 16) {
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
                tint: .orange,
                comparison: store.snapshot.comparisons.today
            )
            StatCard(
                title: "本周消耗",
                primary: currency(store.snapshot.weekAmount),
                secondary: "token \(number(store.snapshot.weekTokens))",
                tint: .pink,
                comparison: store.snapshot.comparisons.week,
                previousPeriodLabel: "上周"
            )
            StatCard(
                title: "本月消耗",
                primary: currency(store.snapshot.monthAmount),
                secondary: "token \(number(store.snapshot.monthTokens))",
                tint: .teal,
                comparison: store.snapshot.comparisons.month,
                previousPeriodLabel: "上月"
            )
        }
    }

    private func filtersSection(width: CGFloat) -> some View {
        let columns = filterColumns(for: width)

        return VStack(alignment: .leading, spacing: 16) {
            Text("分析筛选")
                .font(.headline)
                .foregroundStyle(LensTheme.primaryText)

            if let coverageText = store.selectedCoverageText {
                Text(coverageText)
                    .font(.caption)
                    .foregroundStyle(LensTheme.secondaryText)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                FilterPicker(
                    title: "时间范围",
                    selection: Binding(
                        get: { store.selectedPreset },
                        set: { store.changePreset($0) }
                    ),
                    options: [.thisWeek, .thisMonth, .sixMonths, .custom]
                )

                SegmentedFilter(
                    title: "指标",
                    selection: $store.selectedMetric,
                    options: MetricKind.allCases
                )

                SegmentedFilter(
                    title: "粒度",
                    selection: $store.selectedGranularity,
                    options: TrendGranularity.allCases
                )
                StringFilterPicker(title: "账户", selection: $store.selectedAccountName, options: store.accountOptions)
                StringFilterPicker(title: "token 分组", selection: $store.selectedTokenName, options: store.tokenOptions)
                StringFilterPicker(title: "模型名称", selection: $store.selectedModelName, options: store.modelOptions)
            }

            if store.selectedPreset == .custom {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    CompactDateFilter(title: "开始日期", selection: $store.customRangeStart)
                    CompactDateFilter(title: "结束日期", selection: $store.customRangeEnd)
                }
                .onChange(of: store.customRangeStart) { _, _ in
                    store.changePreset(.custom)
                }
                .onChange(of: store.customRangeEnd) { _, _ in
                    store.changePreset(.custom)
                }
            }
        }
        .panelStyle(cornerRadius: 18)
    }

    private var trendSection: some View {
        let points = selectedTrend
        let barWidth = trendBarWidth(for: points.count)
        let axisLabels = visibleTrendAxisLabels(for: points)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("消耗趋势")
                    .font(.headline)
                    .foregroundStyle(LensTheme.primaryText)
                Spacer()
                if store.isFilteringData {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(store.analysisSummaryText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(LensTheme.secondaryText)
            }

            if points.isEmpty {
                emptyPanelText("当前筛选范围内暂无趋势数据。")
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("时间", point.id),
                        y: .value("值", chartValue(point)),
                        width: .fixed(barWidth)
                    )
                    .foregroundStyle(
                        hoveredTrendID == nil || hoveredTrendID == point.id
                            ? Color.accentColor.gradient
                            : Color.accentColor.opacity(0.5).gradient
                    )
                    .cornerRadius(6)
                }
                .chartXAxis {
                    AxisMarks(values: axisLabels) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8, dash: [4, 5]))
                            .foregroundStyle(LensTheme.cardStroke.opacity(0.55))
                        AxisTick(stroke: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(LensTheme.cardStroke.opacity(0.75))
                        AxisValueLabel {
                            if let rawLabel = value.as(String.self),
                               let point = points.first(where: { $0.id == rawLabel }) {
                                Text(trendAxisLabel(for: point))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(LensTheme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let plotRect = geometry[plotFrame]
                            let slotWidth = plotRect.width / CGFloat(max(points.count, 1))

                            ZStack(alignment: .topLeading) {
                                HStack(spacing: 0) {
                                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                                        Color.clear
                                            .contentShape(Rectangle())
                                            .hoverCursor()
                                            .onHover { isHovering in
                                                hoveredTrendID = isHovering ? point.id : (hoveredTrendID == point.id ? nil : hoveredTrendID)
                                            }
                                            .accessibilityLabel(point.label)
                                            .accessibilityValue(trendAccessibilityValue(for: point))
                                            .frame(width: slotWidth)
                                    }
                                }
                                .frame(width: plotRect.width, height: plotRect.height)
                                .position(
                                    x: plotRect.midX,
                                    y: plotRect.midY
                                )

                                if let hoveredPoint = hoveredTrendPoint(in: points),
                                   let hoveredIndex = points.firstIndex(where: { $0.id == hoveredPoint.id }) {
                                    trendTooltip(for: hoveredPoint)
                                        .frame(width: 168)
                                        .position(
                                            x: tooltipXPosition(
                                                plotRect: plotRect,
                                                slotWidth: slotWidth,
                                                index: hoveredIndex,
                                                tooltipWidth: 168
                                            ),
                                            y: tooltipYPosition(
                                                plotRect: plotRect,
                                                point: hoveredPoint,
                                                tooltipHeight: 76
                                            )
                                        )
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        }
                    }
                }
                .onChange(of: points.map(\.id)) { _, currentIDs in
                    if let hoveredTrendID, !currentIDs.contains(hoveredTrendID) {
                        self.hoveredTrendID = nil
                    }
                }
                .frame(height: 260)
            }
        }
        .panelStyle(cornerRadius: 18)
    }

    private func modelDistributionSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("模型分布")
                    .font(.headline)
                    .foregroundStyle(LensTheme.primaryText)
                Spacer()
                Text("\(store.modelDistribution.count) 个模型")
                    .font(.caption)
                    .foregroundStyle(LensTheme.secondaryText)
            }

            if store.modelDistribution.isEmpty {
                emptyPanelText("当前筛选范围内暂无模型分布数据。")
            } else if width < 640 {
                VStack(alignment: .leading, spacing: 20) {
                    donutChartCard
                    distributionLegend(compact: true, maxHeight: nil)
                }
                .padding(.top, 6)
                .padding(.horizontal, 6)
            } else {
                HStack(alignment: .center, spacing: 40) {
                    donutChartCard
                    distributionLegend(compact: false, maxHeight: 240)
                }
                .padding(.top, 10)
                .padding(.horizontal, 10)
            }
        }
        .panelStyle(cornerRadius: 18)
        .onAppear {
            DispatchQueue.main.async {
                syncHighlightedDistributionIfNeeded()
            }
        }
        .onChange(of: store.modelDistribution.map(\.id)) { _, _ in
            DispatchQueue.main.async {
                syncHighlightedDistributionIfNeeded()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            highlightedDistributionID = nil
        }
    }

    private var donutChartCard: some View {
        VStack(spacing: 12) {
            InteractiveDonutChart(
                slices: store.modelDistribution,
                selectedID: highlightedDistributionID,
                valueProvider: sectorValue(_:),
                colorProvider: color(for:),
                onSelect: { slice in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        highlightedDistributionID = slice?.id
                    }
                }
            )
            .frame(width: 220, height: 220)
            .overlay {
                VStack(spacing: 6) {
                    Text(activeDistributionSlice == nil ? (store.selectedMetric == .amount ? "总金额" : "总 Token") : "当前选中")
                        .font(.caption)
                        .foregroundStyle(LensTheme.secondaryText)
                    Text(centerValueText)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LensTheme.primaryText)
                    if let selectedSlice = activeDistributionSlice {
                        Text(centerSubtitleText(for: selectedSlice))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(color(for: selectedSlice))
                    } else if let dominant = store.modelDistribution.first {
                        Text("主模型 \(dominant.label)")
                            .font(.caption2)
                            .foregroundStyle(LensTheme.tertiaryText)
                    }
                }
            }
        }
        .frame(maxWidth: 264)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LensTheme.windowBackground.opacity(0.22))
        )
    }

    private func distributionLegend(compact: Bool, maxHeight: CGFloat?) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: compact ? 8 : 9) {
                ForEach(Array(store.modelDistribution.enumerated()), id: \.element.id) { index, slice in
                    let isActive = highlightedDistributionID == slice.id

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            highlightedDistributionID = highlightedDistributionID == slice.id ? nil : slice.id
                        }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(color(for: slice).opacity(isActive ? 0.24 : 0.16))
                                    .frame(width: isActive ? 32 : 28, height: isActive ? 32 : 28)
                                Circle()
                                    .fill(color(for: slice))
                                    .frame(width: 10, height: 10)
                            }
                            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isActive)

                            Text(slice.label)
                                .font(.body.weight(isActive ? .semibold : .medium))
                                .foregroundStyle(LensTheme.primaryText)
                                .lineLimit(1)

                            Text("#\(index + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isActive ? color(for: slice) : LensTheme.tertiaryText)

                            if index == 0 {
                                Text("主")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(color(for: slice).opacity(isActive ? 0.22 : 0.14))
                                    )
                                    .foregroundStyle(color(for: slice))
                            }

                            Spacer(minLength: 8)

                            legendInlineBar(for: slice, isActive: isActive, compact: compact)

                            Text(percentageText(for: slice))
                                .font(.caption.weight(isActive ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(isActive ? color(for: slice) : LensTheme.primaryText)
                                .frame(width: compact ? 42 : 46, alignment: .trailing)

                            if !compact {
                                Text(valueText(for: slice))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(isActive ? color(for: slice) : LensTheme.secondaryText)
                                    .frame(width: 72, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, compact ? 12 : 14)
                        .padding(.vertical, compact ? 10 : 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isActive ? color(for: slice).opacity(0.10) : LensTheme.windowBackground.opacity(0.18))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(isActive ? color(for: slice).opacity(0.42) : LensTheme.cardStroke, lineWidth: 1)
                        }
                        .shadow(color: isActive ? color(for: slice).opacity(0.10) : .clear, radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
    }

    private func legendInlineBar(for slice: DistributionSlice, isActive: Bool, compact: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(LensTheme.windowBackground.opacity(0.44))
                Capsule(style: .continuous)
                    .fill(color(for: slice).gradient)
                    .frame(width: max(8, proxy.size.width * percentageValue(for: slice)))
                    .shadow(color: color(for: slice).opacity(isActive ? 0.28 : 0), radius: 8, y: 0)
            }
        }
        .frame(width: compact ? 72 : 108, height: compact ? 6 : 7)
    }

    private func periodDetailSection(width: CGFloat) -> some View {
        let contentWidth = periodDetailContentWidth(for: width)
        let columnWidths = periodDetailColumnWidths(for: contentWidth)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("周期明细")
                    .font(.headline)
                    .foregroundStyle(LensTheme.primaryText)
                Spacer()
                FilterChip(title: store.selectedGranularity.rawValue, icon: "calendar")
            }

            if store.periodSummaryRows.isEmpty {
                emptyPanelText("当前筛选范围内暂无周期明细。")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 12) {
                            tableHeader("时间", width: columnWidths.time, alignment: .trailing)
                            tableHeader("金额", width: columnWidths.amount, alignment: .trailing)
                            tableHeader("Token", width: columnWidths.token, alignment: .trailing)
                            tableHeader("账户", width: columnWidths.account, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)

                        Divider()

                        ForEach(Array(store.periodSummaryRows.enumerated()), id: \.element.id) { index, row in
                            HStack(alignment: .top, spacing: 12) {
                                tableCell(row.title, width: columnWidths.time, alignment: .trailing)
                                tableCell(currency(row.amount), width: columnWidths.amount, alignment: .trailing, monospaced: true)
                                tableCell(number(row.tokens), width: columnWidths.token, alignment: .trailing, monospaced: true)
                                multilineCell(row.topAccounts, width: columnWidths.account, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)

                            if index != store.periodSummaryRows.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .frame(minWidth: contentWidth, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LensTheme.contentBackground.opacity(0.55))
                    )
                }
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

    private var centerValueText: String {
        if let selectedSlice = activeDistributionSlice {
            return store.selectedMetric == .amount ? currency(selectedSlice.amount) : number(selectedSlice.tokens)
        }
        if store.selectedMetric == .amount {
            let amount = store.modelDistribution.reduce(0) { $0 + $1.amount }
            return currency(amount)
        }
        let tokens = store.modelDistribution.reduce(0) { $0 + $1.tokens }
        return number(tokens)
    }

    private var activeDistributionSlice: DistributionSlice? {
        guard let highlightedDistributionID else { return nil }
        return store.modelDistribution.first(where: { $0.id == highlightedDistributionID })
    }

    private func chartValue(_ point: TrendPoint) -> Double {
        switch store.selectedMetric {
        case .amount:
            return point.amount
        case .tokens:
            return Double(point.tokens)
        }
    }

    private func trendBarWidth(for count: Int) -> CGFloat {
        let computedWidth = 320 / CGFloat(max(count, 1))
        return max(8, min(22, computedWidth))
    }

    private func visibleTrendAxisLabels(for points: [TrendPoint]) -> [String] {
        guard !points.isEmpty else { return [] }

        let targetCount: Double
        switch store.selectedGranularity {
        case .day:
            targetCount = 8
        case .week, .month:
            targetCount = 6
        }

        let step = max(1, Int(ceil(Double(points.count) / targetCount)))
        var labels = points.enumerated()
            .filter { index, _ in
                index == 0 || index == points.count - 1 || index % step == 0
            }
            .map(\.element.id)

        if let last = points.last?.id, labels.last != last {
            labels.append(last)
        }
        return labels
    }

    private func trendAxisLabel(for point: TrendPoint) -> String {
        switch store.selectedGranularity {
        case .day:
            return shortDateLabel(point.label)
        case .week:
            let parts = point.label.split(separator: "-")
            if parts.count >= 3 {
                return "\(parts[1])/\(parts[2])"
            }
            return shortDateLabel(point.label)
        case .month:
            return shortDateLabel(point.label)
        }
    }

    private func shortDateLabel(_ raw: String) -> String {
        if raw.contains("~") {
            let parts = raw.split(separator: "~").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = parts.first {
                return shortDateLabel(first)
            }
        }

        let parts = raw.split(separator: "-")
        if parts.count >= 3 {
            return "\(parts[1])/\(parts[2])"
        }
        if parts.count == 2 {
            return "\(parts[0])/\(parts[1])"
        }
        return raw
    }

    private func hoveredTrendPoint(in points: [TrendPoint]) -> TrendPoint? {
        guard let hoveredTrendID else { return nil }
        return points.first(where: { $0.id == hoveredTrendID })
    }

    private func trendAccessibilityValue(for point: TrendPoint) -> String {
        "金额 \(currency(point.amount))，Token \(number(point.tokens))"
    }

    private func trendTooltip(for point: TrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(point.label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(LensTheme.primaryText)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                Text("金额 \(currency(point.amount))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.selectedMetric == .amount ? LensTheme.primaryText : LensTheme.secondaryText)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: 7, height: 7)
                Text("Token \(number(point.tokens))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(store.selectedMetric == .tokens ? LensTheme.primaryText : LensTheme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LensTheme.contentBackground.opacity(0.96))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LensTheme.cardStroke.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func tooltipXPosition(plotRect: CGRect, slotWidth: CGFloat, index: Int, tooltipWidth: CGFloat) -> CGFloat {
        let center = plotRect.minX + slotWidth * (CGFloat(index) + 0.5)
        let halfWidth = tooltipWidth / 2
        return min(max(center, plotRect.minX + halfWidth), plotRect.maxX - halfWidth)
    }

    private func tooltipYPosition(plotRect: CGRect, point: TrendPoint, tooltipHeight: CGFloat) -> CGFloat {
        let maxValue = max(1, selectedTrend.map(chartValue).max() ?? 1)
        let normalizedValue = chartValue(point) / maxValue
        let rawY = plotRect.maxY - CGFloat(normalizedValue) * plotRect.height - tooltipHeight / 2 - 10
        let minY = plotRect.minY + tooltipHeight / 2 + 6
        let maxY = plotRect.maxY - tooltipHeight / 2 - 6
        return min(max(rawY, minY), maxY)
    }

    private func sectorValue(_ slice: DistributionSlice) -> Double {
        switch store.selectedMetric {
        case .amount:
            return slice.amount
        case .tokens:
            return Double(slice.tokens)
        }
    }

    private func detailText(for slice: DistributionSlice) -> String {
        if store.selectedMetric == .amount {
            return "token \(number(slice.tokens))"
        }
        return currency(slice.amount)
    }

    private func percentageText(for slice: DistributionSlice) -> String {
        let total = store.modelDistribution.reduce(0.0) { partial, item in
            partial + sectorValue(item)
        }
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", sectorValue(slice) / total * 100)
    }

    private func percentageValue(for slice: DistributionSlice) -> CGFloat {
        let total = store.modelDistribution.reduce(0.0) { partial, item in
            partial + sectorValue(item)
        }
        guard total > 0 else { return 0 }
        return CGFloat(sectorValue(slice) / total)
    }

    private func valueText(for slice: DistributionSlice) -> String {
        if store.selectedMetric == .amount {
            return currency(slice.amount)
        }
        return number(slice.tokens)
    }

    private func centerSubtitleText(for slice: DistributionSlice) -> String {
        "\(slice.label) · \(percentageText(for: slice))"
    }

    private func color(for slice: DistributionSlice) -> Color {
        let index = store.modelDistribution.firstIndex(where: { $0.id == slice.id }) ?? 0
        let palette: [Color] = [.blue, .teal, .orange, .pink, .green, .indigo]
        return palette[index % palette.count]
    }

    private func tableHeader(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(LensTheme.secondaryText)
            .frame(width: width, alignment: alignment)
    }

    private func tableCell(_ text: String, width: CGFloat, alignment: Alignment, monospaced: Bool = false) -> some View {
        Group {
            if monospaced {
                Text(text)
                    .font(.callout.monospacedDigit())
            } else {
                Text(text)
                    .font(.callout)
            }
        }
        .foregroundStyle(LensTheme.primaryText)
        .frame(width: width, alignment: alignment)
    }

    private func multilineCell(_ values: [String], width: CGFloat, alignment: Alignment) -> some View {
        let displayText = values.isEmpty ? "-" : values.joined(separator: " / ")

        return Text(displayText)
            .font(.callout)
            .foregroundStyle(values.isEmpty ? LensTheme.secondaryText : LensTheme.primaryText)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(width: width, alignment: alignment)
    }

    private func emptyPanelText(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(LensTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func currency(_ value: Double) -> String {
        String(format: "¥ %.2f", value)
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func summaryCardMinimumWidth(for width: CGFloat) -> CGFloat {
        if width < 640 {
            return 150
        }
        if width < 920 {
            return 160
        }
        if width < 1360 {
            return 180
        }
        return 220
    }

    private func summaryColumns(for width: CGFloat) -> [GridItem] {
        let minimumWidth = summaryCardMinimumWidth(for: width)
        let availableWidth = max(width - 40, minimumWidth)
        let columnCount: Int

        if width >= 640 {
            columnCount = 4
        } else if width >= 480 {
            columnCount = 2
        } else {
            columnCount = 1
        }

        let itemWidth = max(minimumWidth, (availableWidth - panelSpacing * CGFloat(max(columnCount - 1, 0))) / CGFloat(columnCount))
        return Array(repeating: GridItem(.flexible(minimum: itemWidth, maximum: itemWidth), spacing: panelSpacing), count: columnCount)
    }

    private func filterColumns(for width: CGFloat) -> [GridItem] {
        let columnCount: Int

        if width >= 1080 {
            columnCount = 6
        } else if width >= 640 {
            columnCount = 3
        } else if width >= 480 {
            columnCount = 2
        } else {
            columnCount = 1
        }

        return Array(repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: panelSpacing), count: columnCount)
    }

    private func periodDetailContentWidth(for width: CGFloat) -> CGFloat {
        max(width - 40, 0)
    }

    private func periodDetailColumnWidths(for contentWidth: CGFloat) -> (time: CGFloat, amount: CGFloat, token: CGFloat, account: CGFloat) {
        let horizontalPadding: CGFloat = 28
        let columnSpacing: CGFloat = 36
        let totalSpacing = horizontalPadding + columnSpacing
        let availableWidth = contentWidth - totalSpacing
        let columnWidth = floor(availableWidth / 4)

        return (
            time: columnWidth,
            amount: columnWidth,
            token: columnWidth,
            account: availableWidth - columnWidth * 3
        )
    }

    private func syncHighlightedDistributionIfNeeded() {
        guard !store.modelDistribution.isEmpty else {
            highlightedDistributionID = nil
            return
        }

        if let highlightedDistributionID,
           store.modelDistribution.contains(where: { $0.id == highlightedDistributionID }) {
            return
        }

        highlightedDistributionID = nil
    }
}

private struct InteractiveDonutChart: View {
    let slices: [DistributionSlice]
    let selectedID: String?
    let valueProvider: (DistributionSlice) -> Double
    let colorProvider: (DistributionSlice) -> Color
    let onSelect: (DistributionSlice?) -> Void

    private let ringThickness: CGFloat = 38
    private let gapDegrees: Double = 3.5

    var body: some View {
        GeometryReader { proxy in
            let frame = CGRect(origin: .zero, size: proxy.size)
            let total = max(slices.reduce(0) { $0 + max(0, valueProvider($1)) }, .leastNonzeroMagnitude)
            let segments = makeSegments(total: total)
            let activeID = selectedID ?? slices.first?.id

            ZStack {
                Circle()
                    .fill(LensTheme.windowBackground.opacity(0.28))
                    .overlay {
                        Circle()
                            .fill(LensTheme.contentBackground)
                            .padding(ringThickness)
                    }

                ForEach(Array(segments.enumerated()), id: \.element.slice.id) { index, segment in
                    let isActive = segment.slice.id == activeID
                    let inset: CGFloat = isActive ? 0 : 3
                    let segmentShape = DonutSectorShape(
                        startFraction: segment.start,
                        endFraction: segment.end,
                        thickness: ringThickness,
                        gapDegrees: gapDegrees,
                        inset: inset
                    )

                    segmentShape
                        .fill(colorProvider(segment.slice).gradient)
                        .opacity(activeID == nil || isActive ? 1 : 0.72)
                        .shadow(color: colorProvider(segment.slice).opacity(isActive ? 0.12 : 0), radius: 8, y: 2)
                        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: activeID)
                        .contentShape(segmentShape)
                        .onTapGesture {
                            onSelect(segment.slice)
                        }
                        .accessibilityLabel(segment.slice.label)
                        .accessibilityValue("\(Int((segment.end - segment.start) * 100))%")
                        .zIndex(Double(index))
                }
            }
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { gesture in
                        if let matched = segment(at: gesture.location, in: frame, segments: segments) {
                            onSelect(matched.slice)
                        } else {
                            onSelect(nil)
                        }
                    }
            )
        }
    }

    private func makeSegments(total: Double) -> [DonutSegment] {
        var start = 0.0
        return slices.map { slice in
            let value = max(0, valueProvider(slice))
            let fraction = value / total
            defer { start += fraction }
            return DonutSegment(slice: slice, start: start, end: start + fraction)
        }
    }

    private func segment(at location: CGPoint, in frame: CGRect, segments: [DonutSegment]) -> DonutSegment? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let outerRadius = min(frame.width, frame.height) / 2
        let innerRadius = outerRadius - ringThickness

        guard distance >= innerRadius - 12, distance <= outerRadius + 12 else {
            return nil
        }

        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 {
            angle += 360
        }

        let fraction = angle / 360
        return segments.first(where: { fraction >= $0.start && fraction <= $0.end })
    }
}

private struct DonutSectorShape: Shape {
    let startFraction: Double
    let endFraction: Double
    let thickness: CGFloat
    let gapDegrees: Double
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let outerRadius = max(0, min(rect.width, rect.height) / 2 - inset)
        let innerRadius = max(0, outerRadius - thickness)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startAngle = angle(for: startFraction) + gapDegrees / 2
        let endAngle = angle(for: endFraction) - gapDegrees / 2

        guard endAngle > startAngle, outerRadius > innerRadius else {
            return Path()
        }

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .degrees(endAngle),
            endAngle: .degrees(startAngle),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    private func angle(for fraction: Double) -> Double {
        fraction * 360 - 90
    }
}

private struct DonutSegment {
    let slice: DistributionSlice
    let start: Double
    let end: Double
}

private struct FilterPicker<Option: Identifiable & Hashable & RawRepresentable>: View where Option.RawValue == String {
    let title: String
    @Binding var selection: Option
    let options: [Option]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LensTheme.secondaryText)
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StringFilterPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LensTheme.secondaryText)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SegmentedFilter<Option: Identifiable & Hashable & RawRepresentable>: View where Option.RawValue == String {
    let title: String
    @Binding var selection: Option
    let options: [Option]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LensTheme.secondaryText)

            Picker("", selection: $selection) {
                ForEach(options) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactDateFilter: View {
    let title: String
    @Binding var selection: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LensTheme.secondaryText)
            DatePicker(title, selection: $selection, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

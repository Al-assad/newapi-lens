import Foundation

enum DashboardAggregator {
    static func build(
        liveSnapshots: [LiveAccountSnapshot],
        todayUsage: UsageAggregate,
        yesterdayUsage: UsageAggregate,
        weekUsage: UsageAggregate,
        lastWeekUsage: UsageAggregate,
        monthUsage: UsageAggregate,
        lastMonthUsage: UsageAggregate,
        topModels: [TopModel],
        modelOptions: [String],
        tokenOptions: [String]
    ) -> DashboardData {
        DashboardData(
            snapshot: UsageSnapshot(
                balanceQuota: liveSnapshots.reduce(0) { $0 + $1.balanceQuota },
                balanceAmount: liveSnapshots.reduce(0) { $0 + $1.balanceAmount },
                todayTokens: todayUsage.tokens,
                todayAmount: todayUsage.amount,
                weekTokens: weekUsage.tokens,
                weekAmount: weekUsage.amount,
                monthTokens: monthUsage.tokens,
                monthAmount: monthUsage.amount,
                comparisons: UsageComparisons(
                    today: PeriodComparison(
                        currentAmount: todayUsage.amount,
                        previousAmount: yesterdayUsage.amount
                    ),
                    week: PeriodComparison(
                        currentAmount: weekUsage.amount,
                        previousAmount: lastWeekUsage.amount
                    ),
                    month: PeriodComparison(
                        currentAmount: monthUsage.amount,
                        previousAmount: lastMonthUsage.amount
                    )
                )
            ),
            topModels: topModels,
            tokenOptions: tokenOptions,
            modelOptions: modelOptions
        )
    }

    static func trendPoints(
        logs: [StoredUsageLog],
        granularity: TrendGranularity
    ) -> [TrendPoint] {
        guard !logs.isEmpty else { return [] }

        let grouped = Dictionary(grouping: logs) { log in
            bucketLabel(timestamp: log.createdAt, granularity: granularity)
        }

        return grouped.keys.sorted().map { label in
            let items = grouped[label] ?? []
            return TrendPoint(
                id: label,
                label: label,
                amount: items.reduce(0) { $0 + $1.amount },
                tokens: items.reduce(0) { $0 + $1.tokenUsed }
            )
        }
    }

    static func reportGroups(
        logs: [StoredUsageLog],
        mode: ReportMode
    ) -> [ReportGroup] {
        guard !logs.isEmpty else { return [] }

        let grouped = Dictionary(grouping: logs) { log in
            switch mode {
            case .weekly:
                bucketLabel(timestamp: log.createdAt, granularity: .week)
            case .monthly:
                bucketLabel(timestamp: log.createdAt, granularity: .month)
            }
        }

        return grouped.keys.sorted(by: >).map { title in
            let parentLogs = grouped[title] ?? []
            let dailyGroups = Dictionary(grouping: parentLogs) { log in
                bucketLabel(timestamp: log.createdAt, granularity: .day)
            }

            let children = dailyGroups.keys.sorted().map { day in
                let dayLogs = dailyGroups[day] ?? []
                return DailyBreakdown(
                    id: day,
                    label: day,
                    amount: dayLogs.reduce(0) { $0 + $1.amount },
                    tokens: dayLogs.reduce(0) { $0 + $1.tokenUsed }
                )
            }

            return ReportGroup(
                id: title,
                title: title,
                amount: parentLogs.reduce(0) { $0 + $1.amount },
                tokens: parentLogs.reduce(0) { $0 + $1.tokenUsed },
                children: children
            )
        }
    }

    static func distributionByModel(logs: [StoredUsageLog]) -> [DistributionSlice] {
        Dictionary(grouping: logs, by: \.modelName)
            .map { label, items in
                DistributionSlice(
                    id: label,
                    label: label,
                    amount: items.reduce(0) { $0 + $1.amount },
                    tokens: items.reduce(0) { $0 + $1.tokenUsed }
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    static func periodSummaryRows(
        logs: [StoredUsageLog],
        accountsByID: [UUID: String],
        granularity: TrendGranularity
    ) -> [PeriodSummaryRow] {
        guard !logs.isEmpty else { return [] }

        let grouped = Dictionary(grouping: logs) { log in
            bucketLabel(timestamp: log.createdAt, granularity: granularity)
        }

        return grouped.keys.sorted(by: >).map { key in
            let items = grouped[key] ?? []
            return PeriodSummaryRow(
                id: key,
                title: key,
                amount: items.reduce(0) { $0 + $1.amount },
                tokens: items.reduce(0) { $0 + $1.tokenUsed },
                topModels: topLabels(
                    grouped: Dictionary(grouping: items, by: \.modelName)
                        .mapValues { group in group.reduce(0) { $0 + $1.amount } }
                ),
                topTokenGroups: topLabels(
                    grouped: Dictionary(grouping: items, by: \.tokenName)
                        .mapValues { group in group.reduce(0) { $0 + $1.amount } }
                ),
                topAccounts: topLabels(
                    grouped: Dictionary(grouping: items) { log in
                        accountsByID[log.accountID] ?? log.accountID.uuidString
                    }
                    .mapValues { group in group.reduce(0) { $0 + $1.amount } }
                )
            )
        }
    }

    private static func topLabels(grouped: [String: Double], limit: Int = 2) -> [String] {
        grouped
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func bucketLabel(timestamp: Int, granularity: TrendGranularity) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "zh_CN")

        switch granularity {
        case .day:
            formatter.dateFormat = "MM-dd"
            return formatter.string(from: date)
        case .week:
            let calendar = Calendar(identifier: .iso8601)
            let year = calendar.component(.yearForWeekOfYear, from: date)
            let week = calendar.component(.weekOfYear, from: date)
            return "\(year)-W\(String(format: "%02d", week))"
        case .month:
            formatter.dateFormat = "yyyy-MM"
            return formatter.string(from: date)
        }
    }
}

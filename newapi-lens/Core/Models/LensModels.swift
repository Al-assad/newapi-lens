import Foundation

enum TimePreset: String, CaseIterable, Identifiable {
    case today = "今天"
    case thisWeek = "本周"
    case thisMonth = "本月"
    case lastWeek = "上周"
    case sixMonths = "近 6 月"
    case custom = "自定义"

    var id: String { rawValue }
}

enum MetricKind: String, CaseIterable, Identifiable {
    case amount = "金额"
    case tokens = "Token"

    var id: String { rawValue }
}

enum TrendGranularity: String, CaseIterable, Identifiable {
    case day = "按天"
    case week = "按周"
    case month = "按月"

    var id: String { rawValue }
}

enum ReportMode: String, CaseIterable, Identifiable {
    case weekly = "按周"
    case monthly = "按月"

    var id: String { rawValue }
}

struct UsageSnapshot {
    let balanceQuota: Int
    let balanceAmount: Double
    let todayTokens: Int
    let todayAmount: Double
    let weekTokens: Int
    let weekAmount: Double
    let monthTokens: Int
    let monthAmount: Double
    let comparisons: UsageComparisons
}

struct UsageComparisons {
    let today: PeriodComparison
    let week: PeriodComparison
    let month: PeriodComparison
}

struct PeriodComparison {
    let currentAmount: Double
    let previousAmount: Double

    var percentChange: Double? {
        guard previousAmount > 0 else { return nil }
        return ((currentAmount - previousAmount) / previousAmount) * 100
    }

    var direction: ComparisonDirection {
        guard let percentChange else {
            if currentAmount == 0, previousAmount == 0 {
                return .flat
            }
            return .unknown
        }
        if percentChange > 0 {
            return .up
        }
        if percentChange < 0 {
            return .down
        }
        return .flat
    }
}

enum ComparisonDirection {
    case up
    case down
    case flat
    case unknown
}

struct TopModel: Identifiable {
    let id: String
    let name: String
    let amount: Double
    let tokens: Int
}

struct TrendPoint: Identifiable {
    let id: String
    let label: String
    let amount: Double
    let tokens: Int
}

struct DistributionSlice: Identifiable {
    let id: String
    let label: String
    let amount: Double
    let tokens: Int
}

struct DailyBreakdown: Identifiable {
    let id: String
    let label: String
    let amount: Double
    let tokens: Int
}

struct ReportGroup: Identifiable {
    let id: String
    let title: String
    let amount: Double
    let tokens: Int
    let children: [DailyBreakdown]
}

struct PeriodSummaryRow: Identifiable {
    let id: String
    let title: String
    let amount: Double
    let tokens: Int
    let topModels: [String]
    let topTokenGroups: [String]
    let topAccounts: [String]
}

struct UsageAggregate {
    let amount: Double
    let tokens: Int
    let count: Int
    let firstCreatedAt: Int?
    let lastCreatedAt: Int?
}

struct APIAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var token: String
    var userID: String
    var lastSync: String
    var lastSyncedAt: TimeInterval?
    var lastLogTimestamp: Int?

    var isConfigured: Bool {
        !host.isEmpty && !token.isEmpty && !userID.isEmpty
    }
}

struct APIAccountDraft {
    var id: UUID?
    var name: String = ""
    var host: String = ""
    var token: String = ""
    var userID: String = ""

    init() {}

    init(account: APIAccount) {
        id = account.id
        name = account.name
        host = account.host
        token = account.token
        userID = account.userID
    }
}

struct DashboardData {
    let snapshot: UsageSnapshot
    let topModels: [TopModel]
    let tokenOptions: [String]
    let modelOptions: [String]
}

struct LiveAccountSnapshot {
    let accountID: UUID
    let balanceQuota: Int
    let balanceAmount: Double
    let syncedAt: Date
}

enum AccountSyncStage: String {
    case detecting = "探测历史"
    case syncing = "同步数据"
}

struct AccountSyncProgress: Equatable {
    let stage: AccountSyncStage
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct AccountSyncStatus: Equatable {
    let message: String
    let currentDayLabel: String?
    let detectProgress: AccountSyncProgress?
    let syncProgress: AccountSyncProgress?

    static let incremental = AccountSyncStatus(
        message: "同步中",
        currentDayLabel: nil,
        detectProgress: nil,
        syncProgress: nil
    )

    static func detecting(scannedUnits: Int, totalUnits: Int, label: String) -> AccountSyncStatus {
        AccountSyncStatus(
            message: "探测历史中 \(scannedUnits)/\(totalUnits) \(label)",
            currentDayLabel: nil,
            detectProgress: AccountSyncProgress(
                stage: .detecting,
                completed: scannedUnits,
                total: totalUnits
            ),
            syncProgress: AccountSyncProgress(
                stage: .syncing,
                completed: 0,
                total: 1
            )
        )
    }

    static func fullReload(
        completedUnits: Int,
        totalUnits: Int,
        unitLabel: String = "天",
        currentDayLabel: String?
    ) -> AccountSyncStatus {
        AccountSyncStatus(
            message: "同步中 \(completedUnits)/\(totalUnits) \(unitLabel)",
            currentDayLabel: currentDayLabel,
            detectProgress: AccountSyncProgress(
                stage: .detecting,
                completed: 1,
                total: 1
            ),
            syncProgress: AccountSyncProgress(
                stage: .syncing,
                completed: completedUnits,
                total: totalUnits
            )
        )
    }
}

struct StoredUsageLog: Identifiable, Codable, Hashable {
    let id: String
    let accountID: UUID
    let createdAt: Int
    let tokenName: String
    let modelName: String
    let quota: Int
    let amount: Double
    let promptTokens: Int
    let completionTokens: Int

    var tokenUsed: Int {
        promptTokens + completionTokens
    }
}

struct NewAPIStatus {
    let quotaPerUnit: Int
    let displayInCurrency: Bool
    let quotaDisplayType: String
    let systemName: String
}

struct NewAPIUser {
    let id: Int
    let username: String
    let quota: Int
    let usedQuota: Int
    let group: String
}

struct NewAPILogEntry {
    let createdAt: Int
    let tokenName: String
    let modelName: String
    let quota: Int
    let amount: Double
    let promptTokens: Int
    let completionTokens: Int

    var tokenUsed: Int {
        promptTokens + completionTokens
    }
}

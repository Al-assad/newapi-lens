import Combine
import SwiftUI

@MainActor
final class LensStore: ObservableObject {
    @Published var isAutoRefreshEnabled = true {
        didSet {
            persistAutoRefreshSettings()
            updateAutoRefreshTask()
        }
    }
    @Published var autoRefreshIntervalMinutes = 5 {
        didSet {
            let normalizedValue = Self.normalizedAutoRefreshInterval(autoRefreshIntervalMinutes)
            guard autoRefreshIntervalMinutes == normalizedValue else {
                autoRefreshIntervalMinutes = normalizedValue
                return
            }
            persistAutoRefreshSettings()
            updateAutoRefreshTask()
        }
    }
    @Published var selectedSection: AppSection = .data
    @Published var selectedPreset: TimePreset = .thisMonth
    @Published var selectedMetric: MetricKind = .amount
    @Published var selectedGranularity: TrendGranularity = .day
    @Published var selectedReportMode: ReportMode = .weekly
    @Published var selectedTokenName: String = "全部"
    @Published var selectedModelName: String = "全部"
    @Published var selectedAccountName: String = "全部"
    @Published var customRangeStart: Date
    @Published var customRangeEnd: Date
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var dashboardData: DashboardData?
    @Published var testingAccountIDs: Set<UUID> = []
    @Published var accounts: [APIAccount] = []
    @Published var syncStatusByAccountID: [UUID: AccountSyncStatus] = [:]
    @Published private(set) var isFilteringData = false

    private let client = NewAPIClient()
    private let logRepository = UsageLogRepository()
    private let accountsKey = "newapi-lens.accounts.v2"
    private let autoRefreshEnabledKey = "newapi-lens.auto-refresh.enabled"
    private let autoRefreshIntervalKey = "newapi-lens.auto-refresh.interval-minutes"
    private let logBackfillMonths = 6
    private let incrementalSafetyWindow: TimeInterval = 30 * 60

    private var liveSnapshotsByAccountID: [UUID: LiveAccountSnapshot] = [:]
    private var activeOverrideSyncAccountIDs: Set<UUID> = [] {
        didSet {
            updateAutoRefreshTask()
        }
    }
    private var filteredDataSnapshot: FilteredDataCache?
    private var filteredDataRevision = 0
    private var filteredDataTask: Task<Void, Never>?
    private var filteredDataTaskKey: FilteredDataCacheKey?
    private var dashboardTask: Task<Void, Never>?
    private var dashboardTaskRevision = 0
    private var autoRefreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let now = Date()
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        _customRangeStart = Published(initialValue: monthStart)
        _customRangeEnd = Published(initialValue: now)
        loadAutoRefreshSettings()
        loadAccounts()
        setupFilterObservers()
        rebuildDashboard()
        updateAutoRefreshTask()
    }

    var hasAccounts: Bool {
        !accounts.isEmpty
    }

    var hasConfiguredAccounts: Bool {
        accounts.contains(where: \.isConfigured)
    }

    var isAutoRefreshPaused: Bool {
        isAutoRefreshEnabled && !activeOverrideSyncAccountIDs.isEmpty
    }

    var latestSyncText: String {
        let latestDate = accounts
            .compactMap(\.lastSyncedAt)
            .max()
            .map { Date(timeIntervalSince1970: $0) }

        guard let latestDate else { return "最后同步 未同步" }
        return "最后同步 \(timeText(for: latestDate))"
    }

    var snapshot: UsageSnapshot {
        dashboardData?.snapshot ?? UsageSnapshot(
            balanceQuota: 0,
            balanceAmount: 0,
            todayTokens: 0,
            todayAmount: 0,
            weekTokens: 0,
            weekAmount: 0,
            monthTokens: 0,
            monthAmount: 0,
            comparisons: UsageComparisons(
                today: PeriodComparison(currentAmount: 0, previousAmount: 0),
                week: PeriodComparison(currentAmount: 0, previousAmount: 0),
                month: PeriodComparison(currentAmount: 0, previousAmount: 0)
            )
        )
    }

    var topModels: [TopModel] {
        let models = dashboardData?.topModels ?? []
        guard selectedModelName != "全部" else { return models }
        return models.filter { $0.name == selectedModelName }
    }

    var tokenOptions: [String] { dashboardData?.tokenOptions ?? ["全部"] }
    var modelOptions: [String] { dashboardData?.modelOptions ?? ["全部"] }
    var accountOptions: [String] {
        ["全部"] + accounts.filter(\.isConfigured).map(\.name).sorted()
    }

    var dayTrend: [TrendPoint] {
        filteredData().dayTrend
    }

    var weekTrend: [TrendPoint] {
        filteredData().weekTrend
    }

    var monthTrend: [TrendPoint] {
        filteredData().monthTrend
    }

    var weeklyReports: [ReportGroup] {
        filteredData().weeklyReports
    }

    var monthlyReports: [ReportGroup] {
        filteredData().monthlyReports
    }

    var modelDistribution: [DistributionSlice] {
        filteredData().modelDistribution
    }

    var periodSummaryRows: [PeriodSummaryRow] {
        let data = filteredData()
        switch selectedGranularity {
        case .day:
            return data.daySummaryRows
        case .week:
            return data.weekSummaryRows
        case .month:
            return data.monthSummaryRows
        }
    }

    var analysisSummaryText: String {
        if selectedMetric == .amount {
            return String(format: "总金额 ¥ %.2f", filteredData().totalAmount)
        }
        return "总 Token \(filteredData().totalTokens.formatted(.number.grouping(.automatic)))"
    }

    var selectedCoverageText: String? {
        filteredData().coverageText
    }

    func refresh() async {
        await refresh(showAccountSyncStatus: false)
    }

    func refresh(showAccountSyncStatus: Bool) async {
        let configuredAccounts = accounts.filter(\.isConfigured)
        guard !configuredAccounts.isEmpty else {
            errorMessage = nil
            dashboardData = nil
            liveSnapshotsByAccountID = [:]
            syncStatusByAccountID = [:]
            invalidateFilteredDataCache()
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            for account in configuredAccounts {
                let result = try await syncAccount(
                    account,
                    forceFullReload: false,
                    showAccountSyncStatus: showAccountSyncStatus
                )
                applySyncResult(result)
            }
            rebuildDashboard()
        } catch {
            syncStatusByAccountID = [:]
            errorMessage = error.localizedDescription
            rebuildDashboard()
        }
    }

    func resyncAccount(_ account: APIAccount) async {
        await resyncAccount(account, startDate: defaultResyncStartDate())
    }

    func resyncAccount(_ account: APIAccount, startDate: Date) async {
        guard account.isConfigured else { return }

        errorMessage = nil
        syncStatusByAccountID[account.id] = .detecting(scannedUnits: 0, totalUnits: 1, label: "段")
        activeOverrideSyncAccountIDs.insert(account.id)
        defer { activeOverrideSyncAccountIDs.remove(account.id) }

        do {
            let result = try await syncAccount(
                account,
                forceFullReload: true,
                overrideStartDate: Calendar.current.startOfDay(for: startDate)
            )
            applySyncResult(result)
            rebuildDashboard()
        } catch {
            syncStatusByAccountID.removeValue(forKey: account.id)
            errorMessage = error.localizedDescription
            rebuildDashboard()
        }
    }

    func defaultResyncStartDate() -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .month, value: -1, to: today) ?? today
    }

    func saveAccount(from draft: APIAccountDraft) {
        let normalizedHost = normalizedHost(draft.host)

        if let id = draft.id, let index = accounts.firstIndex(where: { $0.id == id }) {
            let existing = accounts[index]
            accounts[index].name = draft.name
            accounts[index].host = normalizedHost
            accounts[index].token = draft.token
            accounts[index].userID = draft.userID

            if existing.host != normalizedHost || existing.userID != draft.userID || existing.token != draft.token {
                accounts[index].lastLogTimestamp = nil
                _ = logRepository.deleteLogs(for: id)
            }
        } else {
            accounts.append(
                APIAccount(
                    id: UUID(),
                    name: draft.name,
                    host: normalizedHost,
                    token: draft.token,
                    userID: draft.userID,
                    lastSync: "未同步",
                    lastSyncedAt: nil,
                    lastLogTimestamp: nil
                )
            )
        }

        persistAccounts()
        rebuildDashboard()
    }

    func deleteAccount(_ account: APIAccount) {
        accounts.removeAll { $0.id == account.id }
        liveSnapshotsByAccountID.removeValue(forKey: account.id)
        _ = logRepository.deleteLogs(for: account.id)
        persistAccounts()
        rebuildDashboard()
    }

    func testAccount(_ draft: APIAccountDraft) async throws {
        let temp = APIAccount(
            id: draft.id ?? UUID(),
            name: draft.name,
            host: normalizedHost(draft.host),
            token: draft.token,
            userID: draft.userID,
            lastSync: "未同步",
            lastSyncedAt: nil,
            lastLogTimestamp: nil
        )

        testingAccountIDs.insert(temp.id)
        defer { testingAccountIDs.remove(temp.id) }

        _ = try await client.fetchStatus(account: temp)
        _ = try await client.fetchUser(account: temp)
    }

    func showAccounts() {
        selectedSection = .accounts
    }

    func changePreset(_ preset: TimePreset) {
        selectedPreset = preset
        if preset == .custom {
            normalizeCustomRange()
        }
        selectedGranularity = defaultGranularity(for: preset)
    }

    private func rebuildDashboard() {
        invalidateFilteredDataCache()
        dashboardTaskRevision += 1
        let revision = dashboardTaskRevision
        dashboardTask?.cancel()

        let activeAccountIDs = Set(accounts.filter(\.isConfigured).map(\.id))
        let liveSnapshots = liveSnapshotsByAccountID
            .values
            .filter { activeAccountIDs.contains($0.accountID) }
            .sorted { $0.accountID.uuidString < $1.accountID.uuidString }

        if activeAccountIDs.isEmpty {
            dashboardData = nil
            normalizeSelections()
            return
        }

        let accountIDs = Array(activeAccountIDs)
        dashboardTask = Task.detached(priority: .userInitiated) { [liveSnapshots] in
            let data = Self.buildDashboardData(accountIDs: accountIDs, liveSnapshots: liveSnapshots)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.dashboardTaskRevision == revision else { return }
                self.dashboardData = data
                self.dashboardTask = nil
                self.normalizeSelections()
                self.scheduleFilteredDataRefresh(force: true)
            }
        }
    }

    private func normalizedHost(_ value: String) -> String {
        value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([APIAccount].self, from: data) {
            accounts = decoded
            return
        }

        if let legacyData = UserDefaults.standard.data(forKey: "newapi-lens.accounts.v1"),
           let decoded = try? JSONDecoder().decode([APIAccount].self, from: legacyData) {
            accounts = decoded
            persistAccounts()
            return
        }

        accounts = []
    }

    private func loadAutoRefreshSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: autoRefreshEnabledKey) != nil {
            isAutoRefreshEnabled = defaults.bool(forKey: autoRefreshEnabledKey)
        }

        if defaults.object(forKey: autoRefreshIntervalKey) != nil {
            autoRefreshIntervalMinutes = Self.normalizedAutoRefreshInterval(
                defaults.integer(forKey: autoRefreshIntervalKey)
            )
        }
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        invalidateFilteredDataCache()
    }

    private func persistAutoRefreshSettings() {
        let defaults = UserDefaults.standard
        defaults.set(isAutoRefreshEnabled, forKey: autoRefreshEnabledKey)
        defaults.set(autoRefreshIntervalMinutes, forKey: autoRefreshIntervalKey)
    }

    private func updateAutoRefreshTask() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard isAutoRefreshEnabled, activeOverrideSyncAccountIDs.isEmpty else { return }

        let intervalSeconds = TimeInterval(autoRefreshIntervalMinutes * 60)
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.performAutoRefreshTick()
            }
        }
    }

    private func performAutoRefreshTick() async {
        guard isAutoRefreshEnabled, activeOverrideSyncAccountIDs.isEmpty, !isLoading else { return }
        await refresh()
    }

    nonisolated private static func normalizedAutoRefreshInterval(_ value: Int) -> Int {
        min(max(value, 1), 240)
    }

    private func updateSyncState(for id: UUID, syncedAt: Date, lastLogTimestamp: Int?) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastSync = timeText(for: syncedAt)
        accounts[index].lastSyncedAt = syncedAt.timeIntervalSince1970
        accounts[index].lastLogTimestamp = lastLogTimestamp
        persistAccounts()
    }

    private func normalizeSelections() {
        if !tokenOptions.contains(selectedTokenName) {
            selectedTokenName = "全部"
        }
        if !modelOptions.contains(selectedModelName) {
            selectedModelName = "全部"
        }
        if !accountOptions.contains(selectedAccountName) {
            selectedAccountName = "全部"
        }
    }

    private func timeText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func dateRange(for preset: TimePreset) -> (start: Int, end: Int) {
        Self.dateRange(
            for: preset,
            now: Date(),
            customRangeStart: customRangeStart,
            customRangeEnd: customRangeEnd
        )
    }

    nonisolated private static func dateRange(
        for preset: TimePreset,
        now: Date,
        customRangeStart: Date? = nil,
        customRangeEnd: Date? = nil
    ) -> (start: Int, end: Int) {
        let calendar = Calendar.current
        let interval: DateInterval

        switch preset {
        case .today:
            let start = calendar.startOfDay(for: now)
            interval = DateInterval(start: start, end: now)
        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            interval = DateInterval(start: start, end: now)
        case .lastWeek:
            let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
            interval = DateInterval(start: start, end: thisWeekStart)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            interval = DateInterval(start: start, end: now)
        case .sixMonths:
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart
            interval = DateInterval(start: start, end: now)
        case .custom:
            let startDate = min(customRangeStart ?? now, customRangeEnd ?? now)
            let endDate = max(customRangeStart ?? now, customRangeEnd ?? now)
            let start = calendar.startOfDay(for: startDate)
            let endDay = calendar.startOfDay(for: endDate)
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            interval = DateInterval(start: start, end: end)
        }

        return (Int(interval.start.timeIntervalSince1970), Int(interval.end.timeIntervalSince1970))
    }

    private func previousDateRange(for preset: TimePreset) -> (start: Int, end: Int) {
        Self.previousDateRange(for: preset, now: Date())
    }

    nonisolated private static func previousDateRange(for preset: TimePreset, now: Date) -> (start: Int, end: Int) {
        let calendar = Calendar.current
        let interval: DateInterval

        switch preset {
        case .today:
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            interval = DateInterval(start: yesterdayStart, end: todayStart)
        case .thisWeek:
            let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
            interval = DateInterval(start: lastWeekStart, end: thisWeekStart)
        case .thisMonth:
            let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart) ?? thisMonthStart
            interval = DateInterval(start: lastMonthStart, end: thisMonthStart)
        case .lastWeek, .sixMonths, .custom:
            return (start: 0, end: 0)
        }

        return (Int(interval.start.timeIntervalSince1970), Int(interval.end.timeIntervalSince1970) - 1)
    }

    private func defaultGranularity(for preset: TimePreset) -> TrendGranularity {
        switch preset {
        case .thisWeek, .thisMonth, .today, .lastWeek:
            return .day
        case .sixMonths:
            return .month
        case .custom:
            return defaultGranularityForCustomRange()
        }
    }

    private func defaultGranularityForCustomRange() -> TrendGranularity {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(customRangeStart, customRangeEnd))
        let end = calendar.startOfDay(for: max(customRangeStart, customRangeEnd))
        let span = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
        if span <= 31 {
            return .day
        }
        if span <= 120 {
            return .week
        }
        return .month
    }

    private func normalizeCustomRange() {
        if customRangeStart > customRangeEnd {
            swap(&customRangeStart, &customRangeEnd)
        }
    }

    private func invalidateFilteredDataCache() {
        filteredDataRevision += 1
        filteredDataSnapshot = nil
        filteredDataTask?.cancel()
        filteredDataTask = nil
        filteredDataTaskKey = nil
        isFilteringData = false
    }

    nonisolated private static func buildDashboardData(
        accountIDs: [UUID],
        liveSnapshots: [LiveAccountSnapshot]
    ) -> DashboardData {
        let repository = UsageLogRepository()
        let now = Date()
        let todayRange = dateRange(for: .today, now: now)
        let yesterdayRange = previousDateRange(for: .today, now: now)
        let weekRange = dateRange(for: .thisWeek, now: now)
        let lastWeekRange = previousDateRange(for: .thisWeek, now: now)
        let monthRange = dateRange(for: .thisMonth, now: now)
        let lastMonthRange = previousDateRange(for: .thisMonth, now: now)

        let todayUsage = repository.aggregateUsage(accountIDs: accountIDs, start: todayRange.start, end: todayRange.end)
        let yesterdayUsage = repository.aggregateUsage(accountIDs: accountIDs, start: yesterdayRange.start, end: yesterdayRange.end)
        let weekUsage = repository.aggregateUsage(accountIDs: accountIDs, start: weekRange.start, end: weekRange.end)
        let lastWeekUsage = repository.aggregateUsage(accountIDs: accountIDs, start: lastWeekRange.start, end: lastWeekRange.end)
        let monthUsage = repository.aggregateUsage(accountIDs: accountIDs, start: monthRange.start, end: monthRange.end)
        let lastMonthUsage = repository.aggregateUsage(accountIDs: accountIDs, start: lastMonthRange.start, end: lastMonthRange.end)
        let tokenOptions = ["全部"] + repository.distinctTokenNames(accountIDs: accountIDs)
        let modelOptions = ["全部"] + repository.distinctModelNames(accountIDs: accountIDs)
        let topModels = repository.topModels(accountIDs: accountIDs, start: monthRange.start, end: monthRange.end)

        return DashboardAggregator.build(
            liveSnapshots: liveSnapshots,
            todayUsage: todayUsage,
            yesterdayUsage: yesterdayUsage,
            weekUsage: weekUsage,
            lastWeekUsage: lastWeekUsage,
            monthUsage: monthUsage,
            lastMonthUsage: lastMonthUsage,
            topModels: topModels,
            modelOptions: modelOptions,
            tokenOptions: tokenOptions
        )
    }

    private func filteredData() -> FilteredDataCache {
        let key = currentFilteredDataKey()
        if let filteredDataSnapshot, filteredDataSnapshot.key == key {
            return filteredDataSnapshot
        }
        if let filteredDataSnapshot {
            return filteredDataSnapshot
        }
        return FilteredDataCache.empty(key: key)
    }

    private func currentFilteredDataKey(for preset: TimePreset? = nil) -> FilteredDataCacheKey {
        let effectivePreset = preset ?? selectedPreset
        let accountIDs = selectedAccountIDs().sorted { $0.uuidString < $1.uuidString }
        let range = dateRange(for: effectivePreset)

        return FilteredDataCacheKey(
            revision: filteredDataRevision,
            accountIDs: accountIDs,
            start: range.start,
            end: range.end,
            tokenName: selectedTokenName,
            modelName: selectedModelName,
            granularity: selectedGranularity,
            reportMode: selectedReportMode
        )
    }

    private func setupFilterObservers() {
        Publishers.MergeMany(
            $selectedPreset.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $selectedTokenName.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $selectedModelName.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $selectedAccountName.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $selectedGranularity.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $selectedReportMode.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $customRangeStart.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $customRangeEnd.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.scheduleFilteredDataRefresh(force: true)
            }
        }
        .store(in: &cancellables)
    }

    private func scheduleFilteredDataRefresh(force: Bool = false) {
        let key = currentFilteredDataKey()

        if !force, let filteredDataSnapshot, filteredDataSnapshot.key == key {
            return
        }
        if filteredDataTaskKey == key {
            return
        }

        filteredDataTask?.cancel()

        guard !key.accountIDs.isEmpty else {
            filteredDataSnapshot = FilteredDataCache.empty(key: key)
            filteredDataTask = nil
            filteredDataTaskKey = nil
            isFilteringData = false
            return
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        filteredDataTaskKey = key
        isFilteringData = true

        filteredDataTask = Task.detached(priority: .userInitiated) {
            let data = Self.buildFilteredData(
                key: key,
                accountsByID: accountsByID
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.filteredDataTaskKey == key else { return }
                self.filteredDataSnapshot = data
                self.filteredDataTask = nil
                self.filteredDataTaskKey = nil
                self.isFilteringData = false
            }
        }
    }

    nonisolated private static func buildFilteredData(
        key: FilteredDataCacheKey,
        accountsByID: [UUID: String]
    ) -> FilteredDataCache {
        guard !key.accountIDs.isEmpty else {
            return FilteredDataCache.empty(key: key)
        }

        let repository = UsageLogRepository()
        let aggregate = repository.aggregateUsage(
            accountIDs: key.accountIDs,
            start: key.start,
            end: key.end,
            tokenName: key.tokenName,
            modelName: key.modelName
        )

        return FilteredDataCache(
            key: key,
            totalAmount: aggregate.amount,
            totalTokens: aggregate.tokens,
            coverageText: makeCoverageText(
                firstCreatedAt: aggregate.firstCreatedAt,
                lastCreatedAt: aggregate.lastCreatedAt,
                count: aggregate.count
            ),
            dayTrend: key.granularity == .day ? repository.trendPoints(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                granularity: .day
            ) : [],
            weekTrend: key.granularity == .week ? repository.trendPoints(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                granularity: .week
            ) : [],
            monthTrend: key.granularity == .month ? repository.trendPoints(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                granularity: .month
            ) : [],
            weeklyReports: key.reportMode == .weekly ? repository.reportGroups(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                mode: .weekly
            ) : [],
            monthlyReports: key.reportMode == .monthly ? repository.reportGroups(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                mode: .monthly
            ) : [],
            modelDistribution: repository.distributionByModel(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName
            ),
            daySummaryRows: key.granularity == .day ? repository.periodSummaryRows(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                accountsByID: accountsByID,
                granularity: .day
            ) : [],
            weekSummaryRows: key.granularity == .week ? repository.periodSummaryRows(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                accountsByID: accountsByID,
                granularity: .week
            ) : [],
            monthSummaryRows: key.granularity == .month ? repository.periodSummaryRows(
                accountIDs: key.accountIDs,
                start: key.start,
                end: key.end,
                tokenName: key.tokenName,
                modelName: key.modelName,
                accountsByID: accountsByID,
                granularity: .month
            ) : []
        )
    }

    nonisolated private static func makeCoverageText(
        firstCreatedAt: Int?,
        lastCreatedAt: Int?,
        count: Int
    ) -> String? {
        guard let firstCreatedAt, let lastCreatedAt, count > 0 else { return nil }
        let calendar = Calendar.current
        let startDate = Date(timeIntervalSince1970: TimeInterval(firstCreatedAt))
        let endDate = Date(timeIntervalSince1970: TimeInterval(lastCreatedAt))
        let dayCount = max(1, (calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: startDate),
            to: calendar.startOfDay(for: endDate)
        ).day ?? 0) + 1)

        return "数据覆盖 \(dayLabelText(for: startDate)) ~ \(dayLabelText(for: endDate))，\(dayCount) 天，\(count.formatted(.number.grouping(.automatic))) 条"
    }

    private func selectedAccountIDs() -> [UUID] {
        let configuredAccounts = accounts.filter(\.isConfigured)
        guard selectedAccountName != "全部" else {
            return configuredAccounts.map(\.id)
        }
        return configuredAccounts
            .filter { $0.name == selectedAccountName }
            .map(\.id)
    }
    private func accountName(for id: UUID) -> String {
        accounts.first(where: { $0.id == id })?.name ?? id.uuidString
    }

    private func applySyncResult(_ result: AccountSyncResult) {
        liveSnapshotsByAccountID[result.accountID] = result.liveSnapshot

        if result.didFullReload {
            _ = logRepository.replaceLogs(for: result.accountID, with: result.logs)
        } else {
            _ = logRepository.mergeIncrementalLogs(for: result.accountID, incoming: result.logs)
        }

        updateSyncState(
            for: result.accountID,
            syncedAt: result.liveSnapshot.syncedAt,
            lastLogTimestamp: result.lastLogTimestamp
        )
        invalidateFilteredDataCache()
        syncStatusByAccountID.removeValue(forKey: result.accountID)
    }

    private func syncAccount(
        _ account: APIAccount,
        forceFullReload: Bool,
        overrideStartDate: Date? = nil,
        showAccountSyncStatus: Bool = true
    ) async throws -> AccountSyncResult {
        let now = Date()
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let fullReloadStart = calendar.date(byAdding: .month, value: -(logBackfillMonths - 1), to: monthStart) ?? monthStart

        let didFullReload = forceFullReload || account.lastLogTimestamp == nil
        let fetchedLogs: [NewAPILogEntry]
        if didFullReload {
            let reloadStart: Date
            if let overrideStartDate {
                reloadStart = overrideStartDate
            } else if forceFullReload {
                reloadStart = try await detectEarliestLogDate(account: account) ?? fullReloadStart
            } else {
                reloadStart = fullReloadStart
            }
            fetchedLogs = try await fetchLogsByExportedCSV(
                account: account,
                start: reloadStart,
                end: now
            )
        } else {
            let startTimestamp = max(0, Int(Double(account.lastLogTimestamp ?? 0) - incrementalSafetyWindow))
            if showAccountSyncStatus {
                syncStatusByAccountID[account.id] = .incremental
            }
            fetchedLogs = try await client.fetchLogs(
                account: account,
                start: startTimestamp,
                end: Int(now.timeIntervalSince1970),
                pageSize: 1000,
                pacing: .normal
            )
        }

        let syncedAt = Date()
        let resolvedStatus = try await client.fetchStatus(account: account)
        let resolvedUser = try await client.fetchUser(account: account)
        let quotaPerUnit = max(resolvedStatus.quotaPerUnit, 1)

        let storedLogs = fetchedLogs.map {
            StoredUsageLog(
                id: Self.makeLogID(accountID: account.id, log: $0),
                accountID: account.id,
                createdAt: $0.createdAt,
                tokenName: $0.tokenName,
                modelName: $0.modelName,
                quota: $0.quota,
                amount: $0.amount > 0 ? $0.amount : Double($0.quota) / Double(quotaPerUnit),
                promptTokens: $0.promptTokens,
                completionTokens: $0.completionTokens
            )
        }

        return AccountSyncResult(
            accountID: account.id,
            liveSnapshot: LiveAccountSnapshot(
                accountID: account.id,
                balanceQuota: max(resolvedUser.quota, 0),
                balanceAmount: Double(max(resolvedUser.quota, 0)) / Double(quotaPerUnit),
                syncedAt: syncedAt
            ),
            logs: storedLogs,
            lastLogTimestamp: storedLogs.map { $0.createdAt }.max() ?? account.lastLogTimestamp,
            didFullReload: didFullReload
        )
    }

    private func fetchLogsByExportedCSV(
        account: APIAccount,
        start: Date,
        end: Date
    ) async throws -> [NewAPILogEntry] {
        let calendar = Calendar.current
        let monthStarts = monthStartDates(from: start, to: end, calendar: calendar)

        guard !monthStarts.isEmpty else {
            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: 0,
                totalUnits: 1,
                unitLabel: "月",
                currentDayLabel: nil
            )
            return []
        }

        var collected: [NewAPILogEntry] = []

        for (index, monthStart) in monthStarts.enumerated() {
            let rangeStart = max(monthStart, calendar.startOfDay(for: start))
            let rangeEnd = min(endOfMonth(for: monthStart, calendar: calendar), end)
            let label = "\(dayLabel(for: rangeStart)) ~ \(dayLabel(for: rangeEnd))"

            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: index,
                totalUnits: monthStarts.count,
                unitLabel: "月",
                currentDayLabel: label
            )

            let monthLogs = try await client.exportLogs(
                account: account,
                start: Int(rangeStart.timeIntervalSince1970),
                end: Int(rangeEnd.timeIntervalSince1970),
                pacing: .throttled
            )
            collected.append(contentsOf: monthLogs)

            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: index + 1,
                totalUnits: monthStarts.count,
                unitLabel: "月",
                currentDayLabel: label
            )
        }

        return collected
    }

    private func fetchLogsByDay(
        account: APIAccount,
        start: Date,
        end: Date
    ) async throws -> [NewAPILogEntry] {
        let activeRanges = try await detectActiveLogRanges(
            account: account,
            start: start,
            end: end
        )

        let activeDays = flattenActiveDays(from: activeRanges)

        guard !activeDays.isEmpty else {
            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: 0,
                totalUnits: 1,
                currentDayLabel: nil
            )
            return []
        }

        var collected: [NewAPILogEntry] = []

        for (offset, currentDay) in activeDays.enumerated() {
            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: offset,
                totalUnits: activeDays.count,
                currentDayLabel: dayLabel(for: currentDay)
            )

            let dayLogs = try await fetchLogsForDayInChunks(
                account: account,
                dayStart: currentDay,
                end: end
            )
            collected.append(contentsOf: dayLogs)

            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: offset + 1,
                totalUnits: activeDays.count,
                currentDayLabel: dayLabel(for: currentDay)
            )
        }

        return collected
    }

    private func fetchLogsAdaptive(
        account: APIAccount,
        start: Date,
        end: Date
    ) async throws -> [NewAPILogEntry] {
        let windows = adaptiveSyncWindows(start: start, end: end)
        guard !windows.isEmpty else {
            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: 0,
                totalUnits: 1,
                unitLabel: "段",
                currentDayLabel: nil
            )
            return []
        }

        var collected: [NewAPILogEntry] = []

        for (index, window) in windows.enumerated() {
            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: index,
                totalUnits: windows.count,
                unitLabel: "段",
                currentDayLabel: window.label
            )

            let windowLogs = try await fetchLogsRecursively(
                account: account,
                range: window,
                minimumWindowDuration: 3600
            )
            collected.append(contentsOf: windowLogs)

            syncStatusByAccountID[account.id] = .fullReload(
                completedUnits: index + 1,
                totalUnits: windows.count,
                unitLabel: "段",
                currentDayLabel: window.label
            )
        }

        return collected
    }

    private func fetchLogsRecursively(
        account: APIAccount,
        range: SyncLogRange,
        minimumWindowDuration: TimeInterval
    ) async throws -> [NewAPILogEntry] {
        let maxPageSize = 1000
        let logs = try await client.fetchLogs(
            account: account,
            start: Int(range.start.timeIntervalSince1970),
            end: Int(range.end.timeIntervalSince1970),
            pageSize: maxPageSize,
            pacing: .throttled
        )

        let duration = range.end.timeIntervalSince(range.start)
        if logs.count < maxPageSize || duration <= minimumWindowDuration {
            return logs
        }

        let midpoint = range.start.addingTimeInterval(duration / 2)
        let leftEnd = min(midpoint.addingTimeInterval(-1), range.end)
        guard leftEnd > range.start else {
            return logs
        }

        let leftRange = SyncLogRange(
            start: range.start,
            end: leftEnd,
            label: range.label
        )
        let rightRange = SyncLogRange(
            start: midpoint,
            end: range.end,
            label: range.label
        )

        let leftLogs = try await fetchLogsRecursively(
            account: account,
            range: leftRange,
            minimumWindowDuration: minimumWindowDuration
        )
        let rightLogs = try await fetchLogsRecursively(
            account: account,
            range: rightRange,
            minimumWindowDuration: minimumWindowDuration
        )
        return leftLogs + rightLogs
    }

    private func fetchLogsForDayInChunks(
        account: APIAccount,
        dayStart: Date,
        end: Date
    ) async throws -> [NewAPILogEntry] {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
        let dayEnd = min(nextDay.addingTimeInterval(-1), end)
        let chunkRanges = timeChunkRanges(
            start: dayStart,
            end: dayEnd,
            chunkHours: 6,
            calendar: calendar
        )

        var collected: [NewAPILogEntry] = []
        for range in chunkRanges {
            let chunkLogs = try await client.fetchLogs(
                account: account,
                start: Int(range.start.timeIntervalSince1970),
                end: Int(range.end.timeIntervalSince1970),
                pageSize: 1000,
                pacing: .throttled
            )
            collected.append(contentsOf: chunkLogs)
        }
        return collected
    }

    private func detectActiveLogRanges(
        account: APIAccount,
        start: Date,
        end: Date
    ) async throws -> [SyncLogRange] {
        let calendar = Calendar.current
        let monthStarts = monthStartDates(from: start, to: end, calendar: calendar)
        guard !monthStarts.isEmpty else { return [] }

        var monthsWithLogs: [Date] = []
        for (index, monthStart) in monthStarts.enumerated() {
            let monthEnd = min(endOfMonth(for: monthStart, calendar: calendar), end)
            syncStatusByAccountID[account.id] = .detecting(
                scannedUnits: index + 1,
                totalUnits: monthStarts.count,
                label: "月"
            )

            let monthLogs = try await client.fetchLogsPage(
                account: account,
                start: Int(monthStart.timeIntervalSince1970),
                end: Int(monthEnd.timeIntervalSince1970),
                page: 1,
                pageSize: 1,
                pacing: .throttled
            )

            if !monthLogs.isEmpty {
                monthsWithLogs.append(monthStart)
            }
        }

        guard !monthsWithLogs.isEmpty else { return [] }

        let probedRanges = monthsWithLogs.flatMap {
            weekRanges(in: $0, start: start, end: end, calendar: calendar)
        }
        guard !probedRanges.isEmpty else { return [] }

        var activeRanges: [SyncLogRange] = []
        var scannedRanges = 0
        for range in probedRanges {
                scannedRanges += 1
                syncStatusByAccountID[account.id] = .detecting(
                    scannedUnits: scannedRanges,
                    totalUnits: probedRanges.count,
                    label: "段"
                )

                let probeLogs = try await client.fetchLogsPage(
                    account: account,
                    start: Int(range.start.timeIntervalSince1970),
                    end: Int(range.end.timeIntervalSince1970),
                    page: 1,
                    pageSize: 1,
                    pacing: .throttled
                )

                if !probeLogs.isEmpty {
                    activeRanges.append(range)
                }
        }

        return activeRanges
    }

    private func detectEarliestLogDate(account: APIAccount) async throws -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let maxLookbackMonths = 24
        var scannedMonths = 0

        for offset in 0..<maxLookbackMonths {
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonthStart),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                continue
            }

            scannedMonths += 1
            syncStatusByAccountID[account.id] = .detecting(
                scannedUnits: scannedMonths,
                totalUnits: maxLookbackMonths,
                label: "月"
            )

            let monthLogs = try await client.fetchLogs(
                account: account,
                start: Int(monthStart.timeIntervalSince1970),
                end: Int(min(nextMonth.addingTimeInterval(-1), now).timeIntervalSince1970),
                pageSize: 1000,
                pacing: .throttled
            )

            guard !monthLogs.isEmpty else { continue }
            return try await detectEarliestLogDateInMonth(
                account: account,
                monthStart: monthStart,
                now: now
            )
        }

        return nil
    }

    private func detectEarliestLogDateInMonth(
        account: APIAccount,
        monthStart: Date,
        now: Date
    ) async throws -> Date? {
        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: monthStart) else {
            return nil
        }

        let totalDays = max(1, (calendar.dateComponents([.day], from: monthInterval.start, to: monthInterval.end).day ?? 0))
        for dayOffset in 0..<totalDays {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: monthInterval.start),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                continue
            }

            syncStatusByAccountID[account.id] = .detecting(
                scannedUnits: dayOffset + 1,
                totalUnits: totalDays,
                label: "天"
            )

            let dayLogs = try await client.fetchLogs(
                account: account,
                start: Int(dayStart.timeIntervalSince1970),
                end: Int(min(nextDay.addingTimeInterval(-1), now).timeIntervalSince1970),
                pageSize: 1000,
                pacing: .throttled
            )
            if !dayLogs.isEmpty {
                return calendar.startOfDay(for: dayStart)
            }
        }

        return calendar.startOfDay(for: monthStart)
    }

    private func dayLabel(for date: Date) -> String {
        Self.dayLabelText(for: date)
    }

    nonisolated private static func dayLabelText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func monthStartDates(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var current = calendar.dateInterval(of: .month, for: start)?.start ?? calendar.startOfDay(for: start)
        let endMonth = calendar.dateInterval(of: .month, for: end)?.start ?? calendar.startOfDay(for: end)

        while current <= endMonth {
            dates.append(current)
            guard let next = calendar.date(byAdding: .month, value: 1, to: current) else { break }
            current = next
        }

        return dates
    }

    private func weekRanges(
        in monthStart: Date,
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> [SyncLogRange] {
        let firstDay = max(calendar.startOfDay(for: start), monthStart)
        let lastDay = min(calendar.startOfDay(for: end), endOfMonth(for: monthStart, calendar: calendar))
        guard firstDay <= lastDay else { return [] }

        var ranges: [SyncLogRange] = []
        var current = firstDay
        while current <= lastDay {
            let next = calendar.date(byAdding: .day, value: 7, to: current) ?? lastDay
            let rangeEndDate = min(next.addingTimeInterval(-1), end)
            ranges.append(
                SyncLogRange(
                    start: current,
                    end: rangeEndDate,
                    label: "\(dayLabel(for: current)) ~ \(dayLabel(for: min(calendar.startOfDay(for: rangeEndDate), lastDay)))"
                )
            )
            guard let nextCurrent = calendar.date(byAdding: .day, value: 7, to: current) else { break }
            current = nextCurrent
        }

        return ranges
    }

    private func flattenActiveDays(from ranges: [SyncLogRange]) -> [Date] {
        let calendar = Calendar.current
        var days: [Date] = []

        for range in ranges {
            var current = calendar.startOfDay(for: range.start)
            let last = calendar.startOfDay(for: range.end)
            while current <= last {
                days.append(current)
                guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
        }

        return days
    }

    private func adaptiveSyncWindows(start: Date, end: Date) -> [SyncLogRange] {
        let calendar = Calendar.current
        var windows: [SyncLogRange] = []
        var current = calendar.startOfDay(for: start)

        while current <= end {
            let next = calendar.date(byAdding: .day, value: 7, to: current) ?? end
            let rangeEnd = min(next.addingTimeInterval(-1), end)
            windows.append(
                SyncLogRange(
                    start: current,
                    end: rangeEnd,
                    label: "\(dayLabel(for: current)) ~ \(dayLabel(for: rangeEnd))"
                )
            )

            guard let nextCurrent = calendar.date(byAdding: .day, value: 7, to: current) else {
                break
            }
            current = nextCurrent
        }

        return windows
    }

    private func timeChunkRanges(
        start: Date,
        end: Date,
        chunkHours: Int,
        calendar: Calendar
    ) -> [SyncLogRange] {
        guard start <= end else { return [] }

        var ranges: [SyncLogRange] = []
        var current = start

        while current <= end {
            let next = calendar.date(byAdding: .hour, value: chunkHours, to: current) ?? end
            let rangeEnd = min(next.addingTimeInterval(-1), end)
            ranges.append(
                SyncLogRange(
                    start: current,
                    end: rangeEnd,
                    label: "\(dayLabel(for: current))"
                )
            )

            guard let nextCurrent = calendar.date(byAdding: .hour, value: chunkHours, to: current) else {
                break
            }
            current = nextCurrent
        }

        return ranges
    }

    private func endOfMonth(for monthStart: Date, calendar: Calendar) -> Date {
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        return nextMonth.addingTimeInterval(-1)
    }

    private static func makeLogID(accountID: UUID, log: NewAPILogEntry) -> String {
        [
            accountID.uuidString,
            String(log.createdAt),
            log.tokenName,
            log.modelName,
            String(log.quota),
            String(log.promptTokens),
            String(log.completionTokens)
        ].joined(separator: "|")
    }
}

private struct SyncLogRange {
    let start: Date
    let end: Date
    let label: String
}

private struct AccountSyncResult {
    let accountID: UUID
    let liveSnapshot: LiveAccountSnapshot
    let logs: [StoredUsageLog]
    let lastLogTimestamp: Int?
    let didFullReload: Bool
}

private struct FilteredDataCacheKey: Equatable {
    let revision: Int
    let accountIDs: [UUID]
    let start: Int
    let end: Int
    let tokenName: String
    let modelName: String
    let granularity: TrendGranularity
    let reportMode: ReportMode
}

private struct FilteredDataCache {
    let key: FilteredDataCacheKey
    let totalAmount: Double
    let totalTokens: Int
    let coverageText: String?
    let dayTrend: [TrendPoint]
    let weekTrend: [TrendPoint]
    let monthTrend: [TrendPoint]
    let weeklyReports: [ReportGroup]
    let monthlyReports: [ReportGroup]
    let modelDistribution: [DistributionSlice]
    let daySummaryRows: [PeriodSummaryRow]
    let weekSummaryRows: [PeriodSummaryRow]
    let monthSummaryRows: [PeriodSummaryRow]

    static func empty(key: FilteredDataCacheKey) -> FilteredDataCache {
        FilteredDataCache(
            key: key,
            totalAmount: 0,
            totalTokens: 0,
            coverageText: nil,
            dayTrend: [],
            weekTrend: [],
            monthTrend: [],
            weeklyReports: [],
            monthlyReports: [],
            modelDistribution: [],
            daySummaryRows: [],
            weekSummaryRows: [],
            monthSummaryRows: []
        )
    }
}

import Foundation
import SQLite3

final class UsageLogRepository {
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let legacyStorageKey = "newapi-lens.usage-logs.v1"
    private let databaseName = "usage-logs.sqlite3"
    private let jsonMigrationName = "usage-logs.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.sortedKeys]
        initializeDatabaseIfNeeded()
    }

    func load() -> [StoredUsageLog] {
        migrateLegacyLogsIfNeeded()

        return withDatabase { db in
            queryLogs(db: db, sql: """
            SELECT id, account_id, created_at, token_name, model_name, quota, amount, prompt_tokens, completion_tokens
            FROM usage_logs
            ORDER BY created_at ASC, id ASC;
            """)
        } ?? []
    }

    func loadLogs(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String? = nil,
        modelName: String? = nil
    ) -> [StoredUsageLog] {
        guard !accountIDs.isEmpty else { return [] }
        migrateLegacyLogsIfNeeded()

        return withDatabase { db in
            var parameters: [SQLiteValue] = accountIDs.map { .text($0.uuidString) }
            parameters.append(.int(start))
            parameters.append(.int(end))

            var sql = """
            SELECT id, account_id, created_at, token_name, model_name, quota, amount, prompt_tokens, completion_tokens
            FROM usage_logs
            WHERE account_id IN (\(placeholders(count: accountIDs.count)))
              AND created_at >= ?
              AND created_at <= ?
            """

            if let tokenName, tokenName != "全部" {
                sql += " AND token_name = ?"
                parameters.append(.text(tokenName))
            }
            if let modelName, modelName != "全部" {
                sql += " AND model_name = ?"
                parameters.append(.text(modelName))
            }

            sql += " ORDER BY created_at ASC, id ASC;"
            return queryLogs(db: db, sql: sql, parameters: parameters)
        } ?? []
    }

    func aggregateUsage(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String? = nil,
        modelName: String? = nil
    ) -> UsageAggregate {
        guard !accountIDs.isEmpty else {
            return UsageAggregate(amount: 0, tokens: 0, count: 0, firstCreatedAt: nil, lastCreatedAt: nil)
        }
        migrateLegacyLogsIfNeeded()

        return withDatabase { db in
            let filter = makeFilterClause(
                accountIDs: accountIDs,
                start: start,
                end: end,
                tokenName: tokenName,
                modelName: modelName
            )

            let sql = """
            SELECT
                COALESCE(SUM(amount), 0),
                COALESCE(SUM(prompt_tokens + completion_tokens), 0),
                COUNT(*),
                MIN(created_at),
                MAX(created_at)
            FROM usage_logs
            \(filter.clause);
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return UsageAggregate(amount: 0, tokens: 0, count: 0, firstCreatedAt: nil, lastCreatedAt: nil)
            }
            defer { sqlite3_finalize(statement) }

            bind(filter.parameters, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return UsageAggregate(amount: 0, tokens: 0, count: 0, firstCreatedAt: nil, lastCreatedAt: nil)
            }

            let count = Int(sqlite3_column_int64(statement, 2))
            let firstCreatedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 3))
            let lastCreatedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 4))

            return UsageAggregate(
                amount: sqlite3_column_double(statement, 0),
                tokens: Int(sqlite3_column_int64(statement, 1)),
                count: count,
                firstCreatedAt: firstCreatedAt,
                lastCreatedAt: lastCreatedAt
            )
        } ?? UsageAggregate(amount: 0, tokens: 0, count: 0, firstCreatedAt: nil, lastCreatedAt: nil)
    }

    func topModels(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        limit: Int? = nil
    ) -> [TopModel] {
        let rows = groupedSums(
            accountIDs: accountIDs,
            start: start,
            end: end,
            groupIDExpression: "model_name",
            groupLabelExpression: "model_name",
            tokenName: nil,
            modelName: nil,
            orderBy: "amount DESC, model_name ASC",
            limit: limit
        )

        return Dictionary(grouping: rows, by: \.label)
            .map { label, items in
                TopModel(
                    id: label,
                    name: label,
                    amount: items.reduce(0) { $0 + $1.amount },
                    tokens: items.reduce(0) { $0 + $1.tokens }
                )
            }
            .sorted { lhs, rhs in
                if lhs.amount == rhs.amount {
                    return lhs.name < rhs.name
                }
                return lhs.amount > rhs.amount
            }
            .prefix(limit ?? Int.max)
            .map { $0 }
    }

    func trendPoints(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String? = nil,
        modelName: String? = nil,
        granularity: TrendGranularity
    ) -> [TrendPoint] {
        groupedSums(
            accountIDs: accountIDs,
            start: start,
            end: end,
            groupIDExpression: bucketIDExpression(for: granularity),
            groupLabelExpression: bucketLabelExpression(for: granularity),
            tokenName: tokenName,
            modelName: modelName,
            orderBy: "label ASC"
        ).map {
            TrendPoint(id: $0.id, label: $0.label, amount: $0.amount, tokens: $0.tokens)
        }
    }

    func distributionByModel(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String? = nil,
        modelName: String? = nil
    ) -> [DistributionSlice] {
        let rows = groupedSums(
            accountIDs: accountIDs,
            start: start,
            end: end,
            groupIDExpression: "model_name",
            groupLabelExpression: "model_name",
            tokenName: tokenName,
            modelName: modelName,
            orderBy: "amount DESC, model_name ASC"
        )

        return Dictionary(grouping: rows, by: \.label)
            .map { label, items in
                DistributionSlice(
                    id: label,
                    label: label,
                    amount: items.reduce(0) { $0 + $1.amount },
                    tokens: items.reduce(0) { $0 + $1.tokens }
                )
            }
            .sorted { lhs, rhs in
                if lhs.amount == rhs.amount {
                    return lhs.label < rhs.label
                }
                return lhs.amount > rhs.amount
            }
    }

    func reportGroups(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String? = nil,
        modelName: String? = nil,
        mode: ReportMode
    ) -> [ReportGroup] {
        let parentGranularity: TrendGranularity = mode == .weekly ? .week : .month
        let parentRows = groupedSums(
            accountIDs: accountIDs,
            start: start,
            end: end,
            groupIDExpression: bucketIDExpression(for: parentGranularity),
            groupLabelExpression: bucketLabelExpression(for: parentGranularity),
            tokenName: tokenName,
            modelName: modelName,
            orderBy: "label DESC"
        )

        let childRows: [(String, DailyBreakdown)] = queryRows(
            accountIDs: accountIDs,
            start: start,
            end: end,
            tokenName: tokenName,
            modelName: modelName,
            sqlBuilder: { filter in
                """
                SELECT
                    \(bucketIDExpression(for: parentGranularity)) AS parent_id,
                    \(bucketLabelExpression(for: parentGranularity)) AS parent_label,
                    \(bucketLabelExpression(for: .day)) AS day_label,
                    COALESCE(SUM(amount), 0) AS amount,
                    COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens
                FROM usage_logs
                \(filter.clause)
                GROUP BY parent_id, parent_label, day_label
                ORDER BY parent_label DESC, day_label ASC;
                """
            },
            rowBuilder: { statement in
                guard
                    let parentLabel = sqliteText(statement, column: 1),
                    let dayLabel = sqliteText(statement, column: 2)
                else {
                    return nil
                }
                return (parentLabel, DailyBreakdown(
                    id: dayLabel,
                    label: dayLabel,
                    amount: sqlite3_column_double(statement, 3),
                    tokens: Int(sqlite3_column_int64(statement, 4))
                ))
            }
        )

        let childrenByParent = Dictionary(grouping: childRows, by: { $0.0 })
            .mapValues { rows in rows.map { $0.1 } }

        return parentRows.map { row in
            ReportGroup(
                id: row.id,
                title: row.label,
                amount: row.amount,
                tokens: row.tokens,
                children: childrenByParent[row.label] ?? []
            )
        }
    }

    func periodSummaryRows(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String? = nil,
        modelName: String? = nil,
        accountsByID: [UUID: String],
        granularity: TrendGranularity
    ) -> [PeriodSummaryRow] {
        let periodRows = groupedSums(
            accountIDs: accountIDs,
            start: start,
            end: end,
            groupIDExpression: bucketIDExpression(for: granularity),
            groupLabelExpression: bucketLabelExpression(for: granularity),
            tokenName: tokenName,
            modelName: modelName,
            orderBy: "label DESC"
        )

        let topAccountsByPeriod: [(String, String)] = queryRows(
            accountIDs: accountIDs,
            start: start,
            end: end,
            tokenName: tokenName,
            modelName: modelName,
            sqlBuilder: { filter in
                """
                WITH grouped AS (
                    SELECT
                        \(bucketIDExpression(for: granularity)) AS period_id,
                        \(bucketLabelExpression(for: granularity)) AS period_label,
                        account_id,
                        COALESCE(SUM(amount), 0) AS amount
                    FROM usage_logs
                    \(filter.clause)
                    GROUP BY period_id, period_label, account_id
                ),
                ranked AS (
                    SELECT
                        period_id,
                        period_label,
                        account_id,
                        amount,
                        ROW_NUMBER() OVER (
                            PARTITION BY period_id
                            ORDER BY amount DESC, account_id ASC
                        ) AS rank_no
                    FROM grouped
                )
                SELECT period_label, account_id
                FROM ranked
                WHERE rank_no <= 2
                ORDER BY period_label DESC, rank_no ASC;
                """
            },
            rowBuilder: { statement in
                guard
                    let periodLabel = sqliteText(statement, column: 0),
                    let accountIDText = sqliteText(statement, column: 1),
                    let accountID = UUID(uuidString: accountIDText)
                else {
                    return nil
                }
                return (periodLabel, accountsByID[accountID] ?? accountIDText)
            }
        )

        let topAccountsByPeriodMap = Dictionary(grouping: topAccountsByPeriod, by: { $0.0 })
            .mapValues { rows in rows.map { $0.1 } }

        return periodRows.map { row in
            PeriodSummaryRow(
                id: row.id,
                title: row.label,
                amount: row.amount,
                tokens: row.tokens,
                topModels: [],
                topTokenGroups: [],
                topAccounts: topAccountsByPeriodMap[row.label] ?? []
            )
        }
    }

    func distinctTokenNames(accountIDs: [UUID]) -> [String] {
        distinctValues(column: "token_name", accountIDs: accountIDs)
    }

    func distinctModelNames(accountIDs: [UUID]) -> [String] {
        distinctValues(column: "model_name", accountIDs: accountIDs)
    }

    func save(_ logs: [StoredUsageLog]) {
        _ = withDatabase { db in
            execute(db, sql: "DELETE FROM usage_logs;")
            upsert(logs: logs, in: db)
        }
    }

    func replaceLogs(for accountID: UUID, with incoming: [StoredUsageLog]) -> [StoredUsageLog] {
        _ = withDatabase { db in
            var deleteStatement: OpaquePointer?
            let deleteSQL = "DELETE FROM usage_logs WHERE account_id = ?;"
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
                sqlite3_finalize(deleteStatement)
                return
            }
            sqlite3_bind_text(deleteStatement, 1, accountID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(deleteStatement)
            sqlite3_finalize(deleteStatement)

            upsert(logs: incoming, in: db)
        }

        return load()
    }

    func mergeIncrementalLogs(for accountID: UUID, incoming: [StoredUsageLog]) -> [StoredUsageLog] {
        guard !incoming.isEmpty else { return load() }

        _ = withDatabase { db in
            upsert(logs: incoming.filter { $0.accountID == accountID }, in: db)
        }

        return load()
    }

    func deleteLogs(for accountID: UUID) -> [StoredUsageLog] {
        _ = withDatabase { db in
            var deleteStatement: OpaquePointer?
            let deleteSQL = "DELETE FROM usage_logs WHERE account_id = ?;"
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
                sqlite3_finalize(deleteStatement)
                return
            }
            sqlite3_bind_text(deleteStatement, 1, accountID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(deleteStatement)
            sqlite3_finalize(deleteStatement)
        }

        return load()
    }

    private func initializeDatabaseIfNeeded() {
        _ = withDatabase { db in
            let sql = """
            CREATE TABLE IF NOT EXISTS usage_logs (
                id TEXT PRIMARY KEY NOT NULL,
                account_id TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                token_name TEXT NOT NULL,
                model_name TEXT NOT NULL,
                quota INTEGER NOT NULL,
                amount REAL NOT NULL,
                prompt_tokens INTEGER NOT NULL,
                completion_tokens INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_usage_logs_account_created_at
            ON usage_logs (account_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_usage_logs_created_at
            ON usage_logs (created_at);
            """
            execute(db, sql: sql)
        }
    }

    private func migrateLegacyLogsIfNeeded() {
        migrateJSONFileIfNeeded()
        migrateUserDefaultsIfNeeded()
    }

    private func migrateJSONFileIfNeeded() {
        guard shouldRunMigration else { return }
        guard let url = jsonMigrationURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([StoredUsageLog].self, from: data),
              !decoded.isEmpty else {
            return
        }

        save(decoded)
        try? fileManager.removeItem(at: url)
    }

    private func migrateUserDefaultsIfNeeded() {
        guard shouldRunMigration else { return }
        guard let legacyData = UserDefaults.standard.data(forKey: legacyStorageKey),
              let decoded = try? decoder.decode([StoredUsageLog].self, from: legacyData),
              !decoded.isEmpty else {
            return
        }

        save(decoded)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }

    private var shouldRunMigration: Bool {
        guard let count = withDatabase({ db -> Int in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM usage_logs;", -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return 0
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }) else {
            return true
        }

        return count == 0
    }

    private func upsert(logs: [StoredUsageLog], in db: OpaquePointer?) {
        guard !logs.isEmpty else { return }

        let sql = """
        INSERT INTO usage_logs (
            id, account_id, created_at, token_name, model_name, quota, amount, prompt_tokens, completion_tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            account_id = excluded.account_id,
            created_at = excluded.created_at,
            token_name = excluded.token_name,
            model_name = excluded.model_name,
            quota = excluded.quota,
            amount = excluded.amount,
            prompt_tokens = excluded.prompt_tokens,
            completion_tokens = excluded.completion_tokens;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        execute(db, sql: "BEGIN TRANSACTION;")
        defer { execute(db, sql: "COMMIT;") }

        for log in logs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            sqlite3_bind_text(statement, 1, log.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, log.accountID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(log.createdAt))
            sqlite3_bind_text(statement, 4, log.tokenName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, log.modelName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 6, sqlite3_int64(log.quota))
            sqlite3_bind_double(statement, 7, log.amount)
            sqlite3_bind_int64(statement, 8, sqlite3_int64(log.promptTokens))
            sqlite3_bind_int64(statement, 9, sqlite3_int64(log.completionTokens))

            sqlite3_step(statement)
        }
    }

    private func withDatabase<T>(_ block: (OpaquePointer?) -> T) -> T? {
        guard let url = databaseURL() else { return nil }
        ensureParentDirectory(for: url)

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        return block(db)
    }

    private func execute(_ db: OpaquePointer?, sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func queryLogs(
        db: OpaquePointer?,
        sql: String,
        parameters: [SQLiteValue] = []
    ) -> [StoredUsageLog] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(parameters, to: statement)

        var logs: [StoredUsageLog] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = sqliteText(statement, column: 0),
                let accountIDText = sqliteText(statement, column: 1),
                let accountID = UUID(uuidString: accountIDText),
                let tokenName = sqliteText(statement, column: 3),
                let modelName = sqliteText(statement, column: 4)
            else {
                continue
            }

            logs.append(
                StoredUsageLog(
                    id: id,
                    accountID: accountID,
                    createdAt: Int(sqlite3_column_int64(statement, 2)),
                    tokenName: tokenName,
                    modelName: modelName,
                    quota: Int(sqlite3_column_int64(statement, 5)),
                    amount: sqlite3_column_double(statement, 6),
                    promptTokens: Int(sqlite3_column_int64(statement, 7)),
                    completionTokens: Int(sqlite3_column_int64(statement, 8))
                )
            )
        }

        return logs
    }

    private func groupedSums(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        groupIDExpression: String,
        groupLabelExpression: String,
        tokenName: String? = nil,
        modelName: String? = nil,
        orderBy: String,
        limit: Int? = nil
    ) -> [GroupedSumRow] {
        guard !accountIDs.isEmpty else { return [] }
        migrateLegacyLogsIfNeeded()

        return withDatabase { db in
            let filter = makeFilterClause(
                accountIDs: accountIDs,
                start: start,
                end: end,
                tokenName: tokenName,
                modelName: modelName
            )

            var parameters = filter.parameters
            var sql = """
            SELECT
                \(groupIDExpression) AS group_id,
                \(groupLabelExpression) AS label,
                COALESCE(SUM(amount), 0) AS amount,
                COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens
            FROM usage_logs
            \(filter.clause)
            GROUP BY group_id, label
            ORDER BY \(orderBy)
            """

            if let limit {
                sql += " LIMIT ?"
                parameters.append(.int(limit))
            }
            sql += ";"

            return queryRows(db: db, sql: sql, parameters: parameters) { statement in
                guard
                    let id = sqliteText(statement, column: 0),
                    let label = sqliteText(statement, column: 1)
                else {
                    return nil
                }
                return GroupedSumRow(
                    id: id,
                    label: label,
                    amount: sqlite3_column_double(statement, 2),
                    tokens: Int(sqlite3_column_int64(statement, 3))
                )
            }
        } ?? []
    }

    private func queryRows<Row>(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String?,
        modelName: String?,
        sqlBuilder: (SQLFilter) -> String,
        rowBuilder: (OpaquePointer?) -> Row?
    ) -> [Row] {
        guard !accountIDs.isEmpty else { return [] }
        migrateLegacyLogsIfNeeded()

        return withDatabase { db in
            let filter = makeFilterClause(
                accountIDs: accountIDs,
                start: start,
                end: end,
                tokenName: tokenName,
                modelName: modelName
            )
            return queryRows(db: db, sql: sqlBuilder(filter), parameters: filter.parameters, rowBuilder: rowBuilder)
        } ?? []
    }

    private func queryRows<Row>(
        db: OpaquePointer?,
        sql: String,
        parameters: [SQLiteValue] = [],
        rowBuilder: (OpaquePointer?) -> Row?
    ) -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(parameters, to: statement)

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = rowBuilder(statement) {
                rows.append(row)
            }
        }
        return rows
    }

    private func makeFilterClause(
        accountIDs: [UUID],
        start: Int,
        end: Int,
        tokenName: String?,
        modelName: String?
    ) -> SQLFilter {
        var parameters: [SQLiteValue] = accountIDs.map { .text($0.uuidString) }
        parameters.append(.int(start))
        parameters.append(.int(end))

        var clause = """
        WHERE account_id IN (\(placeholders(count: accountIDs.count)))
          AND created_at >= ?
          AND created_at <= ?
        """

        if let tokenName, tokenName != "全部" {
            clause += " AND token_name = ?"
            parameters.append(.text(tokenName))
        }
        if let modelName, modelName != "全部" {
            clause += " AND model_name = ?"
            parameters.append(.text(modelName))
        }

        return SQLFilter(clause: clause, parameters: parameters)
    }

    private func bucketIDExpression(for granularity: TrendGranularity) -> String {
        let shanghaiDateTime = "datetime(created_at, 'unixepoch', '+8 hours')"
        switch granularity {
        case .day:
            return "strftime('%m-%d', \(shanghaiDateTime))"
        case .week:
            return "printf('%04d-W%02d', CAST(strftime('%G', \(shanghaiDateTime)) AS INTEGER), CAST(strftime('%V', \(shanghaiDateTime)) AS INTEGER))"
        case .month:
            return "strftime('%Y-%m', \(shanghaiDateTime))"
        }
    }

    private func bucketLabelExpression(for granularity: TrendGranularity) -> String {
        let shanghaiDateTime = "datetime(created_at, 'unixepoch', '+8 hours')"
        switch granularity {
        case .day:
            return "strftime('%m-%d', \(shanghaiDateTime))"
        case .week:
            let weekStart = "date(\(shanghaiDateTime), printf('-%d days', (CAST(strftime('%w', \(shanghaiDateTime)) AS INTEGER) + 6) % 7))"
            return "printf('%s-W%d', strftime('%Y-%m', \(weekStart)), ((CAST(strftime('%d', \(weekStart)) AS INTEGER) - 1) / 7) + 1)"
        case .month:
            return "strftime('%Y-%m', \(shanghaiDateTime))"
        }
    }

    private func distinctValues(column: String, accountIDs: [UUID]) -> [String] {
        guard !accountIDs.isEmpty else { return [] }
        migrateLegacyLogsIfNeeded()

        return withDatabase { db in
            let sql = """
            SELECT DISTINCT \(column)
            FROM usage_logs
            WHERE account_id IN (\(placeholders(count: accountIDs.count)))
            ORDER BY \(column) ASC;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return []
            }
            defer { sqlite3_finalize(statement) }

            bind(accountIDs.map { .text($0.uuidString) }, to: statement)

            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqliteText(statement, column: 0) {
                    values.append(value)
                }
            }
            return values
        } ?? []
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .int(let int):
                sqlite3_bind_int64(statement, position, sqlite3_int64(int))
            }
        }
    }

    private func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func databaseURL() -> URL? {
        guard let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return baseDirectory
            .appendingPathComponent("NewAPI Lens", isDirectory: true)
            .appendingPathComponent(databaseName, isDirectory: false)
    }

    private func jsonMigrationURL() -> URL? {
        guard let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return baseDirectory
            .appendingPathComponent("NewAPI Lens", isDirectory: true)
            .appendingPathComponent(jsonMigrationName, isDirectory: false)
    }

    private func ensureParentDirectory(for url: URL) {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func sqliteText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLiteValue {
    case text(String)
    case int(Int)
}

private struct SQLFilter {
    let clause: String
    let parameters: [SQLiteValue]
}

private struct GroupedSumRow {
    let id: String
    let label: String
    let amount: Double
    let tokens: Int
}

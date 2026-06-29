import Foundation

enum NewAPIClientError: LocalizedError {
    case invalidURL
    case requestFailed(String)
    case apiError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "无效的 API 地址"
        case .requestFailed(let message):
            message
        case .apiError(let message):
            message
        case .rateLimited:
            "请求过于频繁，稍后重试"
        case .serverUnavailable(let statusCode):
            "服务暂时不可用 [HTTP \(statusCode)]"
        }
    }
}

final class NewAPIClient {
    private static let throttledRequestPacer = RequestPacer()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchStatus(account: APIAccount) async throws -> NewAPIStatus {
        let response: StatusEnvelope = try await request(
            account: account,
            path: "/api/status",
            authorized: false,
            pacing: .normal
        )

        return NewAPIStatus(
            quotaPerUnit: response.data.quota_per_unit,
            displayInCurrency: response.data.display_in_currency,
            quotaDisplayType: response.data.quota_display_type,
            systemName: response.data.system_name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func fetchUser(account: APIAccount) async throws -> NewAPIUser {
        let response: UserEnvelope = try await request(
            account: account,
            path: "/api/user/self",
            pacing: .normal
        )

        return NewAPIUser(
            id: response.data.id,
            username: response.data.username,
            quota: response.data.quota,
            usedQuota: response.data.used_quota,
            group: response.data.group
        )
    }

    func fetchLogs(
        account: APIAccount,
        start: Int,
        end: Int,
        pageSize: Int = 100,
        pacing: RequestPacing = .normal
    ) async throws -> [NewAPILogEntry] {
        var page = 1
        var collected: [NewAPILogEntry] = []
        var expectedPageCount: Int?

        while true {
            let pageItems = try await fetchLogsPage(
                account: account,
                start: start,
                end: end,
                page: page,
                pageSize: pageSize,
                pacing: pacing
            )
            guard !pageItems.isEmpty else { break }
            collected.append(contentsOf: pageItems)

            if let expectedPageCount, pageItems.count < expectedPageCount {
                break
            }

            expectedPageCount = max(expectedPageCount ?? 0, pageItems.count)
            page += 1
        }

        return collected
    }

    func fetchLogsPage(
        account: APIAccount,
        start: Int,
        end: Int,
        page: Int,
        pageSize: Int = 100,
        pacing: RequestPacing = .normal
    ) async throws -> [NewAPILogEntry] {
        let response: LogsEnvelope = try await request(
            account: account,
            path: "/api/log/self",
            queryItems: [
                URLQueryItem(name: "type", value: "2"),
                URLQueryItem(name: "start_timestamp", value: String(start)),
                URLQueryItem(name: "end_timestamp", value: String(end)),
                URLQueryItem(name: "p", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize))
            ],
            pacing: pacing
        )

        return response.data.items.map {
            NewAPILogEntry(
                createdAt: $0.created_at,
                tokenName: $0.token_name,
                modelName: $0.model_name,
                quota: $0.quota,
                amount: 0,
                promptTokens: $0.prompt_tokens,
                completionTokens: $0.completion_tokens
            )
        }
    }

    func exportLogs(
        account: APIAccount,
        start: Int,
        end: Int,
        pacing: RequestPacing = .throttled
    ) async throws -> [NewAPILogEntry] {
        let quotaPerUnit = max((try await fetchStatus(account: account)).quotaPerUnit, 1)
        let data = try await exportLogsCSVData(
            account: account,
            start: start,
            end: end,
            pacing: pacing
        )
        return try parseExportedLogsCSV(data: data, quotaPerUnit: quotaPerUnit)
    }

    private func request<T: Decodable>(
        account: APIAccount,
        path: String,
        queryItems: [URLQueryItem] = [],
        authorized: Bool = true,
        pacing: RequestPacing = .normal
    ) async throws -> T {
        guard var components = URLComponents(string: "https://\(account.host)") else {
            throw NewAPIClientError.invalidURL
        }

        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw NewAPIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        if authorized {
            request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
            request.setValue(account.userID, forHTTPHeaderField: "New-Api-User")
        }

        if pacing == .throttled {
            await Self.throttledRequestPacer.waitBeforeRequest()
        }
        let (data, response) = try await dataWithRetry(for: request, pacing: pacing)
        let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8-response>"

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NewAPIClientError.apiError(
                    "\(path) 返回错误：\(apiError.message) [HTTP \(statusCode)]"
                )
            }

            if let decodingError = error as? DecodingError {
                let message = detailedDecodingMessage(
                    for: decodingError,
                    path: path,
                    host: account.host,
                    responseText: responseText
                )
                print("NewAPI decode error: \(message)")
                throw NewAPIClientError.requestFailed(message)
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NewAPIClientError.requestFailed(
                "\(path) 请求失败 [HTTP \(statusCode)]：\(error.localizedDescription)"
            )
        }
    }

    private func exportLogsCSVData(
        account: APIAccount,
        start: Int,
        end: Int,
        pacing: RequestPacing
    ) async throws -> Data {
        let data = try await rawRequest(
            account: account,
            path: "/api/log/self/export",
            queryItems: [
                URLQueryItem(name: "type", value: "0"),
                URLQueryItem(name: "start_timestamp", value: String(start)),
                URLQueryItem(name: "end_timestamp", value: String(end))
            ],
            pacing: pacing
        )

        if let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           apiError.success == false {
            throw NewAPIClientError.apiError("/api/log/self/export 返回错误：\(apiError.message)")
        }

        return data
    }

    private func rawRequest(
        account: APIAccount,
        path: String,
        queryItems: [URLQueryItem] = [],
        authorized: Bool = true,
        pacing: RequestPacing = .normal
    ) async throws -> Data {
        guard var components = URLComponents(string: "https://\(account.host)") else {
            throw NewAPIClientError.invalidURL
        }

        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw NewAPIClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        if authorized {
            request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
            request.setValue(account.userID, forHTTPHeaderField: "New-Api-User")
        }

        if pacing == .throttled {
            await Self.throttledRequestPacer.waitBeforeRequest()
        }

        let (data, response) = try await dataWithRetry(for: request, pacing: pacing)
        guard let httpResponse = response as? HTTPURLResponse else { return data }

        if (200...299).contains(httpResponse.statusCode) {
            return data
        }

        if let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            throw NewAPIClientError.apiError(
                "\(path) 返回错误：\(apiError.message) [HTTP \(httpResponse.statusCode)]"
            )
        }

        let preview = String(data: data, encoding: .utf8) ?? "<non-utf8-response>"
        throw NewAPIClientError.requestFailed(
            "\(path) 请求失败 [HTTP \(httpResponse.statusCode)]：\(preview.prefix(200))"
        )
    }

    private func parseExportedLogsCSV(data: Data, quotaPerUnit: Int) throws -> [NewAPILogEntry] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw NewAPIClientError.requestFailed("/api/log/self/export 返回了无法解析的 CSV")
        }

        let rows = CSVReader.rows(from: text)
        guard let header = rows.first, !header.isEmpty else { return [] }

        let headerMap = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })

        func requiredIndex(_ name: String) throws -> Int {
            guard let index = headerMap[name] else {
                throw NewAPIClientError.requestFailed("/api/log/self/export 缺少字段：\(name)")
            }
            return index
        }

        let timeIndex = try requiredIndex("时间")
        let typeIndex = try requiredIndex("类型")
        let tokenIndex = try requiredIndex("令牌名称")
        let modelIndex = try requiredIndex("模型名称")
        let amountIndex = try requiredIndex("花费")
        let promptIndex = try requiredIndex("提示词tokens")
        let completionIndex = try requiredIndex("补全tokens")

        return try rows.dropFirst().compactMap { row in
            guard row.indices.contains(typeIndex), row[typeIndex] == "consume" else { return nil }

            let createdAt = try csvTimestamp(row, index: timeIndex)
            let tokenName = csvValue(row, index: tokenIndex)
            let modelName = csvValue(row, index: modelIndex)
            let amount = Double(csvValue(row, index: amountIndex)) ?? 0
            let promptTokens = Int(csvValue(row, index: promptIndex)) ?? 0
            let completionTokens = Int(csvValue(row, index: completionIndex)) ?? 0
            let quota = Int((amount * Double(quotaPerUnit)).rounded())

            return NewAPILogEntry(
                createdAt: createdAt,
                tokenName: tokenName,
                modelName: modelName,
                quota: quota,
                amount: amount,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
        }
    }

    private func csvTimestamp(_ row: [String], index: Int) throws -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let value = csvValue(row, index: index)
        guard let date = formatter.date(from: value) else {
            throw NewAPIClientError.requestFailed("/api/log/self/export 时间解析失败：\(value)")
        }
        return Int(date.timeIntervalSince1970)
    }

    private func csvValue(_ row: [String], index: Int) -> String {
        guard row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detailedDecodingMessage(
        for error: DecodingError,
        path: String,
        host: String,
        responseText: String
    ) -> String {
        let preview = responseText.prefix(400).replacingOccurrences(of: "\n", with: " ")

        switch error {
        case .typeMismatch(let type, let context):
            return "\(path) 解码失败：字段类型不匹配，期望 \(type)，路径 \(codingPathText(context.codingPath))，\(context.debugDescription)。host=\(host)。响应片段：\(preview)"
        case .valueNotFound(let type, let context):
            return "\(path) 解码失败：缺少值 \(type)，路径 \(codingPathText(context.codingPath))，\(context.debugDescription)。host=\(host)。响应片段：\(preview)"
        case .keyNotFound(let key, let context):
            return "\(path) 解码失败：缺少字段 \(key.stringValue)，路径 \(codingPathText(context.codingPath))，\(context.debugDescription)。host=\(host)。响应片段：\(preview)"
        case .dataCorrupted(let context):
            return "\(path) 解码失败：数据损坏，路径 \(codingPathText(context.codingPath))，\(context.debugDescription)。host=\(host)。响应片段：\(preview)"
        @unknown default:
            return "\(path) 解码失败：未知错误。host=\(host)。响应片段：\(preview)"
        }
    }

    private func codingPathText(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "<root>" }
        return path.map(\.stringValue).joined(separator: ".")
    }

    private func dataWithRetry(
        for request: URLRequest,
        pacing: RequestPacing,
        maxAttempts: Int = 4
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        var lastError: Error?
        let path = request.url?.path ?? ""

        while attempt < maxAttempts {
            attempt += 1

            do {
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 429 {
                        let retryAfter = retryAfterInterval(from: httpResponse)
                        let cooldown: TimeInterval?
                        if pacing == .throttled {
                            cooldown = await Self.throttledRequestPacer.registerRateLimit(
                                path: path,
                                retryAfter: retryAfter
                            )
                        } else {
                            cooldown = retryAfter
                        }
                        if attempt < maxAttempts {
                            try await Task.sleep(
                                nanoseconds: retryDelaySeconds(
                                    for: attempt,
                                    retryAfter: cooldown,
                                    isRateLimited: true
                                )
                            )
                            continue
                        }
                        throw NewAPIClientError.rateLimited(retryAfter: retryAfter)
                    }

                    if (500...599).contains(httpResponse.statusCode) {
                        if attempt < maxAttempts {
                            try await Task.sleep(nanoseconds: retryDelaySeconds(for: attempt, retryAfter: nil))
                            continue
                        }
                        throw NewAPIClientError.serverUnavailable(httpResponse.statusCode)
                    }
                }

                if pacing == .throttled {
                    await Self.throttledRequestPacer.registerSuccess(path: path)
                }
                return (data, response)
            } catch {
                lastError = error

                if error is CancellationError {
                    throw error
                }

                if let clientError = error as? NewAPIClientError {
                    switch clientError {
                    case .rateLimited, .serverUnavailable:
                        if attempt < maxAttempts {
                            let retryAfter: TimeInterval?
                            let isRateLimited: Bool
                            if case .rateLimited(let serverRetryAfter) = clientError {
                                isRateLimited = true
                                if pacing == .throttled {
                                    retryAfter = await Self.throttledRequestPacer.registerRateLimit(
                                        path: path,
                                        retryAfter: serverRetryAfter
                                    )
                                } else {
                                    retryAfter = serverRetryAfter
                                }
                            } else {
                                retryAfter = nil
                                isRateLimited = false
                            }
                            try await Task.sleep(
                                nanoseconds: retryDelaySeconds(
                                    for: attempt,
                                    retryAfter: retryAfter,
                                    isRateLimited: isRateLimited
                                )
                            )
                            continue
                        }
                    default:
                        throw clientError
                    }
                } else if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: retryDelaySeconds(for: attempt, retryAfter: nil))
                    continue
                }
            }
        }

        throw lastError ?? NewAPIClientError.requestFailed("请求失败")
    }

    private func retryAfterInterval(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value) else {
            return nil
        }
        return seconds
    }

    private func retryDelaySeconds(
        for attempt: Int,
        retryAfter: TimeInterval?,
        isRateLimited: Bool = false
    ) -> UInt64 {
        let seconds: TimeInterval
        if isRateLimited {
            seconds = retryAfter ?? min(pow(2, Double(max(attempt - 1, 0))) * 15, 120)
        } else {
            seconds = retryAfter ?? min(Double(attempt * attempt), 8)
        }
        return UInt64(max(seconds, 1) * 1_000_000_000)
    }
}

private enum CSVReader {
    static func rows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false

        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isInsideQuotes {
                if character == "\"" {
                    let nextIndex = index + 1
                    if nextIndex < characters.count, characters[nextIndex] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        isInsideQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    isInsideQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }

            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}

enum RequestPacing {
    case normal
    case throttled
}

private actor RequestPacer {
    private var nextAllowedAt = Date.distantPast
    private var consecutiveRateLimits = 0
    private var consecutiveSuccessfulLogRequests = 0
    private let maxCooldown: TimeInterval = 120
    private let successPauseThreshold = 5
    private let successPauseDuration: TimeInterval = 2

    func waitBeforeRequest() async {
        let now = Date()

        if nextAllowedAt > now {
            let delay = nextAllowedAt.timeIntervalSince(now)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

    }

    func registerRateLimit(path: String, retryAfter: TimeInterval?) -> TimeInterval {
        consecutiveRateLimits += 1

        let localBackoff = fallbackCooldown(
            for: path,
            consecutiveRateLimits: consecutiveRateLimits
        )
        let cooldown = min(max(retryAfter ?? 0, localBackoff), maxCooldown)
        let candidate = Date().addingTimeInterval(cooldown)
        if candidate > nextAllowedAt {
            nextAllowedAt = candidate
        }
        return cooldown
    }

    func registerSuccess(path: String) {
        consecutiveRateLimits = 0

        if path == "/api/log/self" {
            consecutiveSuccessfulLogRequests += 1
            if consecutiveSuccessfulLogRequests >= successPauseThreshold {
                let candidate = Date().addingTimeInterval(successPauseDuration)
                if candidate > nextAllowedAt {
                    nextAllowedAt = candidate
                }
                consecutiveSuccessfulLogRequests = 0
            } else if nextAllowedAt < Date() {
                nextAllowedAt = .distantPast
            }
        } else if nextAllowedAt < Date() {
            nextAllowedAt = .distantPast
        }
    }

    private func fallbackCooldown(
        for path: String,
        consecutiveRateLimits: Int
    ) -> TimeInterval {
        let baseCooldown: TimeInterval
        if path == "/api/log/self" {
            baseCooldown = 15
        } else {
            baseCooldown = 5
        }

        let multiplier = pow(2, Double(max(consecutiveRateLimits - 1, 0)))
        return min(baseCooldown * multiplier, maxCooldown)
    }
}

private struct ErrorEnvelope: Decodable {
    let message: String
    let success: Bool
}

private struct StatusEnvelope: Decodable {
    let success: Bool
    let message: String
    let data: StatusData
}

private struct StatusData: Decodable {
    let quota_per_unit: Int
    let display_in_currency: Bool
    let quota_display_type: String
    let system_name: String
}

private struct UserEnvelope: Decodable {
    let success: Bool
    let message: String
    let data: UserData
}

private struct UserData: Decodable {
    let id: Int
    let username: String
    let quota: Int
    let used_quota: Int
    let group: String
}

private struct LogsEnvelope: Decodable {
    let success: Bool
    let message: String
    let data: LogsData
}

private struct LogsData: Decodable {
    let items: [LogItem]
    let total: Int
    let page: Int
    let page_size: Int
}

private struct LogItem: Decodable {
    let created_at: Int
    let token_name: String
    let model_name: String
    let quota: Int
    let prompt_tokens: Int
    let completion_tokens: Int
}

import Foundation
import CryptoKit

private enum APICachePolicy {
    case disabled
    case disk(maxAge: TimeInterval)
}

private struct APICachedEnvelope: Codable {
    let storedAt: Date
    let payload: Data
}

private final class APIDiskCache {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cacheDirectory: URL

    init() {
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.cacheDirectory = cachesRoot.appendingPathComponent("StockReplayAPI", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func load(for cacheKey: String, maxAge: TimeInterval) -> Data? {
        let fileURL = cacheDirectory.appendingPathComponent(cacheKey).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? decoder.decode(APICachedEnvelope.self, from: data) else {
            return nil
        }

        guard Date().timeIntervalSince(envelope.storedAt) <= maxAge else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        return envelope.payload
    }

    func save(_ payload: Data, for cacheKey: String) {
        let fileURL = cacheDirectory.appendingPathComponent(cacheKey).appendingPathExtension("json")
        let envelope = APICachedEnvelope(storedAt: Date(), payload: payload)
        guard let encoded = try? encoder.encode(envelope) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}

enum APIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "后端地址无效，请在会员页检查 Base URL。"
        case .invalidResponse:
            return "服务器响应无效。"
        case .server(let message):
            return message
        case .decoding(let message):
            return "数据解析失败：\(message)"
        }
    }
}

final class APIClient {
    private let baseURLString: String
    private let decoder: JSONDecoder
    private let diskCache = APIDiskCache()
    private let session: URLSession

    init(baseURLString: String) {
        self.baseURLString = baseURLString
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }

    func fetchHealth() async throws -> HealthCheckResponse {
        try await request(path: "/api/health")
    }

    func fetchCodes() async throws -> [StockCode] {
        try await request(path: "/api/codes")
    }

    func fetchDates(code: String, accountID: String, afdianUID: String, token: String) async throws -> [String] {
        try await request(
            path: "/api/dates",
            queryItems: authQueryItems(code: code, date: nil, accountID: accountID, afdianUID: afdianUID, token: token)
        )
    }

    func fetchSummary(code: String, date: String, accountID: String, afdianUID: String, token: String) async throws -> DailySummary {
        try await request(
            path: "/api/summary",
            queryItems: authQueryItems(code: code, date: date, accountID: accountID, afdianUID: afdianUID, token: token)
        )
    }

    func fetchTicks(code: String, date: String, accountID: String, afdianUID: String, token: String) async throws -> [TickRecord] {
        try await request(
            path: "/api/ticks",
            queryItems: authQueryItems(code: code, date: date, accountID: accountID, afdianUID: afdianUID, token: token)
        )
    }

    /// 预加载指定股票列表的最新一日数据，结果入磁盘缓存。
    /// onProgress(done, total) 每完成一只回调一次。
    func prefetchLatestDay(
        codes: [String],
        accountID: String,
        afdianUID: String,
        token: String,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async {
        let total = codes.count
        await withTaskGroup(of: Void.self) { group in
            for code in codes {
                group.addTask { [weak self] in
                    guard let self else { return }
                    if let dates = try? await self.fetchDates(
                        code: code, accountID: accountID, afdianUID: afdianUID, token: token),
                       let latestDate = dates.first {
                        _ = try? await self.fetchTicks(
                            code: code, date: latestDate,
                            accountID: accountID, afdianUID: afdianUID, token: token)
                    }
                }
            }
            var done = 0
            for await _ in group {
                done += 1
                onProgress(done, total)
            }
        }
    }

    func verifyMembership(accountID: String, afdianUID: String, token: String) async throws -> MemberStatusResponse {
        let items = authQueryItems(code: nil, date: nil, accountID: accountID, afdianUID: afdianUID, token: token)
        return try await request(path: "/api/verify", queryItems: items)
    }

    func syncAppleSubscription(accountID: String, afdianUID: String, token: String, productID: String, transactionID: String) async throws -> MemberStatusResponse {
        try await request(
            path: "/api/subscription/apple/sync",
            method: "POST",
            body: [
                "account_id": accountID,
                "afdian_uid": afdianUID,
                "token": token,
                "product_id": productID,
                "transaction_id": transactionID,
            ]
        )
    }

    private func authQueryItems(code: String?, date: String?, accountID: String, afdianUID: String, token: String) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let date { items.append(URLQueryItem(name: "date", value: date)) }
        if !accountID.isEmpty { items.append(URLQueryItem(name: "account_id", value: accountID)) }
        if !afdianUID.isEmpty { items.append(URLQueryItem(name: "afdian_uid", value: afdianUID)) }
        if !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        return items
    }

    private func request<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: String]? = nil
    ) async throws -> T {
        guard var components = URLComponents(string: baseURLString) else {
            throw APIClientError.invalidBaseURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw APIClientError.invalidBaseURL
        }

        let cachePolicy = cachePolicy(for: path, method: method)
        let cacheKey = cacheKey(for: url)

        if case .disk(let maxAge) = cachePolicy,
           let cachedData = diskCache.load(for: cacheKey, maxAge: maxAge) {
            do {
                return try decoder.decode(T.self, from: cachedData)
            } catch {
                // Ignore corrupted cache and continue with network.
            }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            if case .disk(let maxAge) = cachePolicy,
               let cachedData = diskCache.load(for: cacheKey, maxAge: maxAge),
               let cachedValue = try? decoder.decode(T.self, from: cachedData) {
                return cachedValue
            }
            if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw APIClientError.server(apiError.userMessage)
            }
            throw APIClientError.server("请求失败，状态码 \(httpResponse.statusCode)")
        }

        if case .disk = cachePolicy {
            diskCache.save(data, for: cacheKey)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(error.localizedDescription)
        }
    }

    private func cachePolicy(for path: String, method: String) -> APICachePolicy {
        guard method == "GET" else { return .disabled }

        switch path {
        case "/api/codes":
            return .disk(maxAge: 60 * 60 * 12)
        case "/api/dates", "/api/summary", "/api/ticks":
            return .disk(maxAge: 60 * 60 * 24)
        default:
            return .disabled
        }
    }

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

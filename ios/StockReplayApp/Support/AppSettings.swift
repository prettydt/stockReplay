import SwiftUI

enum ReplayMarkType: String, CaseIterable, Codable, Identifiable {
    case breakout = "突破"
    case pullback = "回落"
    case support = "承接"
    case risk = "风险"
    case note = "观察"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .breakout:
            return "arrow.up.right.circle.fill"
        case .pullback:
            return "arrow.down.right.circle.fill"
        case .support:
            return "shield.lefthalf.filled"
        case .risk:
            return "exclamationmark.triangle.fill"
        case .note:
            return "bookmark.fill"
        }
    }

    func tint(for theme: AppTheme) -> Color {
        switch self {
        case .breakout:
            return theme.positiveColor
        case .pullback:
            return theme.negativeColor
        case .support:
            return theme.accentColor
        case .risk:
            return .orange
        case .note:
            return theme.chartLineColor
        }
    }
}

struct ReplayNote: Codable, Identifiable, Hashable {
    let id: UUID
    let stockCode: String
    let tradeDate: String
    let ts: String
    let price: Double?
    let type: ReplayMarkType
    let note: String
    let createdAt: Date
}

enum AppTheme: String, CaseIterable, Identifiable {
    case `default` = "默认"
    case tonghuashun = "同花顺"
    case dazhihui = "大智慧"

    var id: String { rawValue }

    var accentColor: Color {
        switch self {
        case .default:
            return .blue
        case .tonghuashun:
            return Color(red: 0.96, green: 0.47, blue: 0.18)
        case .dazhihui:
            return Color(red: 0.41, green: 0.74, blue: 0.96)
        }
    }

    var chartLineColor: Color {
        switch self {
        case .default:
            return .blue
        case .tonghuashun:
            return Color(red: 0.99, green: 0.73, blue: 0.18)
        case .dazhihui:
            return Color(red: 0.58, green: 0.63, blue: 0.99)
        }
    }

    var positiveColor: Color {
        switch self {
        case .default:
            return .red
        case .tonghuashun:
            return Color(red: 0.95, green: 0.25, blue: 0.22)
        case .dazhihui:
            return Color(red: 0.92, green: 0.29, blue: 0.35)
        }
    }

    var negativeColor: Color {
        switch self {
        case .default:
            return .green
        case .tonghuashun:
            return Color(red: 0.20, green: 0.76, blue: 0.44)
        case .dazhihui:
            return Color(red: 0.18, green: 0.78, blue: 0.63)
        }
    }

    var pageBackground: LinearGradient {
        switch self {
        case .default:
            return LinearGradient(colors: [Color.black, Color(red: 0.06, green: 0.08, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .tonghuashun:
            return LinearGradient(colors: [Color(red: 0.15, green: 0.09, blue: 0.05), Color(red: 0.24, green: 0.12, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dazhihui:
            return LinearGradient(colors: [Color(red: 0.03, green: 0.08, blue: 0.15), Color(red: 0.08, green: 0.12, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var cardBackground: Color {
        switch self {
        case .default:
            return Color.white.opacity(0.08)
        case .tonghuashun:
            return Color(red: 0.20, green: 0.12, blue: 0.08).opacity(0.95)
        case .dazhihui:
            return Color(red: 0.08, green: 0.12, blue: 0.20).opacity(0.95)
        }
    }

    var workspaceTitle: String {
        switch self {
        case .default:
            return "经典盯盘工作台"
        case .tonghuashun:
            return "同花顺桌面工作台"
        case .dazhihui:
            return "大智慧桌面工作台"
        }
    }

    var workspaceSubtitle: String {
        switch self {
        case .default:
            return "偏通用的深色分时复盘布局"
        case .tonghuashun:
            return "更暖色、更强调价格与成交明细"
        case .dazhihui:
            return "更冷色、更像桌面行情终端"
        }
    }

    var ribbonBackground: Color {
        accentColor.opacity(0.14)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let cloudBaseURL = "http://118.25.176.60:5001"
    static let recentStockLimit = 6

    @Published var baseURLString: String
    @Published var accountID: String
    @Published var afdianUID: String
    @Published var memberToken: String
    @Published var watchlistCodes: [String] {
        didSet { persist() }
    }
    @Published var recentStockCodes: [String] {
        didSet { persist() }
    }
    @Published var compareStockCodes: [String] {
        didSet { persist() }
    }
    @Published var compareLayoutCount: Int {
        didSet { persist() }
    }
    @Published var compareSyncEnabled: Bool {
        didSet { persist() }
    }
    @Published var replayNotes: [ReplayNote] {
        didSet { persist() }
    }
    @Published var globalSelectedDate: String {
        didSet { persist() }
    }
    @Published var selectedTheme: AppTheme {
        didSet { persist() }
    }
    @Published var membershipStatus: MemberStatusResponse?
    @Published var membershipMessage: String = "免费版可查看最近 7 个交易日"
    @Published var backendStatusMessage: String = "尚未检测后端连接"
    @Published var compareSyncTime: String = ""
    @Published var compareSyncSignal: UUID = UUID()
    @Published var compareSyncSourceID: UUID?

    let afdianPageURL = URL(string: "https://ifdian.net/a/stockreplay")!
    private(set) var apiClient: APIClient

    init() {
        let defaults = UserDefaults.standard
        let savedBaseURL = Self.resolvedBaseURL(from: defaults.string(forKey: "ios.baseURL"))
        self.baseURLString = savedBaseURL
        self.accountID = defaults.string(forKey: "ios.accountID") ?? ""
        self.afdianUID = defaults.string(forKey: "ios.afdianUID") ?? ""
        self.memberToken = defaults.string(forKey: "ios.memberToken") ?? ""
        self.watchlistCodes = defaults.stringArray(forKey: "ios.watchlistCodes") ?? ["sh600000", "sz300502"]
        self.recentStockCodes = Self.normalizedRecentStockCodes(defaults.stringArray(forKey: "ios.recentStockCodes") ?? [])
        self.compareStockCodes = defaults.stringArray(forKey: "ios.compareStockCodes") ?? []
        let savedLayout = defaults.integer(forKey: "ios.compareLayoutCount")
        self.compareLayoutCount = [1, 2, 4].contains(savedLayout) ? savedLayout : 1
        self.compareSyncEnabled = defaults.object(forKey: "ios.compareSyncEnabled") as? Bool ?? true
        if let data = defaults.data(forKey: "ios.replayNotes"),
           let decoded = try? JSONDecoder().decode([ReplayNote].self, from: data) {
            self.replayNotes = decoded
        } else {
            self.replayNotes = []
        }
        self.selectedTheme = defaults.string(forKey: "ios.theme").flatMap(AppTheme.init(rawValue:)) ?? .default
        self.globalSelectedDate = defaults.string(forKey: "ios.globalSelectedDate") ?? ""
        self.apiClient = APIClient(baseURLString: savedBaseURL)
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(baseURLString, forKey: "ios.baseURL")
        defaults.set(accountID, forKey: "ios.accountID")
        defaults.set(afdianUID, forKey: "ios.afdianUID")
        defaults.set(memberToken, forKey: "ios.memberToken")
        defaults.set(watchlistCodes, forKey: "ios.watchlistCodes")
        defaults.set(recentStockCodes, forKey: "ios.recentStockCodes")
        defaults.set(compareStockCodes, forKey: "ios.compareStockCodes")
        defaults.set(compareLayoutCount, forKey: "ios.compareLayoutCount")
        defaults.set(compareSyncEnabled, forKey: "ios.compareSyncEnabled")
        if let encoded = try? JSONEncoder().encode(replayNotes) {
            defaults.set(encoded, forKey: "ios.replayNotes")
        }
        defaults.set(selectedTheme.rawValue, forKey: "ios.theme")
        defaults.set(globalSelectedDate, forKey: "ios.globalSelectedDate")
    }

    func updateBaseURL(_ newValue: String) {
        baseURLString = Self.resolvedBaseURL(from: newValue)
        apiClient = APIClient(baseURLString: baseURLString)
        persist()
    }

    func checkBackendConnection() async {
        do {
            let result = try await apiClient.fetchHealth()
            if result.ok {
                let preview = result.previewDays.map { "免费预览 \($0) 天" } ?? "后端在线"
                backendStatusMessage = "连接正常 · \(preview)"
            } else {
                backendStatusMessage = "后端已响应，但状态异常。"
            }
        } catch {
            do {
                let codes = try await apiClient.fetchCodes()
                backendStatusMessage = "连接正常 · 腾讯云在线（股票数 \(codes.count)）"
            } catch {
                backendStatusMessage = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    private static func resolvedBaseURL(from candidate: String?) -> String {
        let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cloudBaseURL }

        let normalized = trimmed.lowercased()
        if normalized.contains("127.0.0.1") || normalized.contains("localhost") {
            return cloudBaseURL
        }
        return trimmed
    }

    private static func normalizedRecentStockCodes(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for code in codes where seen.insert(code).inserted {
            normalized.append(code)
            if normalized.count == recentStockLimit {
                break
            }
        }

        return normalized
    }

    func refreshMembership() async {
        do {
            let result = try await apiClient.verifyMembership(
                accountID: accountID,
                afdianUID: afdianUID,
                token: memberToken
            )
            applyMembership(result, successPrefix: "已开通")
        } catch {
            membershipStatus = nil
            membershipMessage = error.localizedDescription
        }
    }

    func syncAppleMembership(productID: String, transactionID: String) async {
        let normalizedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAfdian = afdianUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccount.isEmpty || !normalizedAfdian.isEmpty || !memberToken.isEmpty else {
            membershipMessage = "请先填写账号或爱发电 UID，再同步 Apple 订阅。"
            return
        }

        do {
            let result = try await apiClient.syncAppleSubscription(
                accountID: normalizedAccount,
                afdianUID: normalizedAfdian,
                token: memberToken,
                productID: productID,
                transactionID: transactionID
            )
            applyMembership(result, successPrefix: "Apple 已同步")
        } catch {
            membershipMessage = "同步 Apple 订阅失败：\(error.localizedDescription)"
        }
    }

    func toggleWatchlist(code: String) {
        if watchlistCodes.contains(code) {
            watchlistCodes.removeAll { $0 == code }
        } else {
            watchlistCodes.insert(code, at: 0)
        }
    }

    func noteRecentStock(code: String) {
        recentStockCodes = Self.normalizedRecentStockCodes([code] + recentStockCodes)
    }

    func setCompareLayout(_ count: Int) {
        compareLayoutCount = [1, 2, 4].contains(count) ? count : 1
        if compareStockCodes.count > 4 {
            compareStockCodes = Array(compareStockCodes.prefix(4))
        }
    }

    func toggleCompareStock(code: String) {
        if compareStockCodes.contains(code) {
            compareStockCodes.removeAll { $0 == code }
        } else {
            compareStockCodes.insert(code, at: 0)
            if compareStockCodes.count > 4 {
                compareStockCodes = Array(compareStockCodes.prefix(4))
            }
        }
    }

    func publishCompareSync(time: String, sourceID: UUID) {
        compareSyncSourceID = sourceID
        compareSyncTime = time
        compareSyncSignal = UUID()
    }

    func replayNotes(for stockCode: String, tradeDate: String) -> [ReplayNote] {
        replayNotes
            .filter { $0.stockCode == stockCode && $0.tradeDate == tradeDate }
            .sorted { $0.ts < $1.ts }
    }

    func addReplayNote(stockCode: String, tradeDate: String, ts: String, price: Double?, type: ReplayMarkType, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = trimmed.isEmpty ? "关键点观察" : trimmed
        replayNotes.append(
            ReplayNote(
                id: UUID(),
                stockCode: stockCode,
                tradeDate: tradeDate,
                ts: ts,
                price: price,
                type: type,
                note: finalNote,
                createdAt: Date()
            )
        )
    }

    func removeReplayNote(id: UUID) {
        replayNotes.removeAll { $0.id == id }
    }

    private func applyMembership(_ result: MemberStatusResponse, successPrefix: String) {
        membershipStatus = result
        if let token = result.token, !token.isEmpty {
            memberToken = token
        }
        if let accountID = result.accountID, !accountID.isEmpty {
            self.accountID = accountID
        }
        if let afdianUID = result.afdianUID, !afdianUID.isEmpty {
            self.afdianUID = afdianUID
        }
        membershipMessage = result.valid
            ? "\(successPrefix) \(result.plan ?? "会员")，剩余 \(result.expireIn ?? "--")"
            : (result.reason ?? "当前账号未开通会员")
        persist()
    }
}

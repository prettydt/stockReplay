import Foundation

struct StockCode: Codable, Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
}

struct MemberStatusResponse: Codable {
    let valid: Bool
    let token: String?
    let accountID: String?
    let afdianUID: String?
    let provider: String?
    let plan: String?
    let expireIn: String?
    let reason: String?
    let productID: String?
    let syncMode: String?
}

struct HealthCheckResponse: Codable {
    let ok: Bool
    let service: String?
    let previewDays: Int?
    let membershipMode: String?
    let appleSyncMode: String?
    let storeProducts: [String]?
    let serverTime: Int?
}

struct DailySummary: Codable {
    let code: String?
    let date: String?
    let open: Double?
    let preClose: Double?
    let close: Double?
    let high: Double?
    let low: Double?
    let volume: Double?
    let amount: Double?
    let chg: Double?
    let pct: Double?

    var formattedVolume: String {
        guard let volume else { return "--" }
        return "\(Int(volume / 100)) 手"
    }

    var formattedAmount: String {
        guard let amount else { return "--" }
        if amount >= 100_000_000 { return String(format: "%.2f 亿", amount / 100_000_000) }
        if amount >= 10_000 { return String(format: "%.2f 万", amount / 10_000) }
        return String(format: "%.0f", amount)
    }
}

struct TickRecord: Codable, Identifiable {
    let ts: String
    let price: Double?
    let volume: Double?
    let amount: Double?
    let open: Double?
    let high: Double?
    let low: Double?
    let preClose: Double?
    let b1p: Double?
    let b1v: Double?
    let b2p: Double?
    let b2v: Double?
    let b3p: Double?
    let b3v: Double?
    let b4p: Double?
    let b4v: Double?
    let b5p: Double?
    let b5v: Double?
    let a1p: Double?
    let a1v: Double?
    let a2p: Double?
    let a2v: Double?
    let a3p: Double?
    let a3v: Double?
    let a4p: Double?
    let a4v: Double?
    let a5p: Double?
    let a5v: Double?

    var id: String { ts }
    var shortTime: String { String(ts.suffix(8)) }

    var priceChange: Double {
        guard let price, let preClose, preClose != 0 else { return 0 }
        return price - preClose
    }

    var priceChangePercent: Double {
        guard let preClose, preClose != 0 else { return 0 }
        return priceChange / preClose * 100
    }
}

struct APIErrorResponse: Codable {
    let error: String?
    let reason: String?
    let previewDates: [String]?
    let needMember: Bool?

    var userMessage: String {
        if let error, !error.isEmpty { return error }
        if let reason, !reason.isEmpty { return reason }
        return "请求失败，请稍后再试。"
    }
}

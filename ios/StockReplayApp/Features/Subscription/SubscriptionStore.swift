import Foundation
import StoreKit

struct PurchasedSubscription {
    let productID: String
    let transactionID: String
}

@MainActor
final class SubscriptionStore: ObservableObject {
    static let productIDs = [
        "com.prettydt.stockreplay.monthly",
        "com.prettydt.stockreplay.yearly"
    ]

    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []
    @Published var isLoading = false
    @Published var storeMessage = "等待连接 App Store Connect 订阅产品。"

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: Self.productIDs)
            await refreshEntitlements()
            if products.isEmpty {
                storeMessage = "还没有从 App Store Connect 拉到产品。请先创建自动续期订阅并使用同样的 Product ID。"
            } else {
                storeMessage = "已加载 \(products.count) 个订阅产品，可以在沙盒环境里测试购买。"
            }
        } catch {
            storeMessage = "加载订阅产品失败：\(error.localizedDescription)"
        }
    }

    func purchase(_ product: Product) async -> PurchasedSubscription? {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verifiedTransaction(from: verification)
                purchasedProductIDs.insert(transaction.productID)
                storeMessage = "购买完成：\(product.displayName)。已准备同步到你的后端会员账号。"
                await transaction.finish()
                return PurchasedSubscription(
                    productID: transaction.productID,
                    transactionID: String(transaction.id)
                )
            case .userCancelled:
                storeMessage = "用户已取消购买。"
            case .pending:
                storeMessage = "交易待处理，等待 App Store 最终确认。"
            @unknown default:
                storeMessage = "收到未知购买结果。"
            }
        } catch {
            storeMessage = "购买失败：\(error.localizedDescription)"
        }
        return nil
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            storeMessage = "已触发恢复购买，请检查会员状态。"
        } catch {
            storeMessage = "恢复购买失败：\(error.localizedDescription)"
        }
    }

    func isPurchased(_ productID: String) -> Bool {
        purchasedProductIDs.contains(productID)
    }

    private func refreshEntitlements() async {
        var newIDs = Set<String>()
        for await result in Transaction.currentEntitlements {
            if let transaction = try? verifiedTransaction(from: result) {
                newIDs.insert(transaction.productID)
            }
        }
        purchasedProductIDs = newIDs
    }

    private func verifiedTransaction<T>(from result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw StoreError.failedVerification
        }
    }
}

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "App Store 交易校验失败。"
        }
    }
}

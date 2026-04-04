import SwiftUI
import StoreKit

private extension View {
    @ViewBuilder
    func accountInputStyle() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    func subscriptionCardStyle(theme: AppTheme) -> some View {
        self
            .padding(12)
            .background(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(theme.accentColor.opacity(0.16), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SubscriptionPlanDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let fallbackPrice: String
    let badge: String?
    let features: [String]

    var isFree: Bool { id == "free" }
}

struct SubscriptionView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var store = SubscriptionStore()

    private var theme: AppTheme { settings.selectedTheme }

    private var monthlyProduct: Product? {
        store.products.first(where: { $0.id == "com.prettydt.stockreplay.monthly" })
    }

    private var yearlyProduct: Product? {
        store.products.first(where: { $0.id == "com.prettydt.stockreplay.yearly" })
    }

    private var planDescriptors: [SubscriptionPlanDescriptor] {
        [
            SubscriptionPlanDescriptor(
                id: "com.prettydt.stockreplay.monthly",
                title: "专业月卡",
                subtitle: "适合按月复盘",
                fallbackPrice: monthlyProduct?.displayPrice ?? "¥100/月",
                badge: nil,
                features: ["完整历史回放", "盘口/成交明细", "快捷键复盘"]
            ),
            SubscriptionPlanDescriptor(
                id: "com.prettydt.stockreplay.yearly",
                title: "专业年卡",
                subtitle: "长期使用更划算",
                fallbackPrice: yearlyProduct?.displayPrice ?? "¥1000/年",
                badge: "推荐",
                features: ["包含全部专业功能", "多股对比同步盯盘", "年付更省"]
            )
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                membershipHeaderCard

                VStack(alignment: .leading, spacing: 10) {
                    Text("订阅方案")
                        .font(.headline)
                    Text("购买后会自动解锁完整历史回放、多股对比和更完整的复盘面板。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 12) {
                        ForEach(planDescriptors) { plan in
                            subscriptionPlanCard(plan)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Label("App Store 安全支付，可随时在系统设置的订阅中取消。", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                if !store.storeMessage.isEmpty {
                    Text(store.storeMessage)
                        .font(.caption)
                        .foregroundStyle(store.storeMessage.contains("失败") || store.storeMessage.contains("还没有") ? .orange : .secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding()
        }
        .navigationTitle("订阅方案")
        .task {
            if store.products.isEmpty {
                await store.loadProducts()
            }
        }
    }

    private var isSubscribed: Bool {
        !store.purchasedProductIDs.isEmpty
    }

    private var membershipHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: isSubscribed ? "crown.fill" : "crown")
                    .font(.title2)
                    .foregroundStyle(isSubscribed ? .yellow : theme.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isSubscribed ? "专业版已开通" : "升级到专业版")
                        .font(.headline)
                    Text(isSubscribed ? "感谢订阅，全部功能已解锁。" : "选择下方方案，点击即可订阅。")
                        .font(.footnote)
                        .foregroundStyle(isSubscribed ? .green : .secondary)
                }

                Spacer()

                Button("恢复购买") {
                    Task { await store.restorePurchases() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
        .subscriptionCardStyle(theme: theme)
    }

    private func subscriptionPlanCard(_ plan: SubscriptionPlanDescriptor) -> some View {
        let isPurchased = store.isPurchased(plan.id)
        let isLoading = store.isLoading
        let accent: Color = plan.id == "com.prettydt.stockreplay.yearly" ? theme.accentColor : .blue

        return Button {
            guard !isPurchased else { return }
            Task { await handlePlanAction(plan) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(plan.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        if isLoading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text(plan.fallbackPrice)
                                .font(.title3.bold())
                                .foregroundStyle(accent)
                        }
                        if let badge = plan.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(accent)
                                .clipShape(Capsule())
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Text(isPurchased ? "✓ 当前方案" : "点击订阅")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isPurchased ? .green : accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(isPurchased ? Color.green.opacity(0.12) : accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .subscriptionCardStyle(theme: theme)
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isPurchased ? Color.green.opacity(0.6) : accent.opacity(isPurchased ? 0.6 : 0.0), lineWidth: isPurchased ? 1.5 : 0)
        )
        .opacity(isPurchased ? 1.0 : 1.0)
    }

    private func product(for id: String) -> Product? {
        store.products.first(where: { $0.id == id })
    }

    private func handlePlanAction(_ plan: SubscriptionPlanDescriptor) async {
        if store.products.isEmpty {
            await store.loadProducts()
        }
        guard let product = product(for: plan.id) else { return }
        _ = await store.purchase(product)
    }
}

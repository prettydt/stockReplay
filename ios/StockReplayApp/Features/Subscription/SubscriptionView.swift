import SwiftUI
import AuthenticationServices

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
}

struct SubscriptionView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var store = SubscriptionStore()
    @State private var serverURLDraft = ""

    var body: some View {
        Form {
            Section("会员状态") {
                Text(settings.membershipMessage)
                    .foregroundStyle(settings.membershipStatus?.valid == true ? .green : .secondary)

                Text(settings.backendStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let status = settings.membershipStatus, status.valid {
                    LabeledContent("套餐", value: status.plan ?? "会员")
                    LabeledContent("来源", value: status.provider ?? "unknown")
                    LabeledContent("Account", value: status.accountID ?? "--")
                    LabeledContent("爱发电UID", value: status.afdianUID ?? "--")
                }

                Button("测试后端连接") {
                    Task { await settings.checkBackendConnection() }
                }

                Button("绑定/刷新会员状态") {
                    Task { await settings.refreshMembership() }
                }
            }

            Section("界面主题") {
                Picker("Theme", selection: $settings.selectedTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    Label("主色", systemImage: "paintpalette")
                    Spacer()
                    Circle().fill(settings.selectedTheme.accentColor).frame(width: 16, height: 16)
                    Circle().fill(settings.selectedTheme.positiveColor).frame(width: 16, height: 16)
                    Circle().fill(settings.selectedTheme.negativeColor).frame(width: 16, height: 16)
                }
                .font(.footnote)

                Text("支持 `默认 / 同花顺 / 大智慧` 三种风格，iPhone、iPad、Mac 会同步使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("App Store 订阅（StoreKit 2 骨架）") {
                Text(store.storeMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("加载 App Store 产品") {
                    Task { await store.loadProducts() }
                }

                Button("恢复购买") {
                    Task {
                        await store.restorePurchases()
                        await settings.refreshMembership()
                    }
                }

                ForEach(store.products, id: \.id) { product in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(product.displayName)
                                    .font(.headline)
                                Text(product.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .font(.headline)
                        }

                        Button(store.isPurchased(product.id) ? "已拥有" : "购买并同步") {
                            Task {
                                if let purchased = await store.purchase(product) {
                                    await settings.syncAppleMembership(
                                        productID: purchased.productID,
                                        transactionID: purchased.transactionID
                                    )
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isPurchased(product.id))
                    }
                    .padding(.vertical, 4)
                }

                Text("购买成功后会自动同步到当前填写的账号，用于解锁完整历史回放。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if store.products.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("预置 Product ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("• com.prettydt.stockreplay.monthly")
                        Text("• com.prettydt.stockreplay.yearly")
                    }
                    .font(.footnote)
                }
            }

            Section("当前过渡方案：爱发电") {
                TextField("你的账号名或邮箱", text: $settings.accountID)
                    .accountInputStyle()
                TextField("爱发电 UID（支付后填写）", text: $settings.afdianUID)
                    .accountInputStyle()
                SecureField("系统 token（自动保存，可不手输）", text: $settings.memberToken)

                Link(destination: settings.afdianPageURL) {
                    Label("去爱发电开通", systemImage: "safari")
                }
                Text("在 App Store Connect 订阅准备好之前，iOS MVP 可以继续复用爱发电绑定流程。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple 用户体系（预留）") {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { _ in
                    settings.membershipMessage = "Sign in with Apple UI 已接上，后端登录接口会在下一阶段补齐。"
                }
                .frame(height: 44)
            }

            Section("后端设置") {
                TextField("Base URL（默认腾讯云）", text: $serverURLDraft)
                    .accountInputStyle()
                Button("保存后端地址") {
                    settings.updateBaseURL(serverURLDraft)
                    serverURLDraft = settings.baseURLString
                }
                Text("当前建议直接使用腾讯云地址：\(AppSettings.cloudBaseURL)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("会员与订阅")
        .onAppear {
            serverURLDraft = settings.baseURLString
        }
        .onDisappear {
            settings.persist()
        }
        .task {
            await settings.checkBackendConnection()
            if settings.membershipStatus == nil,
               !settings.accountID.isEmpty || !settings.afdianUID.isEmpty || !settings.memberToken.isEmpty {
                await settings.refreshMembership()
            }
        }
    }
}

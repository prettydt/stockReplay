import SwiftUI

// MARK: - Pinyin helper
private extension String {
    /// 将汉字字符串转为无声调拼音（含空格分隔）
    var pinyin: String {
        let mutable = NSMutableString(string: self)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return (mutable as String).lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// 每个字的拼音首字母（声母缩写），如"浦发银行" → "pfyx"
    var pinyinInitials: String {
        let mutable = NSMutableString(string: self)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return (mutable as String)
            .components(separatedBy: " ")
            .compactMap { $0.first.map { String($0) } }
            .joined()
            .lowercased()
    }
}

@MainActor
final class StockListViewModel: ObservableObject {
    @Published var stocks: [StockCode] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    // 预计算拼音缓存：code -> (fullPinyin, initials)
    var pinyinCache: [String: (full: String, initials: String)] = [:]

    var filteredStocks: [StockCode] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return stocks }
        let kw = keyword.lowercased()
        return stocks.filter { stock in
            if stock.code.lowercased().contains(kw) { return true }
            if stock.name.lowercased().contains(kw) { return true }
            if let cache = pinyinCache[stock.code] {
                if cache.full.contains(kw) { return true }
                if cache.initials.hasPrefix(kw) { return true }
            }
            return false
        }
    }

    func load(using apiClient: APIClient) async {
        guard stocks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            stocks = try await apiClient.fetchCodes()
            // 后台预计算拼音
            let localStocks = stocks
            Task.detached(priority: .utility) { [weak self] in
                var cache: [String: (full: String, initials: String)] = [:]
                for s in localStocks {
                    cache[s.code] = (s.name.pinyin, s.name.pinyinInitials)
                }
                await MainActor.run { self?.pinyinCache = cache }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct StockListView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = StockListViewModel()
    @State private var selectedStock: StockCode?
    @State private var suppressRecentTracking = false
    @State private var showSpotlight = false
    @State private var showSubscriptionPopover = false

    private var watchlistStocks: [StockCode] {
        settings.watchlistCodes.compactMap { code in
            viewModel.stocks.first(where: { $0.code == code })
        }
    }

    private var compareStocks: [StockCode] {
        settings.compareStockCodes.compactMap { code in
            viewModel.stocks.first(where: { $0.code == code })
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .task {
            await viewModel.load(using: settings.apiClient)
            if selectedStock == nil {
                setSelectedStock(watchlistStocks.first ?? viewModel.stocks.first, recordRecent: false)
            }
        }
        .onChange(of: selectedStock) { _, newValue in
            if suppressRecentTracking {
                suppressRecentTracking = false
                return
            }
            if let code = newValue?.code {
                settings.noteRecentStock(code: code)
            }
        }
        // ⌘K 打开 Spotlight 搜索
        .overlay {
            if showSpotlight {
                SpotlightSearchView(
                    stocks: viewModel.stocks,
                    pinyinCache: viewModel.pinyinCache,
                    onSelect: { stock in
                        showSpotlight = false
                        setSelectedStock(stock)
                    },
                    onDismiss: { showSpotlight = false }
                )
                .environmentObject(settings)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: showSpotlight)
        // 隐藏按钮挂载快捷键，不影响焦点
        .background {
            Button("") { showSpotlight.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSubscriptionPopover.toggle()
                } label: {
                    Image(systemName: settings.membershipStatus?.valid == true ? "crown.fill" : "crown")
                        .font(.headline)
                        .foregroundStyle(settings.membershipStatus?.valid == true ? .yellow : settings.selectedTheme.accentColor)
                }
                .help("查看订阅方案")
            }
        }
        .popover(isPresented: $showSubscriptionPopover, arrowEdge: .top) {
            SubscriptionView()
                .environmentObject(settings)
                .frame(width: 680, height: 540)
        }
    }

    private var sidebarContent: some View {
        WatchlistSidebarView(
            viewModel: viewModel,
            watchlistStocks: watchlistStocks,
            compareStocks: compareStocks,
            selectedStock: $selectedStock,
            onSelect: { setSelectedStock($0) },
            onReload: {
                Task {
                    viewModel.stocks = []
                    await viewModel.load(using: settings.apiClient)
                    setSelectedStock(watchlistStocks.first ?? viewModel.stocks.first, recordRecent: false)
                }
            }
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        #if os(macOS)
        if settings.compareLayoutCount > 1 {
            ReplayCompareWorkspaceView(
                stocks: Array(compareStocks.prefix(settings.compareLayoutCount)),
                slotCount: settings.compareLayoutCount
            )
        } else if let stock = selectedStock {
            ReplayDetailView(stock: stock)
        } else {
            ContentUnavailableView(
                "选择股票开始回放",
                systemImage: "chart.xyaxis.line",
                description: Text("这套界面会同时适配 iPhone、iPad 和 Mac。")
            )
        }
        #else
        if let stock = selectedStock {
            ReplayDetailView(stock: stock)
        } else {
            ContentUnavailableView(
                "选择股票开始回放",
                systemImage: "chart.xyaxis.line",
                description: Text("这套界面会同时适配 iPhone、iPad 和 Mac。")
            )
        }
        #endif
    }

    private func setSelectedStock(_ stock: StockCode?, recordRecent: Bool = true) {
        suppressRecentTracking = !recordRecent
        selectedStock = stock
    }
}

// MARK: - Watchlist Sidebar

private struct WatchlistSidebarView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: StockListViewModel
    let watchlistStocks: [StockCode]
    let compareStocks: [StockCode]
    @Binding var selectedStock: StockCode?
    let onSelect: (StockCode) -> Void
    let onReload: () -> Void

    @State private var prefetchDone = 0
    @State private var prefetchTotal = 0
    @State private var prefetchFinished = false

    private var isPrefetching: Bool { prefetchDone < prefetchTotal }

    // yyyy-MM-dd 字符串 ↔ Date 双向绑定
    private var globalDateBinding: Binding<Date> {
        Binding(
            get: {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                return fmt.date(from: settings.globalSelectedDate) ?? Date()
            },
            set: { date in
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                settings.globalSelectedDate = fmt.string(from: date)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 列表区域
            ZStack(alignment: .top) {
                Group {
                    if viewModel.isLoading {
                        ProgressView("正在加载…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = viewModel.errorMessage {
                        ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(err))
                    } else {
                        List(selection: $selectedStock) {
                            // 全局交易日
                            Section {
                                HStack {
                                    Text("交易日")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    DatePicker("", selection: globalDateBinding, displayedComponents: .date)
                                        .datePickerStyle(.compact)
                                        .labelsHidden()
                                }
                            }

                            Section {
                                if watchlistStocks.isEmpty {
                                    Text("还没有自选股，在个股页面点 ☆ 添加")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(watchlistStocks) { stock in
                                        watchlistRow(stock)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("自选股")
                                    if isPrefetching {
                                        Spacer()
                                        HStack(spacing: 4) {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                                .frame(width: 12, height: 12)
                                            Text("预加载 \(prefetchDone)/\(prefetchTotal)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    } else if prefetchFinished && prefetchTotal > 0 {
                                        Spacer()
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                            .transition(.opacity)
                                    }
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
            }
        }
        .navigationTitle("自选股")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { onReload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

        }
        .task(id: watchlistStocks.map(\.code).joined()) {
            // 股票列表加载完成且有自选股时，后台预下载今日数据到磁盘缓存
            guard !watchlistStocks.isEmpty && !viewModel.isLoading else { return }
            let codes = watchlistStocks.map(\.code)
            prefetchDone = 0
            prefetchTotal = codes.count
            prefetchFinished = false
            await settings.apiClient.prefetchLatestDay(
                codes: codes,
                accountID: settings.accountID,
                afdianUID: settings.afdianUID,
                token: settings.memberToken
            ) { done, total in
                Task { @MainActor in
                    prefetchDone = done
                    prefetchTotal = total
                    if done == total {
                        prefetchFinished = true
                    }
                }
            }
            // 2秒后隐藏完成图标
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            prefetchFinished = false
            prefetchTotal = 0
        }
    }

    private func watchlistRow(_ stock: StockCode) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stock.name).font(.headline)
                Text(stock.code).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                settings.toggleWatchlist(code: stock.code)
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(stock) }
        .tag(stock)
    }
}

// MARK: - Spotlight 全局搜索浮层

private struct SpotlightSearchView: View {
    @EnvironmentObject private var settings: AppSettings
    let stocks: [StockCode]
    let pinyinCache: [String: (full: String, initials: String)]
    let onSelect: (StockCode) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var filtered: [StockCode] = []
    @FocusState private var focused: Bool

    private func updateFiltered(query: String) {
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { filtered = []; return }
        filtered = stocks.filter { s in
            if s.code.lowercased().contains(kw) { return true }
            if s.name.lowercased().contains(kw) { return true }
            if let cache = pinyinCache[s.code] {
                if cache.full.contains(kw) { return true }
                if cache.initials.hasPrefix(kw) { return true }
            }
            return false
        }
    }

    var body: some View {
        ZStack {
            // 暗化背景，点击关闭
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    TextField("搜索股票代码或名称…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title2)
                        .focused($focused)
                        .onSubmit {
                            if let first = filtered.first {
                                onSelect(first)
                            }
                        }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // ESC 提示
                        Text("esc")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                // 分割线
                if !filtered.isEmpty {
                    Divider().opacity(0.5)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered.prefix(12)) { stock in
                                Button {
                                    onSelect(stock)
                                } label: {
                                    HStack(spacing: 14) {
                                        // 市场标签
                                        Text(stock.code.prefix(2).uppercased())
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 3)
                                            .background(
                                                stock.code.hasPrefix("sh") ? Color.red.opacity(0.8) : Color.green.opacity(0.7)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .frame(width: 28)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stock.name)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(stock.code)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button {
                                            settings.toggleWatchlist(code: stock.code)
                                        } label: {
                                            Image(systemName: settings.watchlistCodes.contains(stock.code) ? "star.fill" : "star")
                                                .foregroundStyle(settings.watchlistCodes.contains(stock.code) ? Color.yellow : Color.secondary)
                                        }
                                        .buttonStyle(.plain)

                                        Image(systemName: "arrow.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.clear)

                                if stock.id != filtered.prefix(12).last?.id {
                                    Divider().padding(.leading, 62).opacity(0.4)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }

                // 底部提示栏
                HStack {
                    Label("⌘K 打开 / ESC 关闭", systemImage: "keyboard")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Spacer()
                    if !filtered.isEmpty {
                        Text("共 \(min(filtered.count, 12))/\(filtered.count) 条")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .frame(width: 560)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, newValue in updateFiltered(query: newValue) }
        #if os(macOS)
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        #endif
    }
}

#if os(macOS)
private struct ReplayCompareWorkspaceView: View {
    let stocks: [StockCode]
    let slotCount: Int

    @EnvironmentObject private var settings: AppSettings

    private var columns: [GridItem] {
        let count = slotCount == 4 ? 2 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var slotIndices: [Int] {
        Array(0 ..< max(slotCount, 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("多屏对比工作台")
                            .font(.title3.bold())
                        Text(slotCount == 4 ? "当前为 4 屏对比模式" : "当前为 2 屏对比模式")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Toggle("时间同步", isOn: $settings.compareSyncEnabled)
                            .toggleStyle(.switch)
                        Text("最多 4 屏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)

                if settings.compareSyncEnabled {
                    Label("拖任意一个窗口的十字线，其他窗口会自动同步到同一时刻。", systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                compareGrid
            }
            .padding()
        }
    }

    @ViewBuilder
    private var compareGrid: some View {
        if slotCount == 4 {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    compareSlotView(at: 0)
                    compareSlotView(at: 1)
                }
                HStack(spacing: 12) {
                    compareSlotView(at: 2)
                    compareSlotView(at: 3)
                }
            }
        } else {
            HStack(spacing: 12) {
                compareSlotView(at: 0)
                compareSlotView(at: 1)
            }
        }
    }

    @ViewBuilder
    private func compareSlotView(at index: Int) -> some View {
        if index < stocks.count {
            ReplayDetailView(stock: stocks[index], syncEnabled: true)
        } else {
            ContentUnavailableView(
                "加入对比股票",
                systemImage: "rectangle.split.2x2",
                description: Text("从左侧列表点击叠窗按钮，把股票加入这个对比位。")
            )
            .frame(maxWidth: .infinity, minHeight: slotCount == 4 ? 420 : 680)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
#endif

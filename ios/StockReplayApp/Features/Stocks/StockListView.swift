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
    private var pinyinCache: [String: (full: String, initials: String)] = [:]

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

    @State private var showSearchResults = false
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
        ZStack(alignment: .bottom) {
            // 主列表：只显示自选股
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
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 52) }
                }
            }

            // 搜索结果浮层
            if showSearchResults && !viewModel.searchText.isEmpty {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.filteredStocks.prefix(30)) { stock in
                                Button {
                                    viewModel.searchText = ""
                                    showSearchResults = false
                                    onSelect(stock)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stock.name)
                                                .font(.subheadline.weight(.semibold))
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
                                                .foregroundStyle(settings.watchlistCodes.contains(stock.code) ? .yellow : .secondary)
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: -4)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 52)
                }
            }

            // 底部固定搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("输入代码或名称", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .onSubmit {
                        if let first = viewModel.filteredStocks.first {
                            viewModel.searchText = ""
                            showSearchResults = false
                            onSelect(first)
                        }
                    }
                    .onChange(of: viewModel.searchText) { _, v in
                        showSearchResults = !v.isEmpty
                    }
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        showSearchResults = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(showSearchResults ? settings.selectedTheme.accentColor : Color.clear, lineWidth: 1.5)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
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

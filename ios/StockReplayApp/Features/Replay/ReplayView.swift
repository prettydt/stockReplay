import SwiftUI
import Charts

private struct OrderBookLevel: Identifiable {
    let side: String
    let label: String
    let price: Double?
    let volume: Double?

    var id: String { "\(side)-\(label)" }
}

private struct AveragePricePoint: Identifiable {
    let index: Int
    let value: Double

    var id: Int { index }
}

private struct ReplayNoteMarker: Identifiable {
    let note: ReplayNote
    let index: Int
    let price: Double

    var id: UUID { note.id }
}

private struct ReplayTimeBookmark: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let targetIndex: Int
}

private extension View {
    func replayCardStyle(theme: AppTheme, cornerRadius: CGFloat = 16) -> some View {
        self
            .background(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(theme.accentColor.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

@MainActor
final class ReplayViewModel: ObservableObject {
    @Published var availableDates: [String] = []
    @Published var selectedDate: String = ""
    @Published var summary: DailySummary?
    @Published var ticks: [TickRecord] = []
    @Published var currentIndex = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isPlaying = false
    @Published var playbackSpeed: Double = 2 {
        didSet { if isPlaying { startPlayback() } }
    }

    private var timer: Timer?
    private var loadedStockCode: String?

    var visibleTicks: [TickRecord] {
        guard !ticks.isEmpty else { return [] }
        return Array(ticks.prefix(currentIndex + 1))
    }

    var currentTick: TickRecord? {
        guard ticks.indices.contains(currentIndex) else { return nil }
        return ticks[currentIndex]
    }

    var progressLabel: String {
        guard !ticks.isEmpty else { return "0 / 0" }
        return "\(currentIndex + 1) / \(ticks.count)"
    }

    func loadDates(for stock: StockCode, settings: AppSettings) async {
        let isSwitchingStock = loadedStockCode != stock.code
        if isSwitchingStock {
            resetForNewStock(code: stock.code)
            // 切换股票时，优先使用全局选定日期
            if !settings.globalSelectedDate.isEmpty {
                selectedDate = settings.globalSelectedDate
            }
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            availableDates = try await settings.apiClient.fetchDates(
                code: stock.code,
                accountID: settings.accountID,
                afdianUID: settings.afdianUID,
                token: settings.memberToken
            )
            if !availableDates.contains(selectedDate) {
                selectedDate = availableDates.first ?? ""
            }
            if !selectedDate.isEmpty {
                await loadReplay(for: stock, settings: settings)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadReplay(for stock: StockCode, settings: AppSettings) async {
        guard !selectedDate.isEmpty else { return }
        stopPlayback()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let summary = settings.apiClient.fetchSummary(
                code: stock.code,
                date: selectedDate,
                accountID: settings.accountID,
                afdianUID: settings.afdianUID,
                token: settings.memberToken
            )
            async let ticks = settings.apiClient.fetchTicks(
                code: stock.code,
                date: selectedDate,
                accountID: settings.accountID,
                afdianUID: settings.afdianUID,
                token: settings.memberToken
            )
            self.summary = try await summary
            self.ticks = try await ticks
            self.currentIndex = 0
        } catch {
            self.summary = nil
            self.ticks = []
            self.errorMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        guard !ticks.isEmpty else { return }
        stopPlayback()
        isPlaying = true
        let interval = max(0.05, 0.6 / playbackSpeed)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentIndex < self.ticks.count - 1 {
                    self.currentIndex += 1
                } else {
                    self.stopPlayback()
                }
            }
        }
    }

    func stopPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    deinit {
        timer?.invalidate()
    }

    private func resetForNewStock(code: String) {
        stopPlayback()
        loadedStockCode = code
        availableDates = []
        selectedDate = ""
        summary = nil
        ticks = []
        currentIndex = 0
    }
}

struct ReplayDetailView: View {
    let stock: StockCode
    let syncEnabled: Bool

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = ReplayViewModel()
    @State private var replayNoteDraft = ""
    @State private var selectedReplayType: ReplayMarkType = .breakout
    @State private var paneSyncID = UUID()
    @State private var isApplyingExternalSync = false

    init(stock: StockCode, syncEnabled: Bool = false) {
        self.stock = stock
        self.syncEnabled = syncEnabled
    }

    private var theme: AppTheme { settings.selectedTheme }
    private var currentTradeDate: String { viewModel.selectedDate }
    private var chartTicks: [TickRecord] { viewModel.visibleTicks }
    private var recentTrades: [TickRecord] { Array(viewModel.visibleTicks.suffix(12).reversed()) }
    private var savedReplayNotes: [ReplayNote] {
        settings.replayNotes(for: stock.code, tradeDate: currentTradeDate)
    }
    private var averagePricePoints: [AveragePricePoint] {
        var cumulativeVolume = 0.0
        var cumulativeAmount = 0.0
        return chartTicks.enumerated().compactMap { index, tick in
            cumulativeVolume += tick.volume ?? 0
            cumulativeAmount += tick.amount ?? 0
            guard cumulativeVolume > 0 else { return nil }
            return AveragePricePoint(index: index, value: cumulativeAmount / cumulativeVolume)
        }
    }
    private var replayNoteMarkers: [ReplayNoteMarker] {
        savedReplayNotes.compactMap { note in
            guard let index = viewModel.ticks.firstIndex(where: { $0.ts == note.ts }) else { return nil }
            guard let markerPrice = viewModel.ticks[index].price ?? note.price else { return nil }
            return ReplayNoteMarker(note: note, index: index, price: markerPrice)
        }
    }
    private var previousClose: Double? { viewModel.summary?.preClose ?? chartTicks.first?.preClose }
    private var dailyLimitRate: Double {
        (stock.code.hasPrefix("sz300") || stock.code.hasPrefix("sh688")) ? 0.20 : 0.10
    }
    private var replayBookmarks: [ReplayTimeBookmark] {
        guard !viewModel.ticks.isEmpty else { return [] }
        return [
            ReplayTimeBookmark(id: "open", title: "开盘", subtitle: "开盘前段", targetIndex: nearestIndex(for: "09:30:00") ?? 0),
            ReplayTimeBookmark(id: "firstPush", title: "首次拉升", subtitle: "上午异动", targetIndex: strongestMoveIndex(in: "09:30:00", to: "10:30:00")),
            ReplayTimeBookmark(id: "pullback", title: "首次回落", subtitle: "冲高后观察", targetIndex: weakestMoveIndex(in: "09:45:00", to: "11:00:00")),
            ReplayTimeBookmark(id: "afternoon", title: "午后", subtitle: "13点后", targetIndex: nearestIndex(for: "13:00:00") ?? fallbackIndex(0.55)),
            ReplayTimeBookmark(id: "tail", title: "尾盘", subtitle: "收盘前", targetIndex: nearestIndex(for: "14:45:00") ?? fallbackIndex(0.9))
        ]
    }
    private var upperLimitPrice: Double? { previousClose.map { $0 * (1 + dailyLimitRate) } }
    private var lowerLimitPrice: Double? { previousClose.map { $0 * (1 - dailyLimitRate) } }
    private var lastPriceColor: Color {
        guard let tick = viewModel.currentTick else { return theme.accentColor }
        return tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor
    }

    private var axisMarkIndices: [Int] {
        guard !chartTicks.isEmpty else { return [] }
        let step = max(chartTicks.count / 4, 1)
        var indices = Array(stride(from: 0, to: chartTicks.count, by: step))
        if let last = chartTicks.indices.last, indices.last != last {
            indices.append(last)
        }
        return indices
    }

    private var priceAxisDomain: ClosedRange<Double> {
        let prices = chartTicks.compactMap(\.price)
        let averagePrices = averagePricePoints.map(\.value)
        let referencePrices = [previousClose].compactMap { $0 }
        let allPrices = prices + averagePrices + referencePrices

        guard let minPrice = allPrices.min(), let maxPrice = allPrices.max() else {
            return 0...1
        }

        let spread = max(maxPrice - minPrice, maxPrice * 0.003)
        let padding = max(spread * 0.18, 0.02)
        let lowerBound = max(0, minPrice - padding)
        let upperBound = maxPrice + padding
        return lowerBound...upperBound
    }

    private var priceAxisMarks: [Double] {
        let domain = priceAxisDomain
        let step = (domain.upperBound - domain.lowerBound) / 4
        var marks = (0 ... 4).map { index in
            ((domain.lowerBound + (step * Double(index))) * 100).rounded() / 100
        }

        if let previousClose {
            marks.append((previousClose * 100).rounded() / 100)
        }

        return Array(Set(marks)).sorted()
    }

    private func percentText(for price: Double) -> String {
        guard let previousClose, previousClose != 0 else { return "--" }
        let percent = ((price - previousClose) / previousClose) * 100
        return String(format: "%+.2f%%", percent)
    }

    private func axisColor(for price: Double) -> Color {
        guard let previousClose else { return .secondary }
        if abs(price - previousClose) < 0.0001 {
            return .secondary
        }
        return price >= previousClose ? theme.positiveColor : theme.negativeColor
    }

    private var playbackUpperBound: Int {
        max(viewModel.ticks.count - 1, 0)
    }

    private var playbackSliderRange: ClosedRange<Double> {
        0...Double(max(playbackUpperBound, 1))
    }

    private var playbackSliderValue: Binding<Double> {
        Binding(
            get: {
                Double(min(max(viewModel.currentIndex, 0), playbackUpperBound))
            },
            set: { newValue in
                let clampedIndex = min(max(Int(newValue.rounded()), 0), playbackUpperBound)
                viewModel.currentIndex = clampedIndex
            }
        )
    }

    private func formattedShares(_ volume: Double?) -> String {
        guard let volume else { return "--" }
        return "\(Int(volume / 100)) 手"
    }

    private func formattedTurnover(_ amount: Double?) -> String {
        guard let amount else { return "--" }
        if amount >= 100_000_000 { return String(format: "%.2f 亿", amount / 100_000_000) }
        if amount >= 10_000 { return String(format: "%.2f 万", amount / 10_000) }
        return String(format: "%.0f", amount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if !os(macOS)
                topControls
                #endif

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .padding(.horizontal, 4)
                }

                if viewModel.isLoading {
                    ProgressView("正在加载回放数据…")
                        .frame(maxWidth: .infinity)
                } else if viewModel.visibleTicks.isEmpty {
                    ContentUnavailableView("暂无分时数据", systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    #if os(macOS)
                    desktopReplayWorkspace
                    #else
                    desktopWorkspaceHeader

                    if let summary = viewModel.summary {
                        marketPulseRibbon(summary)
                        summaryGrid(summary)
                    }

                    adaptiveReplayContent
                    #endif
                }
            }
            .padding()
        }
        .background(theme.pageBackground.ignoresSafeArea())
        .navigationTitle(stock.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    settings.toggleWatchlist(code: stock.code)
                } label: {
                    Image(systemName: settings.watchlistCodes.contains(stock.code) ? "star.fill" : "star")
                        .foregroundStyle(settings.watchlistCodes.contains(stock.code) ? .yellow : .secondary)
                }
            }
        }
        .task(id: stock.code) {
            await viewModel.loadDates(for: stock, settings: settings)
        }
        .onChange(of: viewModel.currentIndex) { _, newValue in
            publishCompareSyncIfNeeded(for: newValue)
        }
        .onChange(of: viewModel.ticks.count) { _, _ in
            applyExternalSyncIfNeeded()
        }
        .onChange(of: settings.compareSyncSignal) { _, _ in
            applyExternalSyncIfNeeded()
        }
    }

    private var desktopReplayWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            timelinePlaybackCard

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    priceChartCard
                    volumeChartCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    orderBookCard
                    recentTradesCard
                }
                .frame(width: 360)
            }
        }
    }

    private var desktopInstrumentStrip: some View {
        HStack(spacing: 14) {
            Label(stock.code.replacingOccurrences(of: "sh", with: "").replacingOccurrences(of: "sz", with: ""), systemImage: "rectangle.leadinghalf.inset.filled")
                .font(.headline)
                .foregroundStyle(theme.chartLineColor)

            HStack(spacing: 10) {
                stripTag("分时", selected: true)
                stripTag("多日")
                stripTag("日K")
                stripTag("周K")
                stripTag("月K")
                stripTag("Tick")
            }

            Spacer()

            Text(stock.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .replayCardStyle(theme: theme, cornerRadius: 12)
    }

    private var quoteSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stock.code.replacingOccurrences(of: "sh", with: "").replacingOccurrences(of: "sz", with: ""))
                        .font(.title3.bold())
                    Text(stock.name)
                        .font(.headline)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(viewModel.currentTick?.price.map { String(format: "%.2f", $0) } ?? "--")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(lastPriceColor)
                    Text(String(format: "%+.2f%%", viewModel.currentTick?.priceChangePercent ?? 0))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(lastPriceColor)
                }
            }

            VStack(spacing: 8) {
                quoteRow("最新价", viewModel.currentTick?.price.map { String(format: "%.2f", $0) } ?? "--", color: lastPriceColor,
                         "均价", averagePricePoints.last.map { String(format: "%.2f", $0.value) } ?? "--", color: .yellow)
                quoteRow("最高价", viewModel.summary?.high.map { String(format: "%.2f", $0) } ?? "--", color: theme.positiveColor,
                         "开盘价", viewModel.summary?.open.map { String(format: "%.2f", $0) } ?? "--")
                quoteRow("最低价", viewModel.summary?.low.map { String(format: "%.2f", $0) } ?? "--", color: theme.negativeColor,
                         "昨收价", viewModel.summary?.preClose.map { String(format: "%.2f", $0) } ?? "--")
                quoteRow("成交量", formattedShares(viewModel.currentTick?.volume),
                         "成交额", formattedTurnover(viewModel.currentTick?.amount))
                quoteRow("交易日", viewModel.selectedDate.isEmpty ? "--" : viewModel.selectedDate,
                         "回放", "\(Int(viewModel.playbackSpeed))x")
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }
    private var topControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stock.code)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Picker("交易日", selection: $viewModel.selectedDate) {
                    ForEach(viewModel.availableDates, id: \.self) { date in
                        Text(date).tag(date)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedDate) { _, newDate in
                    settings.globalSelectedDate = newDate
                    Task { await viewModel.loadReplay(for: stock, settings: settings) }
                }

                Picker("倍速", selection: $viewModel.playbackSpeed) {
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("5x").tag(5.0)
                    Text("10x").tag(10.0)
                    Text("30x").tag(30.0)
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.playbackSpeed) { _, _ in
                    if viewModel.isPlaying {
                        viewModel.startPlayback()
                    }
                }
            }

            if !replayBookmarks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(replayBookmarks) { bookmark in
                            Button {
                                jumpToBookmark(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(.caption.weight(.semibold))
                                    Text(bookmark.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(theme.ribbonBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text("使用回放进度与关键时段按钮定位行情，桌面布局会保持接近盯盘终端的分区展示。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var adaptiveReplayContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    priceChartCard
                    volumeChartCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 16) {
                    sessionStatusCard
                    timelinePlaybackCard
                    replayNotesCard
                    orderBookCard
                    recentTradesCard
                }
                .frame(width: 360)
            }

            VStack(spacing: 16) {
                sessionStatusCard
                timelinePlaybackCard
                priceChartCard
                volumeChartCard
                replayNotesCard
                orderBookCard
                recentTradesCard
            }
        }
    }

    private var desktopWorkspaceHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(theme.workspaceTitle)
                    .font(.caption)
                    .foregroundStyle(theme.accentColor)
                Text("\(stock.name) · 桌面盯盘")
                    .font(.title3.bold())
                Text(theme.workspaceSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(viewModel.selectedDate.isEmpty ? "未选择交易日" : viewModel.selectedDate)
                    .font(.headline)
                Text("Theme · \(theme.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private func marketPulseRibbon(_ summary: DailySummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                metricPill(title: "最新", value: summary.close.map { String(format: "%.2f", $0) } ?? "--", tint: lastPriceColor)
                metricPill(title: "涨跌", value: summary.chg.map { String(format: "%+.2f", $0) } ?? "--", tint: lastPriceColor)
                metricPill(title: "振幅", value: summary.pct.map { String(format: "%.2f%%", abs($0)) } ?? "--", tint: theme.accentColor)
                metricPill(title: "成交量", value: summary.formattedVolume, tint: theme.chartLineColor)
                metricPill(title: "成交额", value: summary.formattedAmount, tint: theme.chartLineColor)
                metricPill(title: "回放", value: "\(Int(viewModel.playbackSpeed))x", tint: theme.accentColor)
            }
            .padding(.horizontal, 2)
        }
    }

    private var clockCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.currentTick?.shortTime ?? "--:--:--")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accentColor)
                Text(viewModel.progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let tick = viewModel.currentTick {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.2f", tick.price ?? 0))
                        .font(.title2.bold())
                        .foregroundStyle(tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor)
                    Text(String(format: "%+.2f%%", tick.priceChangePercent))
                        .font(.caption)
                        .foregroundStyle(tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor)
                }
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var priceChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("分时价格")
                    .font(.headline)
                Spacer()
                inspectionInfoBox
            }

            Chart {
                ForEach(Array(chartTicks.enumerated()), id: \.offset) { index, tick in
                    if let price = tick.price {
                        LineMark(
                            x: .value("序号", index),
                            y: .value("价格", price)
                        )
                        .foregroundStyle(theme.chartLineColor)
                        .interpolationMethod(.linear)
                    }
                }

                if let previousClose {
                    RuleMark(y: .value("昨收", previousClose))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }

                ForEach(replayNoteMarkers) { marker in
                    PointMark(
                        x: .value("关键点", marker.index),
                        y: .value("价格", marker.price)
                    )
                    .foregroundStyle(marker.note.type.tint(for: theme))
                    .symbolSize(70)
                    .annotation(position: .top) {
                        Image(systemName: marker.note.type.symbolName)
                            .font(.caption2)
                            .foregroundStyle(marker.note.type.tint(for: theme))
                    }
                }

                if let currentTick = viewModel.currentTick, let currentPrice = currentTick.price {
                    RuleMark(x: .value("游标", viewModel.currentIndex))
                        .foregroundStyle(theme.accentColor.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    RuleMark(y: .value("价格横线", currentPrice))
                        .foregroundStyle(lastPriceColor.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    PointMark(
                        x: .value("游标", viewModel.currentIndex),
                        y: .value("价格", currentPrice)
                    )
                    .foregroundStyle(lastPriceColor)
                    .symbolSize(40)
                }
            }
            .chartYScale(domain: priceAxisDomain)
            .chartXAxis {
                AxisMarks(values: axisMarkIndices) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let index = value.as(Int.self), chartTicks.indices.contains(index) {
                            Text(chartTicks[index].shortTime)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: priceAxisMarks) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(String(format: "%.2f", price))
                                .foregroundStyle(axisColor(for: price))
                        }
                    }
                }

                AxisMarks(position: .trailing, values: priceAxisMarks) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(percentText(for: price))
                                .foregroundStyle(axisColor(for: price))
                        }
                    }
                }
            }
            .frame(height: 240)
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var inspectionInfoBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(viewModel.currentTick?.shortTime ?? "--:--:--")
                    .font(.caption.bold())
                Spacer()
                Text("当前数据")
                    .font(.caption2)
                    .foregroundStyle(theme.accentColor)
            }

            Divider()

            infoLine("价格", viewModel.currentTick?.price.map { String(format: "%.2f", $0) } ?? "--", color: lastPriceColor)
            infoLine("涨跌", String(format: "%+.2f%%", viewModel.currentTick?.priceChangePercent ?? 0), color: lastPriceColor)
            infoLine("成交量", formattedShares(viewModel.currentTick?.volume))
            infoLine("成交额", formattedTurnover(viewModel.currentTick?.amount))
        }
        .font(.caption2.monospacedDigit())
        .padding(10)
        .frame(minWidth: 150)
        .background(theme.cardBackground.opacity(0.98))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var volumeChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("成交量")
                .font(.headline)

            Chart {
                ForEach(Array(chartTicks.enumerated()), id: \.offset) { index, tick in
                    if let volume = tick.volume {
                        BarMark(
                            x: .value("序号", index),
                            y: .value("成交量", volume)
                        )
                        .foregroundStyle((tick.priceChange >= 0) ? theme.positiveColor : theme.negativeColor)
                    }
                }

                RuleMark(x: .value("游标", viewModel.currentIndex))
                    .foregroundStyle(theme.accentColor.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxis {
                AxisMarks(values: axisMarkIndices) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let index = value.as(Int.self), chartTicks.indices.contains(index) {
                            Text(chartTicks[index].shortTime)
                        }
                    }
                }
            }
            .frame(height: 140)
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var sessionStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("桌面面板")
                .font(.headline)

            statusRow("样式", theme.rawValue)
            statusRow("工作台", theme.workspaceTitle)
            statusRow("交易日", viewModel.selectedDate.isEmpty ? "--" : viewModel.selectedDate)
            statusRow("当前进度", viewModel.progressLabel)
            statusRow("回放倍速", "\(Int(viewModel.playbackSpeed))x")
            statusRow("关键点", "\(savedReplayNotes.count) 条")
            statusRow("会员状态", settings.membershipStatus?.valid == true ? "已解锁" : "免费预览")
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var timelinePlaybackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 日期选择
            HStack(spacing: 8) {
                Text("交易日")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $viewModel.selectedDate) {
                    ForEach(viewModel.availableDates, id: \.self) { date in
                        Text(date).tag(date)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedDate) { _, newDate in
                    settings.globalSelectedDate = newDate
                    Task { await viewModel.loadReplay(for: stock, settings: settings) }
                }
            }

            Divider()

            // 大时钟 + 当前价格
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.currentTick?.shortTime ?? "--:--:--")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accentColor)
                    Text(viewModel.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let tick = viewModel.currentTick {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f", tick.price ?? 0))
                            .font(.title3.bold())
                            .foregroundStyle(tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor)
                        Text(String(format: "%+.2f%%", tick.priceChangePercent))
                            .font(.caption)
                            .foregroundStyle(tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor)
                    }
                }
            }

            // 进度条
            Slider(
                value: playbackSliderValue,
                in: playbackSliderRange,
                step: 1
            )
            .disabled(viewModel.ticks.count <= 1)
            .tint(theme.accentColor)

            // QuickTime 风格：⏮ ◀ ⏯ ▶ 倍速
            HStack(spacing: 8) {
                // 1. 重置到起点
                Button {
                    viewModel.stopPlayback()
                    viewModel.currentIndex = 0
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)

                // 2. 上一 tick
                Button {
                    viewModel.currentIndex = max(0, viewModel.currentIndex - 1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.currentIndex <= 0)

                // 3. 播放 / 暂停（主按钮，撑满剩余空间）
                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)

                // 4. 下一 tick
                Button {
                    viewModel.currentIndex = min(viewModel.ticks.count - 1, viewModel.currentIndex + 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.currentIndex >= viewModel.ticks.count - 1)

                // 5. 倍速循环切换
                Button {
                    let steps: [Double] = [1, 2, 4, 8]
                    let next = steps.first(where: { $0 > viewModel.playbackSpeed }) ?? steps[0]
                    viewModel.playbackSpeed = next
                } label: {
                    Text(viewModel.playbackSpeed.truncatingRemainder(dividingBy: 1) == 0
                         ? "\(Int(viewModel.playbackSpeed))x"
                         : "\(viewModel.playbackSpeed)x")
                        .monospacedDigit()
                        .frame(minWidth: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var replayNotesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("关键点复盘")
                    .font(.headline)
                Spacer()
                Text(viewModel.currentTick?.shortTime ?? "--:--:--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("标记类型", selection: $selectedReplayType) {
                ForEach(ReplayMarkType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.menu)

            TextField("写一句复盘备注，比如：首次放量突破 / 承接转弱", text: $replayNoteDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("标记当前点") {
                    addCurrentReplayNote()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(viewModel.currentTick == nil || currentTradeDate.isEmpty)

                if !replayNoteDraft.isEmpty {
                    Button("清空") {
                        replayNoteDraft = ""
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            if savedReplayNotes.isEmpty {
                Text("还没有关键点标记。复盘时在关键位置点一下保存，后面就能快速回看。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(savedReplayNotes) { note in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: note.type.symbolName)
                            .foregroundStyle(note.type.tint(for: theme))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(note.ts) · \(note.type.rawValue)")
                                .font(.subheadline.weight(.semibold))
                            if let price = note.price {
                                Text(String(format: "价格 %.2f", price))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(note.note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("定位") {
                            jumpToReplayNote(note)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            settings.removeReplayNote(id: note.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var recentTradesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("成交明细")
                    .font(.headline)
                Spacer()
                Text("最近 \(recentTrades.count) 笔")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recentTrades.isEmpty {
                Text("暂无成交明细")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    HStack {
                        Text("时间")
                        Spacer()
                        Text("价格")
                        Text("手数")
                            .frame(width: 56, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(recentTrades) { tick in
                        HStack {
                            Text(tick.shortTime)
                            Spacer()
                            Text(String(format: "%.2f", tick.price ?? 0))
                                .foregroundStyle(tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor)
                            Text("\(Int((tick.volume ?? 0) / 100))")
                                .frame(width: 56, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote.monospacedDigit())
                    }
                }
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    private var orderBookCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("盘口")
                .font(.headline)

            if let tick = viewModel.currentTick {
                let asks = [
                    OrderBookLevel(side: "ask", label: "卖五", price: tick.a5p, volume: tick.a5v),
                    OrderBookLevel(side: "ask", label: "卖四", price: tick.a4p, volume: tick.a4v),
                    OrderBookLevel(side: "ask", label: "卖三", price: tick.a3p, volume: tick.a3v),
                    OrderBookLevel(side: "ask", label: "卖二", price: tick.a2p, volume: tick.a2v),
                    OrderBookLevel(side: "ask", label: "卖一", price: tick.a1p, volume: tick.a1v)
                ]
                let bids = [
                    OrderBookLevel(side: "bid", label: "买一", price: tick.b1p, volume: tick.b1v),
                    OrderBookLevel(side: "bid", label: "买二", price: tick.b2p, volume: tick.b2v),
                    OrderBookLevel(side: "bid", label: "买三", price: tick.b3p, volume: tick.b3v),
                    OrderBookLevel(side: "bid", label: "买四", price: tick.b4p, volume: tick.b4v),
                    OrderBookLevel(side: "bid", label: "买五", price: tick.b5p, volume: tick.b5v)
                ]

                VStack(spacing: 6) {
                    ForEach(asks) { row in orderBookRow(row, color: theme.negativeColor) }
                    Divider().padding(.vertical, 4)
                    HStack {
                        Text("最新")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f", tick.price ?? 0))
                            .foregroundStyle(tick.priceChange >= 0 ? theme.positiveColor : theme.negativeColor)
                            .font(.headline)
                    }
                    Divider().padding(.vertical, 4)
                    ForEach(bids) { row in orderBookRow(row, color: theme.positiveColor) }
                }
            }
        }
        .padding()
        .replayCardStyle(theme: theme)
    }

    @ViewBuilder
    private func summaryGrid(_ summary: DailySummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            summaryCell("最新价", summary.close)
            summaryCell("涨跌额", summary.chg)
            summaryCell("涨跌幅", summary.pct, suffix: "%")
            summaryCell("今开", summary.open)
            summaryCell("昨收", summary.preClose)
            summaryCell("最高", summary.high)
            summaryCell("最低", summary.low)
            textSummaryCell("成交量", summary.formattedVolume)
            textSummaryCell("成交额", summary.formattedAmount)
        }
    }

    private func summaryCell(_ title: String, _ value: Double?, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.2f%@", $0, suffix) } ?? "--")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .replayCardStyle(theme: theme, cornerRadius: 12)
    }

    private func metricPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.ribbonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stripTag(_ title: String, selected: Bool = false) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.white : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? theme.accentColor.opacity(0.85) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func quoteRow(_ leftTitle: String, _ leftValue: String, color leftColor: Color? = nil, _ rightTitle: String, _ rightValue: String, color rightColor: Color? = nil) -> some View {
        HStack(spacing: 18) {
            quoteItem(leftTitle, leftValue, color: leftColor)
            quoteItem(rightTitle, rightValue, color: rightColor)
        }
    }

    private func quoteItem(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func infoLine(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(color ?? .primary)
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func textSummaryCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .replayCardStyle(theme: theme, cornerRadius: 12)
    }

    private func orderBookRow(_ row: OrderBookLevel, color: Color) -> some View {
        HStack {
            Text(row.label)
                .foregroundStyle(color)
            Spacer()
            Text(row.price.map { String(format: "%.2f", $0) } ?? "--")
                .monospacedDigit()
            Text(row.volume.map { "\(Int($0))" } ?? "--")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 60, alignment: .trailing)
        }
        .font(.footnote)
    }

    private func addCurrentReplayNote() {
        guard let tick = viewModel.currentTick, !currentTradeDate.isEmpty else { return }
        settings.addReplayNote(
            stockCode: stock.code,
            tradeDate: currentTradeDate,
            ts: tick.ts,
            price: tick.price,
            type: selectedReplayType,
            note: replayNoteDraft
        )
        replayNoteDraft = ""
    }

    private func jumpToBookmark(_ bookmark: ReplayTimeBookmark) {
        let clamped = min(max(bookmark.targetIndex, 0), max(viewModel.ticks.count - 1, 0))
        if viewModel.isPlaying { viewModel.stopPlayback() }
        viewModel.currentIndex = clamped
    }

    private func jumpToReplayNote(_ note: ReplayNote) {
        guard let index = viewModel.ticks.firstIndex(where: { $0.ts == note.ts }) else { return }
        if viewModel.isPlaying { viewModel.stopPlayback() }
        viewModel.currentIndex = index
    }

    private func publishCompareSyncIfNeeded(for index: Int) {
        guard syncEnabled, settings.compareSyncEnabled else { return }
        guard viewModel.ticks.indices.contains(index) else { return }
        if isApplyingExternalSync {
            isApplyingExternalSync = false
            return
        }
        settings.publishCompareSync(time: viewModel.ticks[index].shortTime, sourceID: paneSyncID)
    }

    private func applyExternalSyncIfNeeded() {
        guard syncEnabled, settings.compareSyncEnabled else { return }
        guard settings.compareSyncSourceID != paneSyncID else { return }
        let targetTime = settings.compareSyncTime
        guard !targetTime.isEmpty, let index = nearestIndex(for: targetTime) else { return }
        guard viewModel.currentIndex != index else { return }
        isApplyingExternalSync = true
        if viewModel.isPlaying { viewModel.stopPlayback() }
        viewModel.currentIndex = index
    }

    private func nearestIndex(for time: String) -> Int? {
        guard !viewModel.ticks.isEmpty else { return nil }
        let targetSeconds = secondsSinceMidnight(time)
        return viewModel.ticks.enumerated().min { lhs, rhs in
            abs(secondsSinceMidnight(lhs.element.shortTime) - targetSeconds) < abs(secondsSinceMidnight(rhs.element.shortTime) - targetSeconds)
        }?.offset
    }

    private func fallbackIndex(_ ratio: Double) -> Int {
        guard !viewModel.ticks.isEmpty else { return 0 }
        return min(max(Int(Double(viewModel.ticks.count - 1) * ratio), 0), max(viewModel.ticks.count - 1, 0))
    }

    private func strongestMoveIndex(in start: String, to end: String) -> Int {
        rankedMoveIndex(in: start, to: end, pickStrongest: true) ?? nearestIndex(for: start) ?? fallbackIndex(0.15)
    }

    private func weakestMoveIndex(in start: String, to end: String) -> Int {
        rankedMoveIndex(in: start, to: end, pickStrongest: false) ?? nearestIndex(for: end) ?? fallbackIndex(0.28)
    }

    private func rankedMoveIndex(in start: String, to end: String, pickStrongest: Bool) -> Int? {
        let startSeconds = secondsSinceMidnight(start)
        let endSeconds = secondsSinceMidnight(end)
        let candidates = viewModel.ticks.enumerated().filter { element in
            let ts = secondsSinceMidnight(element.element.shortTime)
            return ts >= startSeconds && ts <= endSeconds
        }
        guard !candidates.isEmpty else { return nil }
        if pickStrongest {
            return candidates.max { ($0.element.priceChangePercent) < ($1.element.priceChangePercent) }?.offset
        }
        return candidates.min { ($0.element.priceChangePercent) < ($1.element.priceChangePercent) }?.offset
    }

    private func secondsSinceMidnight(_ value: String) -> Int {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

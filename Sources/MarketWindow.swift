import AppKit
import SwiftUI
import Charts

@MainActor
final class MarketModel: ObservableObject {
    @Published var snapshots: [MarketIndex: MarketSnapshot] = [:]
    @Published private(set) var indexQuotes: [MarketIndex: MarketQuote] = [:]
    @Published private(set) var indexErrors: [MarketIndex: String] = [:]
    @Published var errors: [MarketIndex: String] = [:]
    @Published var refreshing = false
    @Published var selected: MarketIndex = .shanghai
    @Published private(set) var favorites: [SecurityID] = []
    @Published private(set) var favoriteCache: [SecurityID: MarketQuote] = [:]
    @Published var favoriteError: String?
    var lastAttempt = Date.distantPast
    var onChange: (() -> Void)?
    var onRefreshCompleted: (() -> Void)?
    let cacheURL: URL
    let preferencesURL: URL
    let favoriteCacheURL: URL
    let indexCacheURL: URL
    private var lastLogKey: String?

    init(directory: URL) {
        cacheURL = directory.appendingPathComponent("market-cache.json")
        preferencesURL = directory.appendingPathComponent("market-preferences.json")
        favoriteCacheURL = directory.appendingPathComponent("favorite-quotes.json")
        indexCacheURL = directory.appendingPathComponent("index-quotes.json")
        if let data = try? Data(contentsOf: cacheURL), let values = try? JSONDecoder().decode([MarketSnapshot].self, from: data) {
            for snapshot in values {
                snapshots[snapshot.index] = snapshot
                indexQuotes[snapshot.index] = snapshot.quote
            }
        }
        if let data = try? Data(contentsOf: indexCacheURL), let quotes = try? JSONDecoder().decode([MarketQuote].self, from: data) {
            for quote in quotes {
                guard let index = MarketIndex.allCases.first(where: { $0.security == quote.security }),
                      quote.price != nil, quote.percent != nil, let updated = quote.updatedAt,
                      updated >= (indexQuotes[index]?.updatedAt ?? .distantPast) else { continue }
                indexQuotes[index] = quote
            }
        }
        if let data = try? Data(contentsOf: preferencesURL), let value = try? JSONDecoder().decode([SecurityID].self, from: data) {
            var seen = Set<SecurityID>()
            favorites = value.filter { SecurityID.parse($0.id) != nil && seen.insert($0).inserted }
        }
        if let data = try? Data(contentsOf: favoriteCacheURL), let quotes = try? JSONDecoder().decode([MarketQuote].self, from: data) {
            for quote in quotes where favorites.contains(quote.security) { favoriteCache[quote.security] = quote }
        }
        // 最旧范围决定是否需要刷新，避免一个新快照掩盖另一个过期范围。
        if snapshots.count == MarketIndex.allCases.count, let cached = snapshots.values.map(\.fetchedAt).min() {
            lastAttempt = cached
        }
    }
    func automaticRefreshInterval(at date: Date = Date()) -> TimeInterval? {
        MarketRefreshSchedule.interval(at: date, snapshots: snapshots, hasError: !errors.isEmpty)
    }
    var retryHint: String {
        guard let interval = automaticRefreshInterval() else { return "可点击“刷新行情”重试" }
        return "自动重试间隔\(Int(interval / 60))分钟"
    }
    func refreshIfDue(interval: TimeInterval) {
        if Date().timeIntervalSince(lastAttempt) >= interval { refresh() }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = Date()
        Task {
            async let favoriteUpdates = MarketAPI.fetchFavoriteQuotes(favorites)
            let results = await MarketAPI.fetchAll()
            apply(results)
            updateFavoriteQuotes(await favoriteUpdates)
            refreshing = false
            onRefreshCompleted?()
            onChange?()
        }
    }
    func apply(_ results: [MarketResult]) {
        errors.removeAll()
        indexErrors.removeAll()
        for result in results {
            let quote = result.indexQuote ?? result.snapshot?.quote
            if let quote = quote, quote.security == result.index.security,
               quote.price != nil, quote.percent != nil, let updated = quote.updatedAt {
                if updated >= (indexQuotes[result.index]?.updatedAt ?? .distantPast) { indexQuotes[result.index] = quote }
            } else { indexErrors[result.index] = result.error ?? "指数行情查询失败" }
            if let snapshot = result.snapshot { snapshots[result.index] = snapshot }
            else { errors[result.index] = result.error ?? "榜单查询失败" }
        }
        if let data = try? JSONEncoder().encode(MarketIndex.allCases.compactMap { snapshots[$0] }) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(MarketIndex.allCases.compactMap { indexQuotes[$0] }) {
            try? data.write(to: indexCacheURL, options: .atomic)
        }
        let key = MarketIndex.allCases.map { "\($0.rawValue):\(errors[$0] ?? "成功"):\(snapshots[$0]?.memberCount ?? 0)" }.joined(separator: "|")
        if key != lastLogKey || !errors.isEmpty {
            let details = results.map { result in
                "\(result.index.name) \(result.error ?? "完整\(result.snapshot?.memberCount ?? 0)只")；指数 \(MarketText.timestamp(indexQuotes[result.index]?.updatedAt))；榜单 \(MarketText.timestamp(snapshots[result.index]?.quote.updatedAt))"
            }.joined(separator: "；")
            try? ActivityLogFile.append("行情刷新：\(details)", to: cacheURL.deletingLastPathComponent())
        }
        lastLogKey = key
    }
    var searchableQuotes: [MarketQuote] { Array(quoteIndex.values) }
    private var quoteIndex: [SecurityID: MarketQuote] {
        var all = MarketQuoteIndex.latest(from: snapshots.values)
        for (security, quote) in favoriteCache {
            if all[security] == nil || (quote.updatedAt ?? .distantPast) >= (all[security]?.updatedAt ?? .distantPast) {
                all[security] = quote
            }
        }
        return all
    }
    var favoriteQuotes: [MarketQuote] {
        let all = quoteIndex
        return favorites.map { all[$0] ?? placeholder(for: $0) }
    }
    func quote(for security: SecurityID) -> MarketQuote? {
        quoteIndex[security] ?? (isFavorite(security) ? placeholder(for: security) : nil)
    }
    private func placeholder(for security: SecurityID) -> MarketQuote {
        MarketQuote(security: security, name: security.code, price: nil, percent: nil, change: nil, netInflow: nil, updatedAt: nil)
    }
    func isFavorite(_ security: SecurityID) -> Bool { favorites.contains(security) }
    func addFavorite(_ quote: MarketQuote) throws {
        guard !isFavorite(quote.security) else { return }
        guard SecurityID.parse(quote.id) != nil else { throw FeedError(message: "股票代码无效") }
        var cache = favoriteCache
        let known = quoteIndex[quote.security]
        cache[quote.security] = (known?.updatedAt ?? .distantPast) > (quote.updatedAt ?? .distantPast) ? known : quote
        let updated = favorites + [quote.security]
        // 先保存名称和行情，再保存自选列表；列表写入失败时不报告添加成功。
        try saveFavoriteCache(cache)
        try JSONEncoder().encode(updated).write(to: preferencesURL, options: .atomic)
        favoriteCache = cache
        favorites = updated
        favoriteError = nil
        onChange?()
    }
    func toggleFavorite(_ security: SecurityID) {
        do {
            if isFavorite(security) {
                let updated = favorites.filter { $0 != security }
                try JSONEncoder().encode(updated).write(to: preferencesURL, options: .atomic)
                favorites = updated
                favoriteCache.removeValue(forKey: security)
                try? saveFavoriteCache(favoriteCache)
                favoriteError = nil
                onChange?()
            } else if let quote = quote(for: security) {
                try addFavorite(quote)
            }
        } catch { favoriteError = "自选股保存失败：\(error.localizedDescription)" }
    }
    private func saveFavoriteCache(_ cache: [SecurityID: MarketQuote]) throws {
        try JSONEncoder().encode(cache.values.sorted { $0.id < $1.id }).write(to: favoriteCacheURL, options: .atomic)
    }
    func updateFavoriteQuotes(_ quotes: [MarketQuote]) {
        var cache = favoriteCache
        for quote in quotes where isFavorite(quote.security) {
            if cache[quote.security] == nil || (quote.updatedAt ?? .distantPast) >= (cache[quote.security]?.updatedAt ?? .distantPast) {
                cache[quote.security] = quote
            }
        }
        favoriteCache = cache
        try? saveFavoriteCache(cache)
    }
    /// 仅重载个人自选设置；不会让导入文件覆盖当前榜单。
    func reloadFavorites() {
        if let data = try? Data(contentsOf: preferencesURL), let values = try? JSONDecoder().decode([SecurityID].self, from: data) {
            favorites = values
        }
        favoriteCache.removeAll()
        if let data = try? Data(contentsOf: favoriteCacheURL), let quotes = try? JSONDecoder().decode([MarketQuote].self, from: data) {
            for quote in quotes where favorites.contains(quote.security) { favoriteCache[quote.security] = quote }
        }
        favoriteError = nil
        onChange?()
    }
    /// 同时核对指数和成分行情，避免只有指数更新时误报恢复；单股停牌不算整个范围延迟。
    var monitoringTime: Date? {
        guard snapshots.count == MarketIndex.allCases.count, indexQuotes.count == MarketIndex.allCases.count else { return nil }
        let times = MarketIndex.allCases.flatMap { index -> [Date] in
            [indexQuotes[index]?.updatedAt, snapshots[index]?.quote.updatedAt,
             snapshots[index]?.stocks.compactMap(\.updatedAt).max()].compactMap { $0 }
        }
        guard times.count == MarketIndex.allCases.count * 3 else { return nil }
        return times.min()
    }
    func refreshFavoriteQuotes(_ securities: [SecurityID]) async {
        updateFavoriteQuotes(await MarketAPI.fetchFavoriteQuotes(securities))
        onChange?()
    }
}

/// 图表布局期间只读取已转换的日期，不重复解析60条日线。
struct StockChartPoint: Identifiable {
    let day: String
    let date: Date
    let close: Double
    var id: String { day }
    init?(_ value: DailyClose) {
        guard let date = MarketParsing.date(value.day) else { return nil }
        day = value.day
        self.date = date
        close = value.close
    }
}

struct StockDetailState {
    let original: MarketQuote
    var detail: StockDetail?
    var history: [StockChartPoint] = []
    var detailLoading = true
    var historyLoading = true
    var detailError: String?
    var chartError: String?
    var isCached = true
    var loading: Bool { detailLoading || historyLoading }
    var quote: MarketQuote {
        guard let quote = detail?.quote,
              (quote.updatedAt ?? .distantPast) >= (original.updatedAt ?? .distantPast) else { return original }
        return quote
    }
}

@MainActor
final class StockDetailModel: ObservableObject {
    typealias DetailLoader = (SecurityID) async throws -> StockDetail
    typealias HistoryLoader = (SecurityID) async throws -> [DailyClose]
    @Published private(set) var state: StockDetailState?
    private(set) var isActive = false
    var onQuote: ((MarketQuote) -> Void)?
    private let loadDetail: DetailLoader
    private let loadHistory: HistoryLoader?
    private var detailTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var requestID = UUID()
    private struct Cached {
        var detail: StockDetail?
        var history: [StockChartPoint] = []
    }
    private var cache: [SecurityID: Cached] = [:]
    private var cacheOrder: [SecurityID] = []

    init(loadDetail: @escaping DetailLoader = MarketAPI.fetchDetail,
         loadHistory: HistoryLoader? = nil) {
        self.loadDetail = loadDetail
        self.loadHistory = loadHistory
    }

    func showStock(_ quote: MarketQuote) {
        cancelRequests()
        let token = UUID()
        requestID = token
        isActive = true
        let security = quote.security
        cacheOrder.removeAll { $0 == security }
        cacheOrder.append(security)
        while cacheOrder.count > 24 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        state = StockDetailState(original: quote, detail: cache[security]?.detail, history: cache[security]?.history ?? [])
        let fetchDetail = loadDetail, fetchHistory = loadHistory
        detailTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let detail = try await fetchDetail(security)
                guard !Task.isCancelled, let self = self, self.accepts(token), var state = self.state else { return }
                state.detail = detail
                state.detailLoading = false
                state.isCached = false
                self.cache[security, default: Cached()].detail = detail
                self.state = state
                self.onQuote?(detail.quote)
            } catch {
                guard !Task.isCancelled, let self = self, self.accepts(token), var state = self.state else { return }
                state.detailLoading = false
                state.detailError = error.localizedDescription
                self.state = state
            }
        }
        guard let fetchHistory = fetchHistory else { state?.historyLoading = false; return }
        historyTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let history = try await fetchHistory(security)
                guard !Task.isCancelled, let self = self, self.accepts(token), var state = self.state else { return }
                let points = history.compactMap(StockChartPoint.init)
                state.history = points
                state.historyLoading = false
                self.cache[security, default: Cached()].history = points
                self.state = state
            } catch {
                guard !Task.isCancelled, let self = self, self.accepts(token), var state = self.state else { return }
                state.historyLoading = false
                state.chartError = error.localizedDescription
                self.state = state
            }
        }
    }

    private func accepts(_ token: UUID) -> Bool { isActive && requestID == token }

    func cancelRequests() {
        guard isActive else { return }
        isActive = false
        requestID = UUID()
        detailTask?.cancel()
        historyTask?.cancel()
        detailTask = nil
        historyTask = nil
        // 关闭只取消请求，不发布界面状态，避免关闭期间再次触发布局。
    }
}

enum MarketStyle {
    static let rising = Color(red: 0.82, green: 0.18, blue: 0.20)
    static let falling = Color(red: 0.05, green: 0.49, blue: 0.35)
    static func color(_ value: Double?) -> Color {
        guard let value = value, value != 0 else { return .secondary }
        return value > 0 ? rising : falling
    }
}

struct FavoriteSearchView: View {
    @ObservedObject var model: MarketModel
    let close: () -> Void
    @State private var query = ""
    @State private var results: [StockSearchResult] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var saveError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("添加股票或场内基金", systemImage: "star").font(.system(size: 20, weight: .semibold))
                Spacer()
                Text("已自选 \(model.favorites.count) 只").foregroundColor(.secondary).font(.system(size: 12))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("股票或场内基金名称 / 代码，如 茅台 / 510300", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("股票或场内基金名称或代码")
                if !query.isEmpty {
                    Button(action: { query = ""; searchFocused = true }) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("清空搜索")
                }
                if searching { ProgressView().controlSize(.small) }
            }.padding(11).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            if let error = saveError ?? searchError {
                Label(error, systemImage: "exclamationmark.circle").foregroundColor(.orange)
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { result in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.name).font(.system(size: 14, weight: .medium))
                                Text("\(result.marketName)  \(result.security.code)")
                                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: { add(result) }) {
                                Label(model.isFavorite(result.security) ? "已添加" : "添加", systemImage: model.isFavorite(result.security) ? "checkmark" : "plus")
                                    .frame(width: 65)
                            }.disabled(model.isFavorite(result.security))
                                .accessibilityLabel("\(model.isFavorite(result.security) ? "已添加" : "添加")\(result.name)")
                        }.padding(.vertical, 11).padding(.horizontal, 3)
                        Divider()
                    }
                    if results.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: query.isEmpty ? "magnifyingglass" : "doc.text.magnifyingglass").font(.system(size: 28))
                            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入名称或代码，搜索沪深京 A 股、ETF 和 LOF" : (searching ? "正在搜索…" : (searchError == nil ? "未找到股票或场内基金，请换个名称或代码" : "暂时无法搜索，请检查网络后重试")))
                                .font(.system(size: 13))
                            if searchError != nil { Button("重试") { Task { await search(query) } } }
                        }.foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.top, 65)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("添加后可在「自选股」中点击查看详情").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("完成", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 510, height: 400)
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id: query) { await search(query) }
            .onAppear { searchFocused = true }
    }

    private func search(_ input: String) async {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil
        saveError = nil
        results = StockSearch.local(term, quotes: model.searchableQuotes)
        searching = !term.isEmpty
        guard !term.isEmpty else { return }
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let online = try await MarketAPI.searchStocks(term, includeFunds: true)
            try Task.checkCancellation()
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            var seen = Set<SecurityID>()
            results = (online + results).filter { seen.insert($0.security).inserted }
            searching = false
        } catch {
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            searchError = results.isEmpty ? "搜索失败，请检查网络后重试" : "在线搜索失败，以下为本机已缓存的匹配股票"
            searching = false
        }
    }

    private func add(_ result: StockSearchResult) {
        do {
            try model.addFavorite(result.placeholderQuote)
            saveError = nil
            Task { await model.refreshFavoriteQuotes([result.security]) }
        } catch { saveError = "添加失败，未能保存自选股：\(error.localizedDescription)" }
    }
}

@MainActor
final class FavoriteSearchWindowController {
    let model: MarketModel
    var window: NSWindow?
    init(model: MarketModel) { self.model = model }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "申购提醒 · 添加自选股"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FavoriteSearchView(model: model, close: { [weak self] in self?.window?.close() }))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MarketView: View {
    @ObservedObject var model: MarketModel
    let openTHS: () -> Void
    let showStock: (MarketQuote) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日行情").font(.system(size: 25, weight: .semibold))
                    Text("三个指数 · 四类榜单 · 点击股票查看详情").foregroundColor(.secondary)
                }
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button(action: { model.refresh() }) { Label("刷新行情", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshing)
                Button("打开同花顺", action: openTHS)
            }
            HStack(spacing: 12) {
                ForEach(MarketIndex.allCases) { index in indexCard(index) }
            }
            if !model.favoriteQuotes.isEmpty {
                HStack(spacing: 9) {
                    Label("自选", systemImage: "star.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
                    ForEach(model.favoriteQuotes) { quote in
                        Button(action: { showStock(quote) }) {
                            HStack(spacing: 5) {
                                Text(quote.name).lineLimit(1)
                                Text(MarketText.number(quote.percent, signed: true, suffix: "%")).foregroundColor(MarketStyle.color(quote.percent)).monospacedDigit()
                            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        }.buttonStyle(.plain).help("查看\(quote.name)详情")
                    }
                    Spacer()
                }
            }
            if let snapshot = model.snapshots[model.selected] {
                HStack(spacing: 8) {
                    Text(snapshot.index.scope).fontWeight(.medium)
                    Text("\(snapshot.memberCount) 只").foregroundColor(.secondary)
                    Spacer()
                    Text("榜单行情 \(MarketText.timestamp(snapshot.quote.updatedAt)) · 北京时间").foregroundColor(.secondary)
                }.font(.system(size: 12))
                if let error = model.errors[model.selected] {
                    warning("榜单刷新未完成，以下保留上次完整榜单。\(error)；\(model.retryHint)。")
                } else if snapshot.tradingDay != ChinaClock.day() {
                    warning("当前展示 \(snapshot.tradingDay ?? "未知日期") 的最近交易行情，今日暂无新行情。")
                } else if MarketRefreshSchedule.isStale(snapshot.quote.updatedAt, at: Date()) {
                    warning("数据源返回的榜单行情时间落后，请以标注时间为准；程序将继续自动刷新。")
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(RankingKind.allCases) { kind in rankingCard(kind, snapshot: snapshot) }
                }.frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 38)).foregroundColor(.secondary)
                    Text(model.refreshing ? "正在获取成分股与行情…" : "暂时无法获取行情").font(.title3)
                    if let error = model.errors[model.selected] { Text(error).foregroundColor(.secondary) }
                    if !model.refreshing { Button("重新查询") { model.refresh() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("资金口径：当日主力净流入额，正值为净流入，负值为净流出。榜单仅列对应方向，少于十只时按实际数量显示。")
                    Text("行情：东方财富 · 成分范围：新浪财经指数列表 · 盘中每5分钟更新，失败1分钟后重试 · 指数与榜单分别标注时间 · 数据可能延迟，交易请以同花顺为准。")
            }.font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(minWidth: 960, minHeight: 610)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
    func indexCard(_ index: MarketIndex) -> some View {
        let quote = model.indexQuotes[index]
        let chosen = model.selected == index
        return Button(action: { model.selected = index }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(index.name).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundColor(chosen ? .accentColor : .secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(MarketText.number(quote?.price)).font(.system(size: 27, weight: .medium, design: .rounded))
                    Spacer(minLength: 0)
                    Text(MarketText.number(quote?.percent, signed: true, suffix: "%")).font(.system(size: 16, weight: .semibold))
                }.foregroundColor(MarketStyle.color(quote?.percent)).monospacedDigit()
                Text(quote?.updatedAt.map { MarketText.timestamp($0) } ?? "等待行情")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if model.indexErrors[index] != nil {
                    Text("指数刷新失败 · 保留缓存").font(.system(size: 11)).foregroundColor(.orange)
                } else if MarketRefreshSchedule.isStale(quote?.updatedAt, at: Date()) {
                    Text("指数行情时间落后").font(.system(size: 11)).foregroundColor(.orange)
                }
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosen ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func rankingCard(_ kind: RankingKind, snapshot: MarketSnapshot) -> some View {
        let rows = snapshot.ranked(kind)
        let available = snapshot.availableCount(kind)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle().fill(MarketStyle.color(kind.positive ? 1 : -1)).frame(width: 6, height: 6)
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Text(kind.isFlow ? "主力净额" : "涨跌幅").font(.system(size: 11)).foregroundColor(.secondary)
                Button("复制") { copyRanking(snapshot: snapshot, kind: kind) }.font(.system(size: 11))
            }.padding(13)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, quote in
                        Button(action: { showStock(quote) }) {
                            HStack(spacing: 8) {
                                Text("\(offset + 1)").font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary).frame(width: 15)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(quote.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(quote.security.code).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 2)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(kind.isFlow ? MarketText.money(quote.netInflow, signed: true) : MarketText.number(quote.percent, signed: true, suffix: "%"))
                                        .font(.system(size: 12, weight: .semibold)).foregroundColor(MarketStyle.color(kind.value(quote)))
                                    Text(kind.isFlow ? MarketText.number(quote.percent, signed: true, suffix: "%") : MarketText.number(quote.price))
                                        .font(.system(size: 10)).foregroundColor(.secondary)
                                }.monospacedDigit()
                            }.padding(.horizontal, 11).padding(.vertical, 8).frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help("查看\(quote.name)（\(quote.security.code)）详情")
                        if offset < rows.count - 1 { Divider().padding(.leading, 34) }
                    }
                    if rows.isEmpty {
                        Text("该交易日暂无符合方向的数据").font(.system(size: 12)).foregroundColor(.secondary)
                            .padding(.vertical, 35).padding(.horizontal, 10)
                    }
                }
            }
            Divider()
            Text(available == snapshot.memberCount ? "覆盖 \(available) / \(snapshot.memberCount) 只" : "可用 \(available) / \(snapshot.memberCount) 只 · 缺失或停牌已排除")
                .font(.system(size: 10)).foregroundColor(.secondary).padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.16)))
    }
    func copyRanking(snapshot: MarketSnapshot, kind: RankingKind) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarketText.rankingCopy(snapshot: snapshot, kind: kind), forType: .string)
    }
}

struct StockDetailView: View {
    @ObservedObject var model: StockDetailModel
    @ObservedObject var charts: SecurityChartModel
    var showFund: (String?) -> Void = { _ in }
    @ObservedObject var favorites: MarketModel
    let openTHS: () -> Void
    let close: () -> Void
    var body: some View {
        ScrollView {
            if let state = model.state { content(state) }
        }.frame(minWidth: 660, minHeight: 660)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func content(_ state: StockDetailState) -> some View {
        let quote = state.quote
        return VStack(alignment: .leading, spacing: 16) {
            Group {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(quote.name).font(.system(size: 24, weight: .semibold))
                    Text(quote.security.label).foregroundColor(.secondary).font(.system(size: 12, design: .monospaced))
                }
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Button("刷新") { model.showStock(quote); charts.refresh() }.disabled(state.loading)
                Button(action: { toggleFavorite(quote) }) {
                    Label(favorites.isFavorite(quote.security) ? "已自选" : "加自选", systemImage: favorites.isFavorite(quote.security) ? "star.fill" : "star")
                }.foregroundColor(.orange)
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(quote.security.isExchangeFund ? quote.price.map { String(format: "%.3f", $0) } ?? "—" : MarketText.number(quote.price)).font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(MarketText.number(quote.change, signed: true)).font(.title3)
                Text(MarketText.number(quote.percent, signed: true, suffix: "%")).font(.title3)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("当日主力净流入").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(MarketText.money(quote.netInflow, signed: true)).foregroundColor(MarketStyle.color(quote.netInflow))
                }
            }.foregroundColor(MarketStyle.color(quote.percent)).monospacedDigit()
            Text(quote.updatedAt == nil ? "行情时间：等待获取" : "行情时间：\(MarketText.timestamp(quote.updatedAt))（北京时间）\(state.isCached ? " · 缓存行情" : "")")
                .font(.system(size: 11)).foregroundColor(.secondary)
            if let error = favorites.favoriteError { Text(error).foregroundColor(.orange).font(.system(size: 12)) }
            if let error = state.detailError { Label("详情刷新失败：\(error)", systemImage: "exclamationmark.circle").foregroundColor(.orange).font(.system(size: 12)) }
            if let updatedAt = quote.updatedAt, ChinaClock.day(updatedAt) != ChinaClock.day() {
                Text("当前为最近交易日行情，今日暂无新行情。").foregroundColor(.orange).font(.system(size: 12))
            }
            Divider()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    metric("今开", MarketText.number(state.detail?.open))
                    metric("昨收", MarketText.number(state.detail?.previousClose))
                    metric("最高", MarketText.number(state.detail?.high))
                    metric("最低", MarketText.number(state.detail?.low))
                }
                GridRow {
                    metric("成交量（手）", MarketText.quantity(state.detail?.volume))
                    metric("成交额（元）", MarketText.money(state.detail?.amount))
                    metric("换手率", MarketText.number(state.detail?.turnover, suffix: "%"))
                    metric("量比", MarketText.number(state.detail?.volumeRatio))
                }
                GridRow {
                    metric("总市值（元）", MarketText.money(state.detail?.marketCap))
                    metric("流通市值（元）", MarketText.money(state.detail?.floatCap))
                    metric("市盈率（动态）", MarketText.number(state.detail?.pe))
                    metric("市净率", MarketText.number(state.detail?.pb))
                }
            }
            SecurityChartPanel(model: charts)
            HStack {
                Button("复制代码") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quote.security.code, forType: .string)
                }
                Button("打开同花顺", action: openTHS)
                Button(quote.security.isExchangeFund ? "查看基金净值" : "基金走势与净值") { showFund(quote.security.isExchangeFund ? quote.security.code : nil) }
                Spacer()
                Link("东方财富详情 ↗", destination: URL(string: "https://quote.eastmoney.com/\(quote.security.marketName == "沪" ? "sh" : (quote.security.marketName == "京" ? "bj" : "sz"))\(quote.security.code).html")!)
            }
            Text("数据：东方财富 · 资金为主力净额 · — 表示暂无数据 · 实际交易信息以券商页面为准。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func toggleFavorite(_ quote: MarketQuote) {
        if favorites.isFavorite(quote.security) { favorites.toggleFavorite(quote.security) }
        else {
            do { try favorites.addFavorite(quote) }
            catch { favorites.favoriteError = "自选股保存失败：\(error.localizedDescription)" }
        }
    }
    func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class MarketWindowController {
    let model: MarketModel
    var window: NSWindow?
    var openTHS: () -> Void = {}
    lazy var stockDetail = StockDetailWindowController(favorites: model, openTHS: { [weak self] in self?.openTHS() })
    init(directory: URL) { model = MarketModel(directory: directory) }
    var visible: Bool { window?.isVisible == true }
    func show(index: MarketIndex? = nil) {
        if let index = index { model.selected = index }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "申购提醒 · 行情与排行榜"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1000, height: 680)
            window.contentView = NSHostingView(rootView: MarketView(model: model, openTHS: { [weak self] in self?.openTHS() }, showStock: { [weak self] in self?.showStock($0) }))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let interval = model.automaticRefreshInterval() { model.refreshIfDue(interval: interval) }
    }
    func showStock(_ quote: MarketQuote) { stockDetail.show(quote) }
}

@MainActor
final class StockDetailWindowController: NSObject, NSWindowDelegate {
    let model: StockDetailModel
    let favorites: MarketModel
    let charts: SecurityChartModel
    lazy var funds = FundDetailWindowController()
    private let openTHS: () -> Void
    private(set) var window: NSWindow?

    init(favorites: MarketModel, model: StockDetailModel? = nil, charts: SecurityChartModel? = nil, openTHS: @escaping () -> Void) {
        self.favorites = favorites
        self.model = model ?? StockDetailModel()
        self.charts = charts ?? SecurityChartModel()
        self.openTHS = openTHS
        super.init()
        self.charts.canAutoRefresh = { [weak self] in self?.window?.isVisible == true && self?.window?.isMiniaturized == false }
        self.charts.onAutoRefresh = { [weak self] in
            guard let self = self, let quote = self.model.state?.quote else { return }
            self.model.showStock(quote)
        }
        self.model.onQuote = { [weak favorites] quote in
            guard let favorites = favorites, favorites.isFavorite(quote.security) else { return }
            favorites.updateFavoriteQuotes([quote])
            favorites.onChange?()
        }
    }

    func show(_ quote: MarketQuote) {
        model.showStock(quote)
        charts.show(quote.security)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 700)
            window.delegate = self
            window.contentView = NSHostingView(rootView: StockDetailView(model: model, charts: charts, showFund: { [weak self] in self?.funds.show(code: $0) }, favorites: favorites,
                openTHS: openTHS, close: { [weak self] in self?.window?.close() }))
            window.center()
            self.window = window
        }
        window?.title = "申购提醒 · \(quote.name)（\(quote.security.code)）"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { model.cancelRequests(); charts.cancel() }
}

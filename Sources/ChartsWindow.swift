import AppKit
import SwiftUI
import Charts

@MainActor
final class SecurityChartModel: ObservableObject {
    typealias Loader = (SecurityID, PriceChartPeriod) async throws -> PriceChartData
    @Published private(set) var data: PriceChartData?
    @Published private(set) var period: PriceChartPeriod = .intraday
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private(set) var security: SecurityID?
    private(set) var active = false
    var canAutoRefresh: () -> Bool = { true }
    var onAutoRefresh: (() -> Void)?
    private let loader: Loader
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var token = UUID()
    private struct Key: Hashable { let security: SecurityID; let period: String }
    private var cache: [Key: PriceChartData] = [:]
    private var order: [Key] = []
    init(loader: @escaping Loader = DetailChartAPI.chart) { self.loader = loader }
    func show(_ security: SecurityID) {
        cancel(); active = true; self.security = security; refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self = self, self.active else { return }
                if self.canAutoRefresh(), Self.isTrading(at: Date()), !self.loading { self.refresh(); self.onAutoRefresh?() }
            }
        }
    }
    static func isTrading(at date: Date) -> Bool {
        guard TradingCalendar.isTradingDay(date) else { return false }
        let p = ChinaClock.calendar.dateComponents([.hour, .minute], from: date)
        let m = (p.hour ?? 0) * 60 + (p.minute ?? 0)
        return (570...690).contains(m) || (780...900).contains(m)
    }
    func select(_ period: PriceChartPeriod) {
        guard self.period != period else { return }
        self.period = period; refresh()
    }
    func refresh() {
        guard active, let security = security else { return }
        task?.cancel(); token = UUID(); let token = token, period = period
        let key = Key(security: security, period: period.rawValue)
        data = cache[key]; error = nil; loading = true
        let loader = loader
        task = Task { [weak self] in
            do {
                let value = try await loader(security, period)
                guard !Task.isCancelled, let self = self, self.active, self.token == token else { return }
                guard value.period == period, value.security == security else { throw FeedError(message: "图表周期不匹配") }
                self.cache[key] = value; self.order.removeAll { $0 == key }; self.order.append(key)
                while self.order.count > 96 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                self.data = value; self.loading = false
            } catch {
                guard !Task.isCancelled, let self = self, self.active, self.token == token else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }
    func cancel() {
        active = false; token = UUID(); task?.cancel(); timer?.cancel(); task = nil; timer = nil
        // 关闭时不发布状态，避免触发窗口重布局。
    }
}

struct SecurityChartPanel: View {
    @ObservedObject var model: SecurityChartModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("走势图", selection: Binding(get: { model.period }, set: { model.select($0) })) {
                    ForEach(PriceChartPeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 280)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button(action: { model.refresh() }) { Image(systemName: "arrow.clockwise") }.help("刷新当前图表").disabled(model.loading)
            }
            if let data = model.data {
                PriceCanvasChart(data: data).id("\(model.security?.id ?? "")-\(model.period.rawValue)")
                HStack {
                    Text("\(data.source) · \(data.adjustment)")
                    Spacer()
                    Text(data.period == .intraday ? "截至 \(MarketText.timestamp(data.lastTime))" : "最新周期 \(data.bars.last?.label ?? "—")")
                }.font(.system(size: 10)).foregroundColor(.secondary)
                if data.period == .intraday, let time = data.lastTime, MarketRefreshSchedule.isStale(time, at: Date()) {
                    Text("当前为最近可用分时数据，请留意日期与时间。").font(.system(size: 11)).foregroundColor(.orange)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.title)
                    Text(model.loading ? "正在加载\(model.period.title)…" : "暂无图表数据")
                }.foregroundColor(.secondary).frame(maxWidth: .infinity).frame(height: 260)
            }
            if let error = model.error {
                Text("图表刷新失败\(model.data == nil ? "" : "，保留上次数据")：\(error)").font(.system(size: 11)).foregroundColor(.orange)
            }
            Text("红涨绿跌 · 鼠标悬停查看数值 · 下方为成交量（手） · 盘中可见窗口每60秒更新，午休及休市暂停；最新K线在周期结束前仍会变化。")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 轻量 Canvas 一次绘制价格、蜡烛与成交量，避免大量图表子视图拖慢窗口关闭。
struct PriceCanvasChart: View {
    let data: PriceChartData
    @State private var hovered: Int?
    private var selected: PriceBar? {
        guard let index = hovered, data.bars.indices.contains(index) else { return data.bars.last }; return data.bars[index]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bar = selected {
                HStack(spacing: 12) {
                    Text(data.period == .intraday ? MarketText.timestamp(bar.date) : bar.label)
                    if data.period == .intraday { Text("价格 \(value(bar.close))") }
                    else {
                        Text("开 \(value(bar.open))"); Text("收 \(value(bar.close))")
                        Text("高 \(value(bar.high))"); Text("低 \(value(bar.low))")
                    }
                    Text("量 \(MarketText.quantity(bar.volume))")
                }.font(.system(size: 10, design: .monospaced)).lineLimit(1).foregroundColor(.secondary).frame(height: 20)
            }
            GeometryReader { geometry in
                Canvas { context, size in draw(context: &context, size: size) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let width = max(1, geometry.size.width - 66)
                            let position = min(1, max(0, (point.x - 56) / width))
                            if data.period == .intraday {
                                hovered = data.bars.indices.min(by: { abs(xFraction(data.bars[$0], index: $0) - position) < abs(xFraction(data.bars[$1], index: $1) - position) })
                            } else { hovered = min(data.bars.count - 1, max(0, Int(position * Double(data.bars.count)))) }
                        case .ended: hovered = nil
                        }
                    }
            }.frame(height: 245)
            HStack {
                Text(data.period == .intraday ? "09:30" : (data.bars.first?.label ?? ""))
                Spacer()
                if data.period == .intraday { Text("11:30 / 13:00"); Spacer() }
                Text(data.period == .intraday ? "15:00" : (data.bars.last?.label ?? ""))
            }.font(.system(size: 10)).foregroundColor(.secondary).padding(.leading, 56).padding(.trailing, 10)
        }
    }
    private func value(_ x: Double) -> String { String(format: "%.3f", x) }
    private func xFraction(_ bar: PriceBar, index: Int) -> Double {
        guard data.period == .intraday else { return (Double(index) + 0.5) / Double(max(1, data.bars.count)) }
        let parts = ChinaClock.calendar.dateComponents([.hour, .minute], from: bar.date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return Double(minute >= 780 ? minute - 660 : minute - 570) / 240
    }
    private func draw(context: inout GraphicsContext, size: CGSize) {
        guard !data.bars.isEmpty else { return }
        let left: CGFloat = 56, right = max(left + 1, size.width - 10), top: CGFloat = 8, bottom: CGFloat = 177
        let width = right - left
        let reference = data.previousClose.flatMap { $0 > 0 ? $0 : nil }
        let low = min(data.bars.map(\.low).min()!, reference ?? .greatestFiniteMagnitude)
        let high = max(data.bars.map(\.high).max()!, reference ?? 0)
        let margin = max((high - low) * 0.08, high * 0.001)
        let ymin = low - margin, ymax = high + margin
        func x(_ index: Int) -> CGFloat { left + CGFloat(xFraction(data.bars[index], index: index)) * width }
        func y(_ price: Double) -> CGFloat { bottom - CGFloat((price - ymin) / (ymax - ymin)) * (bottom - top) }
        for i in 0...4 {
            let price = ymin + (ymax - ymin) * Double(i) / 4
            let level = y(price)
            var line = Path(); line.move(to: CGPoint(x: left, y: level)); line.addLine(to: CGPoint(x: right, y: level))
            context.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
            context.draw(Text(value(price)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: left - 5, y: level), anchor: .trailing)
        }
        if let previous = reference {
            var line = Path(); line.move(to: CGPoint(x: left, y: y(previous))); line.addLine(to: CGPoint(x: right, y: y(previous)))
            context.stroke(line, with: .color(.secondary.opacity(0.65)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3]))
        }
        let maxVolume = max(1, data.bars.map(\.volume).max() ?? 1)
        let barWidth = max(1, min(8, width / CGFloat(data.bars.count) * 0.65))
        var curve = Path()
        for i in data.bars.indices {
            let bar = data.bars[i], xx = x(i)
            let increasing = data.period == .intraday ? bar.close >= (reference ?? data.bars[0].close) : bar.close >= bar.open
            let color = increasing ? MarketStyle.rising : MarketStyle.falling
            let volHeight = CGFloat(bar.volume / maxVolume) * 46
            context.fill(Path(CGRect(x: xx - barWidth / 2, y: 241 - volHeight, width: barWidth, height: max(0.5, volHeight))), with: .color(color.opacity(0.65)))
            if data.period == .intraday {
                let point = CGPoint(x: xx, y: y(bar.close))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            } else {
                var wick = Path(); wick.move(to: CGPoint(x: xx, y: y(bar.high))); wick.addLine(to: CGPoint(x: xx, y: y(bar.low)))
                context.stroke(wick, with: .color(color), lineWidth: 1)
                context.fill(Path(CGRect(x: xx - barWidth / 2, y: min(y(bar.open), y(bar.close)), width: barWidth, height: max(1, abs(y(bar.open) - y(bar.close))))), with: .color(color))
            }
        }
        if data.period == .intraday { context.stroke(curve, with: .color(.accentColor), lineWidth: 1.5) }
        if let i = hovered, data.bars.indices.contains(i) {
            var line = Path(); line.move(to: CGPoint(x: x(i), y: top)); line.addLine(to: CGPoint(x: x(i), y: 241))
            context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
        }
        context.draw(Text("成交量").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: left - 5, y: 214), anchor: .trailing)
    }
}

@MainActor
final class FundDetailModel: ObservableObject {
    typealias Searcher = (String) async throws -> [FundIdentity]
    typealias Loader = (FundIdentity) async throws -> FundHistory
    @Published var query = ""
    @Published private(set) var results: [FundIdentity] = []
    @Published private(set) var searching = false
    @Published private(set) var searchError: String?
    @Published private(set) var selected: FundIdentity?
    @Published private(set) var history: FundHistory?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private(set) var active = false
    private let searcher: Searcher
    private let loader: Loader
    private var searchTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var searchToken = UUID(), historyToken = UUID()
    private var cache: [String: FundHistory] = [:]
    private var cacheOrder: [String] = []
    init(searcher: @escaping Searcher = DetailChartAPI.searchFunds, loader: @escaping Loader = DetailChartAPI.fundHistory) { self.searcher = searcher; self.loader = loader }
    func open(code: String? = nil) {
        active = true; searching = false; loading = false
        if let code = code { query = code; search(code) }
        else {
            if !query.isEmpty { search(query) }
            if let fund = selected { select(fund) }
        }
    }
    func search(_ input: String) {
        guard active else { return }
        searchTask?.cancel(); searchToken = UUID(); let token = searchToken
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        searching = !term.isEmpty; searchError = nil; results = []
        guard !term.isEmpty else { return }
        let searcher = searcher
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                let values = try await searcher(term)
                guard !Task.isCancelled, let self = self, self.active, self.searchToken == token else { return }
                self.results = values; self.searching = false
                if values.count == 1, values[0].code == term { self.select(values[0]) }
            } catch {
                guard !Task.isCancelled, let self = self, self.active, self.searchToken == token else { return }
                self.searchError = "基金搜索失败：\(error.localizedDescription)"; self.searching = false
            }
        }
    }
    func select(_ fund: FundIdentity) {
        guard active else { return }
        historyTask?.cancel(); historyToken = UUID(); let token = historyToken
        selected = fund; history = cache[fund.code]; loading = true; error = nil
        let loader = loader
        historyTask = Task { [weak self] in
            do {
                let value = try await loader(fund)
                guard !Task.isCancelled, let self = self, self.active, self.historyToken == token else { return }
                guard value.fund.code == fund.code else { throw FeedError(message: "基金净值与代码不匹配") }
                self.history = value; self.cache[fund.code] = value
                self.cacheOrder.removeAll { $0 == fund.code }; self.cacheOrder.append(fund.code)
                while self.cacheOrder.count > 12 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
                self.loading = false
            } catch {
                guard !Task.isCancelled, let self = self, self.active, self.historyToken == token else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }
    func cancel() {
        active = false; searchToken = UUID(); historyToken = UUID(); searchTask?.cancel(); historyTask?.cancel()
        searchTask = nil; historyTask = nil
    }
}

struct FundDetailView: View {
    @ObservedObject var model: FundDetailModel
    let close: () -> Void
    @State private var range = 365
    @State private var visibleRows = 40
    @State private var hovered: FundNAV?
    private var displayed: [FundNAV] {
        guard let values = model.history?.values else { return [] }
        guard range != 0, let end = values.last?.date, let start = ChinaClock.calendar.date(byAdding: .day, value: -range, to: end) else { return sampled(values) }
        return sampled(values.filter { $0.date >= start })
    }
    private func sampled(_ values: [FundNAV]) -> [FundNAV] {
        guard values.count > 700 else { return values }
        let stride = Int(ceil(Double(values.count) / 700))
        return values.enumerated().filter { $0.offset % stride == 0 || $0.offset == values.count - 1 }.map(\.element)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("基金走势与净值", systemImage: "chart.xyaxis.line").font(.title2)
                Spacer()
                if model.searching || model.loading { ProgressView().controlSize(.small) }
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("输入基金名称或代码，如 华夏成长 / 000001", text: $model.query)
                    .textFieldStyle(.roundedBorder).onChange(of: model.query) { model.search($0) }
                Button("搜索") { model.search(model.query) }.disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.searchError { Text(error).foregroundColor(.orange).font(.caption) }
            if !model.results.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.results) { fund in
                            Button { model.select(fund); visibleRows = 40; hovered = nil } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(fund.name).font(.system(size: 12, weight: .medium))
                                    Text("\(fund.code) · \(fund.type)").font(.system(size: 10)).foregroundColor(.secondary)
                                }.padding(8).background(RoundedRectangle(cornerRadius: 7).fill(model.selected == fund ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 58)
            } else if !model.query.isEmpty, !model.searching, model.searchError == nil {
                Text("未找到支持的基金；货币基金收益数据暂不支持。").font(.caption).foregroundColor(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let fund = model.selected {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fund.name).font(.system(size: 21, weight: .semibold))
                                Text("\(fund.code) · \(fund.type)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("刷新净值") { model.select(fund) }.disabled(model.loading)
                        }
                        if let history = model.history, let latest = history.values.last {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(String(format: "%.4f", latest.unit)).font(.system(size: 32, weight: .semibold, design: .rounded))
                                Text(MarketText.number(latest.percent, signed: true, suffix: "%")).foregroundColor(MarketStyle.color(latest.percent))
                                Text("单位净值 · \(latest.day)").font(.caption).foregroundColor(.secondary)
                            }
                            Text("已公布净值每日更新；普通基金暂无可用的盘中估算，不代表实时成交价。ETF / LOF 的实际盘中走势请在「搜索添加股票或场内基金」中查看。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            Picker("历史范围", selection: $range) {
                                Text("近1月").tag(31); Text("近3月").tag(93); Text("近1年").tag(365); Text("全部").tag(0)
                            }.pickerStyle(.segmented).frame(width: 320).onChange(of: range) { _ in hovered = nil }
                            navChart
                            Text(hovered.map { "\($0.day)  单位净值 \(String(format: "%.4f", $0.unit))  累计净值 \($0.accumulated.map { String(format: "%.4f", $0) } ?? "—")" } ?? "鼠标悬停查看净值 · 单位净值走势不等同于含分红再投资的收益率")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(height: 18)
                            Group {
                            Divider()
                            Text("历史净值详情（\(history.values.count)条，最新在前）").font(.system(size: 13, weight: .semibold))
                            HStack { cell("日期"); cell("单位净值"); cell("累计净值"); cell("日增长率") }.foregroundColor(.secondary)
                            }
                            LazyVStack(spacing: 0) {
                                ForEach(Array(history.values.reversed().prefix(visibleRows))) { item in
                                    HStack {
                                        cell(item.day); cell(String(format: "%.4f", item.unit))
                                        cell(item.accumulated.map { String(format: "%.4f", $0) } ?? "—")
                                        cell(MarketText.number(item.percent, signed: true, suffix: "%")).foregroundColor(MarketStyle.color(item.percent))
                                    }.padding(.vertical, 7)
                                    Divider()
                                }
                            }
                            if visibleRows < history.values.count { Button("显示更早净值") { visibleRows += 40 } }
                            Link("天天基金详情 ↗", destination: URL(string: "https://fund.eastmoney.com/\(fund.code).html")!)
                        } else {
                            Text(model.loading ? "正在加载历史净值…" : "暂无净值数据").foregroundColor(.secondary).frame(maxWidth: .infinity).frame(height: 180)
                        }
                        if let error = model.error { Text("净值刷新失败\(model.history == nil ? "" : "，保留缓存")：\(error)").font(.caption).foregroundColor(.orange) }
                    } else {
                        Text("按名称或代码搜索基金，点击结果查看历史走势和净值详情。").foregroundColor(.secondary).frame(maxWidth: .infinity).frame(height: 180)
                    }
                    Text("数据：天天基金（东方财富） · 所有日期按北京时间 · 基金净值与场内交易价格分别展示。").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }.padding(22).frame(minWidth: 660, minHeight: 650).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.timeZone, ChinaClock.calendar.timeZone)
            .onChange(of: model.selected?.id) { _ in visibleRows = 40; hovered = nil }
    }
    private func cell(_ text: String) -> some View { Text(text).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
    private var navChart: some View {
        Chart(displayed) { item in
            LineMark(x: .value("日期", item.date), y: .value("单位净值", item.unit)).foregroundStyle(Color.accentColor)
        }.chartYScale(domain: .automatic(includesZero: false))
            .chartXScale(range: .plotDimension(padding: 16))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(axisDate(date)).font(.system(size: 10, design: .monospaced)).fixedSize()
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let x = point.x - geometry[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: x) { hovered = displayed.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
                        case .ended: hovered = nil
                        }
                    }
                }
            }.frame(height: 210)
    }
    private func axisDate(_ date: Date) -> String {
        let parts = ChinaClock.calendar.dateComponents([.year, .month, .day], from: date)
        if range > 0 && range <= 93 { return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0) }
        return String(format: "%02d-%02d", (parts.year ?? 0) % 100, parts.month ?? 0)
    }
}

@MainActor
final class FundDetailWindowController: NSObject, NSWindowDelegate {
    let model: FundDetailModel
    private(set) var window: NSWindow?
    init(model: FundDetailModel? = nil) { self.model = model ?? FundDetailModel(); super.init() }
    func show(code: String? = nil) {
        model.open(code: code)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "申购提醒 · 基金走势与净值"; window.minSize = NSSize(width: 710, height: 720); window.delegate = self
            window.contentView = NSHostingView(rootView: FundDetailView(model: model, close: { [weak self] in self?.window?.close() }))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}

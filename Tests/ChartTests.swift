import AppKit
import SwiftUI
import Combine

@MainActor private final class PendingCharts {
    var requests: [(SecurityID, PriceChartPeriod, CheckedContinuation<PriceChartData, Error>)] = []
    func load(_ security: SecurityID, _ period: PriceChartPeriod) async throws -> PriceChartData {
        try await withCheckedThrowingContinuation { requests.append((security, period, $0)) }
    }
}
@MainActor private final class PendingFunds {
    var requests: [(FundIdentity, CheckedContinuation<FundHistory, Error>)] = []
    func load(_ fund: FundIdentity) async throws -> FundHistory {
        try await withCheckedThrowingContinuation { requests.append((fund, $0)) }
    }
}

private final class ChartURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct ChartTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task {
            do {
                if CommandLine.arguments.contains("--live") { try await live() }
                else { try await run() }
                exit(0)
            } catch { fputs("图表检查失败：\(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("检查失败（第\(checks + 1)项）：\(message)\n", stderr); exit(1) }; checks += 1
        }
        func rejects(_ message: String, _ block: () throws -> Void) {
            do { try block() } catch { checks += 1; return }; fatalError(message)
        }
        func json(_ source: String) -> Data { Data(source.utf8) }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() { guard Date() < deadline else { throw FeedError(message: "异步请求未按期完成") }; try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let a = SecurityID(market: 1, code: "601899"), b = SecurityID(market: 0, code: "000001")
        let kline = json(#"{"code":0,"data":{"sh601899":{"qfqday":[["2026-10-21","10","11","12","9","100"],["2026-10-20","9","10","11","8","50",{"dividend":"1"}],["2026-10-20","9","10","11","8","50"],["2026-02-30","9","10","11","8","50"],["2026-10-22","12","10","9","11","-5"]]}}}"#)
        let daily = try ChartParsing.tencent(kline, security: a, period: .day)
        check(daily.bars.count == 2 && daily.bars[0].label == "2026-10-20", "K线排序去重，剔除无效日期和OHLC，允许分红附加列")
        check(daily.bars[1].open == 10 && daily.bars[1].high == 12 && daily.bars[1].low == 9 && daily.bars[1].volume == 100, "OHLC及成交量不得误用收盘价")
        check(daily.adjustment == "前复权" && daily.security == a, "标明复权和证券")
        rejects("其他证券不得误用") { _ = try ChartParsing.tencent(kline, security: b, period: .day) }
        rejects("日线不得用作周线") { _ = try ChartParsing.tencent(kline, security: a, period: .week) }
        let raw = try ChartParsing.tencent(json(#"{"code":0,"data":{"sh601899":{"month":[["2026-09-30","10","10","11","9","0"]]}}}"#), security: a, period: .month)
        check(raw.adjustment == "不复权" && raw.bars[0].open == raw.bars[0].close, "原始月线和十字星可正常展示")
        let minute = try ChartParsing.tencent(json(#"{"code":0,"data":{"sh601899":{"qt":{"sh601899":["1","紫金矿业","601899","11","10"]},"data":{"date":"20261022","data":["0930 10.10 100","0931 10.20 150","1200 10.30 180","1300 10.40 150","1301 10.50 200","1302 0 220","2500 11 300"]}}}}"#), security: a, period: .intraday)
        check(minute.bars.count == 4 && minute.bars.map(\.volume) == [100, 50, 0, 50], "午休不造数据，累计成交量转每分钟成交量，不接受非法时间或零价")
        check(minute.previousClose == 10 && ChinaClock.day(minute.lastTime!) == "2026-10-22", "使用上游交易日期和昨收")
        rejects("分时必须有上游日期") { _ = try ChartParsing.tencent(json(#"{"code":0,"data":{"sh601899":{"data":{"data":["0930 10 100"]}}}}"#), security: a, period: .intraday) }
        let east = try ChartParsing.eastmoney(json(#"{"rc":0,"data":{"code":"601899","klines":["2026-10-22,10,11,12,9,100,1000"]}}"#), security: a, period: .week)
        check(east.bars[0].close == 11 && east.source == "东方财富", "备用K线列位正确")
        check(SecurityID(market: 1, code: "510300").isExchangeFund && !b.isExchangeFund, "ETF与同号普通基金不得混为股票")
        check(ChartParsing.number(true) == nil && ChartParsing.number("nan") == nil, "布尔及非有限值不能当作价格")
        let search = json(#"{"QuotationCodeTable":{"Status":0,"Data":[{"SecurityTypeName":"基金","QuoteID":"1.510300","Code":"510300","Name":"沪深300ETF"},{"SecurityTypeName":"基金","QuoteID":"0.000001","Code":"000001","Name":"普通基金"},{"SecurityTypeName":"指数","QuoteID":"1.000001","Code":"000001","Name":"上证指数"}]}}"#)
        let withFunds = try StockSearch.parse(search, includeFunds: true), stocksOnly = try StockSearch.parse(search)
        check(withFunds.map(\.security.code) == ["510300"], "新增场内基金入口不得误加普通基金或指数")
        check(stocksOnly.isEmpty, "原股票专用搜索保留范围限制")
        let funds = try ChartParsing.funds(json(#"{"ErrCode":0,"Datas":[{"CODE":"000001","NAME":"华夏成长","CATEGORY":700,"FundBaseInfo":{"FTYPE":"混合型"}},{"CODE":"000001","NAME":"重复","CATEGORY":700,"FundBaseInfo":{"FTYPE":"混合型"}},{"CODE":"000002","NAME":"货币","CATEGORY":700,"FundBaseInfo":{"FTYPE":"货币型"}},{"CODE":"../123","NAME":"无效","CATEGORY":700,"FundBaseInfo":{"FTYPE":"混合型"}}]}"#))
        check(funds.count == 1 && funds[0].id != b.id, "基金搜索去重和校验，独立命名空间防止000001代码冲突")
        let fund = funds[0]
        let navSource = #"var fS_code="000001";var Data_netWorthTrend=[{"x":1792512000000,"y":1.2345,"equityReturn":1.5},{"x":1792425600000,"y":1.22,"equityReturn":-0.1},{"x":1792425600000,"y":1.22},{"x":1792339200000,"y":0}];var Data_ACWorthTrend=[[1792512000000,3.4567]];throw new Error("不得执行");"#
        let history = try ChartParsing.fundHistory(json(navSource), fund: fund)
        check(history.values.count == 2 && history.values.last?.day == "2026-10-21", "净值日期按北京时间转换，去重排序并剔除无效净值，不执行脚本")
        check(history.values.last?.unit == 1.2345 && history.values.last?.accumulated == 3.4567 && history.values.last?.percent == 1.5, "单位/累计净值和日增长率保持不同口径")
        check(history.values.first?.accumulated == nil, "缺失累计净值显示空值，不用单位净值补齐")
        rejects("错号基金不应展示") { _ = try ChartParsing.fundHistory(json(navSource), fund: FundIdentity(code: "000003", name: "其他", type: "混合型")) }
        rejects("接口返回HTML不能当净值") { _ = try ChartParsing.fundHistory(json("<html>not found</html>"), fund: fund) }
        check(!SecurityChartModel.isTrading(at: ChartParsing.formatter("yyyy-MM-dd HH:mm").date(from: "2026-10-22 12:00")!), "午休停止图表自动刷新")
        check(!SecurityChartModel.isTrading(at: ChartParsing.formatter("yyyy-MM-dd HH:mm").date(from: "2026-10-24 10:00")!), "周末停止图表自动刷新")
        check(SecurityChartModel.isTrading(at: ChartParsing.formatter("yyyy-MM-dd HH:mm").date(from: "2026-10-22 14:30")!), "交易时段允许更新")

        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ChartURLProtocol.self]
        let connection = URLSession(configuration: configuration)
        defer { connection.invalidateAndCancel(); ChartURLProtocol.handler = nil }
        ChartURLProtocol.handler = { request in
            if request.url?.host == "web.ifzq.gtimg.cn" { return json("{}") }
            guard request.url?.host == "push2his.eastmoney.com", URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "klt", value: "102")) == true else { throw FeedError(message: "备用入口请求周期不符") }
            return json(#"{"rc":0,"data":{"code":"601899","klines":["2026-10-22,10,11,12,9,100,1000"]}}"#)
        }
        let fallback = try await DetailChartAPI.fetchChart(a, period: .week, session: connection)
        check(fallback.source == "东方财富" && fallback.period == .week, "主图表接口无效时可切换备用入口，保留所选周期")

        let pending = PendingCharts(), chart = SecurityChartModel(loader: { try await pending.load($0, $1) })
        chart.show(a); try await waitUntil { pending.requests.count == 1 }
        chart.select(.day); try await waitUntil { pending.requests.count == 2 }
        pending.requests[1].2.resume(returning: daily)
        try await waitUntil { !chart.loading }
        pending.requests[0].2.resume(returning: minute)
        try await Task.sleep(nanoseconds: 10_000_000)
        check(chart.period == .day && chart.data?.period == .day, "快速切换周期时旧分时响应不能覆盖日K")
        chart.select(.week); try await waitUntil { pending.requests.count == 3 }
        check(chart.data == nil, "未获取过的周K不能沿用日K缓存")
        pending.requests[2].2.resume(throwing: FeedError(message: "模拟失败")); try await waitUntil { !chart.loading }
        chart.select(.day); check(chart.data?.bars.count == 2, "切回日K立即使用对应周期缓存")
        try await waitUntil { pending.requests.count == 4 }
        pending.requests[3].2.resume(throwing: FeedError(message: "刷新失败")); try await waitUntil { !chart.loading }
        check(chart.data?.bars.count == 2 && chart.error != nil, "刷新失败保留本周期缓存")
        chart.show(b); try await waitUntil { pending.requests.count == 5 }
        check(chart.data == nil, "切换证券不能显示其他股票缓存")
        var published = 0
        let sub = chart.objectWillChange.sink { published += 1 }
        chart.cancel(); pending.requests[4].2.resume(returning: daily)
        try await Task.sleep(nanoseconds: 10_000_000)
        check(published == 0 && !chart.active, "关闭不发布状态并拒绝晚到的响应")
        withExtendedLifetime(sub) {}
        chart.show(a); try await waitUntil { pending.requests.count == 6 }
        pending.requests[5].2.resume(returning: PriceChartData(security: b, bars: daily.bars, period: .day, previousClose: nil, source: "错号", adjustment: ""))
        try await waitUntil { !chart.loading }
        check(chart.error != nil && chart.data?.security == a, "错误证券响应不能写入图表缓存")
        chart.cancel()

        let pendingFunds = PendingFunds()
        let fundModel = FundDetailModel(searcher: { _ in [fund] }, loader: { try await pendingFunds.load($0) })
        fundModel.open(); fundModel.select(fund); try await waitUntil { pendingFunds.requests.count == 1 }
        let other = FundIdentity(code: "000003", name: "其他基金", type: "混合型")
        fundModel.select(other); try await waitUntil { pendingFunds.requests.count == 2 }
        pendingFunds.requests[1].1.resume(returning: FundHistory(fund: other, values: history.values))
        try await waitUntil { !fundModel.loading }
        pendingFunds.requests[0].1.resume(returning: history); try await Task.sleep(nanoseconds: 10_000_000)
        check(fundModel.history?.fund == other, "基金快速切换丢弃旧结果")
        fundModel.select(other); check(fundModel.history?.fund == other, "基金重开立即使用独立缓存")
        try await waitUntil { pendingFunds.requests.count == 3 }
        pendingFunds.requests[2].1.resume(throwing: FeedError(message: "净值超时")); try await waitUntil { !fundModel.loading }
        check(fundModel.history != nil && fundModel.error != nil, "净值失败保留缓存和错误提示")
        let fundController = FundDetailWindowController(model: fundModel)
        fundController.show(); try await waitUntil { pendingFunds.requests.count == 4 }
        var fundPublishes = 0
        let fundSubscription = fundModel.objectWillChange.sink { fundPublishes += 1 }
        let closing = ProcessInfo.processInfo.systemUptime
        fundController.window?.close()
        check(ProcessInfo.processInfo.systemUptime - closing < 1 && !fundModel.active, "净值未返回时窗口应快速关闭")
        pendingFunds.requests[3].1.resume(returning: FundHistory(fund: other, values: history.values))
        try await Task.sleep(nanoseconds: 10_000_000)
        check(fundPublishes == 0 && fundModel.history?.fund == other, "基金关闭后迟到成功不得修改状态")
        withExtendedLifetime(fundSubscription) {}

        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try preview(PriceCanvasChart(data: daily).padding(20).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 780, height: 320), to: build.appendingPathComponent("kline-preview.png"))
        try preview(FundDetailView(model: fundModel, close: {}), size: NSSize(width: 780, height: 800), to: build.appendingPathComponent("fund-nav-preview.png"))
        check(FileManager.default.fileExists(atPath: build.appendingPathComponent("kline-preview.png").path), "K线和净值界面可渲染")
        print("通过 \(checks) 项图表与基金检查。")
    }
    @MainActor static func preview<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view); host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; host.wantsLayer = true; host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw FeedError(message: "预览失败") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.close()
    }
    @MainActor static func live() async throws {
        let a = SecurityID(market: 1, code: "601899")
        for period in PriceChartPeriod.allCases {
            let data = try await DetailChartAPI.chart(a, period: period)
            print("\(a.id) \(period.title)：\(data.bars.count)条；\(data.source)；\(data.bars.last?.label ?? "")")
        }
        let etf = try await DetailChartAPI.chart(SecurityID(market: 1, code: "510300"), period: .intraday)
        print("ETF分时：\(etf.bars.count)条；\(MarketText.timestamp(etf.lastTime))")
        let funds = try await DetailChartAPI.searchFunds("161725")
        guard let fund = funds.first else { throw FeedError(message: "真实基金搜索无结果") }
        let history = try await DetailChartAPI.fundHistory(fund)
        print("\(fund.name)：\(history.values.count)条净值；\(history.values.last?.day ?? "")；累计净值\(history.values.last?.accumulated ?? 0)")
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        let model = FundDetailModel(searcher: { _ in funds }, loader: { _ in history }); model.open(); model.select(fund)
        while model.loading { try await Task.sleep(nanoseconds: 5_000_000) }
        let daily = try await DetailChartAPI.chart(a, period: .day)
        try preview(PriceCanvasChart(data: daily).padding(20).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 780, height: 320), to: build.appendingPathComponent("kline-live-preview.png"))
        try preview(FundDetailView(model: model, close: {}), size: NSSize(width: 780, height: 800), to: build.appendingPathComponent("fund-nav-live-preview.png"))
        model.cancel()
        let detail = try await MarketAPI.fetchDetail(a)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChartLive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let favorites = MarketModel(directory: directory)
        let stock = StockDetailModel(loadDetail: { _ in detail })
        let charts = SecurityChartModel(loader: { _, _ in daily }); charts.select(.day)
        let controller = StockDetailWindowController(favorites: favorites, model: stock, charts: charts, openTHS: {})
        controller.show(detail.quote)
        let deadline = Date().addingTimeInterval(5)
        while stock.state?.loading == true || charts.loading {
            guard Date() < deadline else { throw FeedError(message: "完整图表详情布局超时") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try preview(StockDetailView(model: stock, charts: charts, favorites: favorites, openTHS: {}, close: {}), size: NSSize(width: 820, height: 950), to: build.appendingPathComponent("stock-detail-live-preview.png"))
        controller.window?.close()
        let opening = ProcessInfo.processInfo.systemUptime
        controller.show(detail.quote); controller.window?.contentView?.layoutSubtreeIfNeeded()
        let openSeconds = ProcessInfo.processInfo.systemUptime - opening
        let closing = ProcessInfo.processInfo.systemUptime
        controller.window?.close()
        let closeSeconds = ProcessInfo.processInfo.systemUptime - closing
        guard openSeconds < 1, closeSeconds < 1, !stock.isActive, !charts.active else { throw FeedError(message: "完整K线详情打开或关闭过慢") }
        print(String(format: "真实120根K线详情缓存重开 %.3f 秒；关闭 %.3f 秒。", openSeconds, closeSeconds))
    }
}

import AppKit
import Combine

/// 请求故意不响应取消，用来验证晚到的接口响应不会改写当前股票或关闭后的界面。
@MainActor private final class PendingStockRequests {
    var details: [(SecurityID, CheckedContinuation<StockDetail, Error>)] = []
    var histories: [(SecurityID, CheckedContinuation<[DailyClose], Error>)] = []
    func detail(_ security: SecurityID) async throws -> StockDetail {
        try await withCheckedThrowingContinuation { details.append((security, $0)) }
    }
    func history(_ security: SecurityID) async throws -> [DailyClose] {
        try await withCheckedThrowingContinuation { histories.append((security, $0)) }
    }
}

@main struct StockDetailTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            do { try await run(); exit(0) }
            catch { fputs("详情测试失败：\(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() {
                guard Date() < deadline else { throw FeedError(message: message) }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockDetailTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let market = MarketModel(directory: directory)
        let now = Date()
        func quote(_ code: String, price: Double = 12, at date: Date? = nil) -> MarketQuote {
            MarketQuote(security: SecurityID(market: 0, code: code), name: "测试\(code)", price: price,
                        percent: 1, change: 0.1, netInflow: 100, updatedAt: date ?? now)
        }
        func detail(_ quote: MarketQuote) -> StockDetail {
            StockDetail(quote: quote, open: 11, previousClose: 11.9, high: 13, low: 10, volume: 100,
                        amount: 1200, turnover: 1, volumeRatio: 1, marketCap: 10000, floatCap: 5000, pe: 10, pb: 1)
        }
        let bars = (1...60).map { offset in
            DailyClose(day: ChinaClock.addingDays(offset - 60), close: Double(offset + 10))
        }
        let a = quote("000001"), b = quote("000002")
        let requests = PendingStockRequests()
        let model = StockDetailModel(loadDetail: { try await requests.detail($0) }, loadHistory: { try await requests.history($0) })
        var accepted: [SecurityID] = []
        model.onQuote = { accepted.append($0.security) }
        model.showStock(a)
        check(model.state?.quote.id == a.id && model.state?.loading == true, "点击后立即显示已知行情，不等待接口")
        try await waitUntil("首次请求未启动") { requests.details.count == 1 && requests.histories.count == 1 }
        model.showStock(b)
        try await waitUntil("切换请求未启动") { requests.details.count == 2 && requests.histories.count == 2 }
        requests.details[1].1.resume(returning: detail(b))
        requests.histories[1].1.resume(returning: bars)
        try await waitUntil("详情与日线未独立完成") { model.state?.loading == false }
        requests.details[0].1.resume(returning: detail(a))
        requests.histories[0].1.resume(throwing: FeedError(message: "旧股票失败"))
        try await Task.sleep(nanoseconds: 20_000_000)
        check(model.state?.quote.id == b.id && model.state?.chartError == nil && accepted == [b.security], "快速切换后晚到的旧成功和失败均不能覆盖新股票")
        check(model.state?.history.count == 60 && model.state?.history.first?.date == MarketParsing.date(bars[0].day), "日线日期只转换一次，并保持完整图表")

        model.showStock(b)
        check(model.state?.detail != nil && model.state?.history.count == 60 && model.state?.isCached == true, "重复打开应立即显示详情和图表缓存")
        try await waitUntil("缓存后台刷新未启动") { requests.details.count == 3 && requests.histories.count == 3 }
        model.showStock(b)
        try await waitUntil("同股票新一轮请求未启动") { requests.details.count == 4 && requests.histories.count == 4 }
        requests.details[3].1.resume(returning: detail(quote("000002", price: 14)))
        requests.histories[3].1.resume(returning: bars)
        try await waitUntil("新请求未完成") { model.state?.loading == false }
        requests.details[2].1.resume(returning: detail(quote("000002", price: 9)))
        requests.histories[2].1.resume(throwing: FeedError(message: "旧刷新失败"))
        try await Task.sleep(nanoseconds: 20_000_000)
        check(model.state?.quote.price == 14 && model.state?.chartError == nil, "同一股票重开也必须按请求批次拒绝旧响应")

        let newer = quote("000002", price: 15, at: now.addingTimeInterval(60))
        model.showStock(newer)
        check(model.state?.quote.price == 15, "旧详情缓存不能覆盖较新的菜单行情")
        try await waitUntil("失败回退请求未启动") { requests.details.count == 5 && requests.histories.count == 5 }
        requests.details[4].1.resume(throwing: FeedError(message: "网络超时"))
        requests.histories[4].1.resume(throwing: FeedError(message: "日线超时"))
        try await waitUntil("失败未结束加载状态") { model.state?.loading == false }
        check(model.state?.detail != nil && model.state?.history.count == 60 && model.state?.detailError != nil && model.state?.chartError != nil, "网络失败须保留缓存并显示两个独立错误")

        let controller = StockDetailWindowController(favorites: market, model: model, openTHS: {})
        let start = ProcessInfo.processInfo.systemUptime
        controller.show(b)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let openTime = ProcessInfo.processInfo.systemUptime - start
        check(controller.window?.isVisible == true, "慢网络下详情窗口仍立即可见")
        try await waitUntil("窗口请求未启动") { requests.details.count == 6 && requests.histories.count == 6 }
        var publishes = 0
        let subscription = model.objectWillChange.sink { publishes += 1 }
        let closing = ProcessInfo.processInfo.systemUptime
        controller.window?.performClose(nil)
        let closeTime = ProcessInfo.processInfo.systemUptime - closing
        check(controller.window?.isVisible == false && !model.isActive, "窗口关闭不能等待未完成的网络请求")
        check(publishes == 0, "关闭不能发布状态并重新触发详情布局")
        model.cancelRequests()
        check(publishes == 0, "重复取消必须幂等")
        requests.details[5].1.resume(returning: detail(quote("000002", price: 99)))
        requests.histories[5].1.resume(returning: [])
        try await Task.sleep(nanoseconds: 20_000_000)
        check(publishes == 0 && model.state?.history.count == 60, "关闭后的迟到响应不能更新界面或清掉图表")
        withExtendedLifetime(subscription) {}
        print(String(format: "缓存详情窗口打开并布局 %.3f 秒；未完成请求时关闭 %.3f 秒。", openTime, closeTime))

        try market.addFavorite(b)
        controller.show(b)
        try await waitUntil("重开请求未启动") { requests.details.count == 7 && requests.histories.count == 7 }
        requests.details[6].1.resume(returning: detail(quote("000002", price: 16, at: now.addingTimeInterval(120))))
        requests.histories[6].1.resume(returning: bars)
        try await waitUntil("重开未更新自选行情") { market.quote(for: b.security)?.price == 16 && model.state?.loading == false }
        check(controller.window?.isVisible == true && model.state?.history.count == 60, "关闭后重开应复用窗口并正常完成详情图表与自选更新")
        controller.window?.close()
        check(!model.isActive, "标题栏关闭同样取消请求")

        let direct = MarketWindowController(directory: directory)
        direct.showStock(b)
        check(direct.window == nil && direct.stockDetail.window?.isVisible == true, "自选股入口不能创建或布局完整排行榜窗口")
        direct.stockDetail.window?.close()
        check(!direct.stockDetail.model.isActive, "直接打开的详情也可立即关闭")
        print("通过 \(checks) 项详情检查：慢网响应、切换、同股旧响应、缓存、失败回退、关闭取消、重开、窗口独立及自选行情。")
    }
}

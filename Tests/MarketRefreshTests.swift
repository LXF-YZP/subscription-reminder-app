import Foundation
import AppKit

final class MarketMockProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let result = Result { try Self.handler!(request) }
        Self.lock.unlock()
        switch result {
        case .success(let data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@main struct MarketRefreshTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func session(_ handler: @escaping (URLRequest) throws -> Data) -> URLSession {
            MarketMockProtocol.handler = handler
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MarketMockProtocol.self]
            return URLSession(configuration: config)
        }
        func parameters(_ request: URLRequest) -> [String: String] {
            Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        }
        func ids(_ request: URLRequest) -> [SecurityID] {
            let parameters = parameters(request)
            return (parameters["secids"] ?? parameters["fs"]!).split(separator: ",").map {
                SecurityID.parse(String($0).replacingOccurrences(of: "i:", with: ""))!
            }
        }
        let time = ISO8601DateFormatter().date(from: "2026-10-22T03:30:00Z")!
        func row(_ security: SecurityID) -> [String: Any] {
            ["f12": security.code, "f13": security.market, "f14": "测试" + security.code, "f2": 12.34,
             "f3": 1.2, "f4": 0.14, "f62": -12345678, "f124": time.timeIntervalSince1970]
        }
        func response(_ securities: [SecurityID], object: Bool = false) throws -> Data {
            let rows = securities.map(row)
            let diff: Any = object ? Dictionary(uniqueKeysWithValues: rows.enumerated().map { (String($0.offset), $0.element) }) : rows
            let payload: [String: Any] = ["rc": 0, "data": ["total": rows.count, "diff": diff]]
            return try JSONSerialization.data(withJSONObject: payload)
        }
        let indices = MarketIndex.allCases.map(\.security)
        let primary = session { request in
            let values = parameters(request)
            check(request.url!.path.hasSuffix("/clist/get"), "应优先走已验证可用的 clist 行情入口")
            check(values["fs"] == indices.map { "i:" + $0.id }.joined(separator: ",") && values["secids"] == nil,
                  "指定证券筛选必须保留市场前缀，不能把上证指数与平安银行混淆")
            check(values["pz"] == "3" && values["np"] == "1", "主入口必须显式指定完整页大小与数组格式")
            return try response(indices.reversed().map { $0 })
        }
        let direct = await MarketAPI.fetchQuoteBatch(indices, session: primary)
        check(direct.error == nil && direct.quotes.map(\.security) == indices,
              "主入口成功时按请求代码归位，不能依赖服务器返回顺序")
        primary.invalidateAndCancel()
        var calls: [String] = []
        let fallback = session { request in
            calls.append(request.url!.path)
            if request.url!.path.contains("clist/get") { throw URLError(.networkConnectionLost) }
            check(parameters(request)["pz"] == "3" && parameters(request)["pn"] == "1", "必须显式请求完整批次页大小")
            return try response(ids(request), object: true)
        }
        let recovered = try await MarketAPI.fetchQuotes(indices, session: fallback)
        check(recovered.count == 3 && recovered[0].price == 12.34 && recovered[0].netInflow == -12345678, "主入口连接中断后备用入口须保留价格与资金口径")
        check(calls.count == 3, "网络失败只重试一次，然后切换入口")
        fallback.invalidateAndCancel()

        let stocks = (100000..<100150).map { SecurityID(market: 0, code: String($0)) }
        var batches: [[SecurityID]] = []
        let missing = stocks[99]
        let partial = session { request in
            let requested = ids(request); batches.append(requested)
            precondition(requested.count <= 100, "主入口每页最多100只，必须先分批")
            if request.url!.path.contains("ulist/get") { throw URLError(.networkConnectionLost) }
            // 第一轮只丢一只；备用入口也不可用，小批补查应只请求这一只。
            return try response(requested.count == 100 ? requested.filter { $0 != missing } : requested)
        }
        let filled = await MarketAPI.fetchQuoteUniverse(stocks, session: partial, expiresAt: Date().addingTimeInterval(5))
        check(filled.quotes.count == 150 && filled.error == nil, "部分响应和备用入口失败后，小批补查应恢复完整结果")
        check(batches.filter { $0.count > 1 }.count == 2 && batches.filter { $0 == [missing] }.count == 3, "成功股票不应重复下载，只有缺失股票补查")
        partial.invalidateAndCancel()

        let mismatched = session { _ in try response([SecurityID(market: 1, code: "600519")]) }
        let invalid = await MarketAPI.fetchQuoteBatch(indices, session: mismatched)
        check(invalid.quotes.isEmpty && invalid.error?.contains("未请求") == true, "其他股票的行情不得冒充请求结果")
        mismatched.invalidateAndCancel()

        let independent = session { request in
            if request.url!.path.contains("/api/qt/") { return try response(ids(request)) }
            throw URLError(.cannotConnectToHost)
        }
        let results = await MarketAPI.fetchAll(session: independent, expiresAt: Date().addingTimeInterval(5))
        check(results.count == 3 && results.allSatisfy { $0.snapshot == nil && $0.indexQuote?.updatedAt == time }, "成员列表失败时，已获取的三个指数也应返回")
        check(results.allSatisfy { $0.error?.contains("成分股查询失败") == true }, "成员失败仍须如实报告，不能显示完整榜单")
        independent.invalidateAndCancel()

        let missingStock = SecurityID(market: 1, code: "600999")
        let regional = session { request in
            if request.url!.path.contains("/api/qt/") { return try response(ids(request).filter { $0 != missingStock }) }
            let node = parameters(request)["node"]!
            let count = node == MarketIndex.shanghai.node ? 1001 : (node == MarketIndex.shenzhen.node ? 500 : 300)
            if request.url!.path.hasSuffix("getHQNodeStockCount") { return Data("\"\(count)\"".utf8) }
            let members = (0..<count).map { ["symbol": String(format: node == MarketIndex.shanghai.node ? "sh%06d" : "sz%06d", node == MarketIndex.shanghai.node ? 600000 + $0 : 1 + $0)] }
            return try JSONSerialization.data(withJSONObject: members)
        }
        let regionalResults = await MarketAPI.fetchAll(session: regional, expiresAt: Date().addingTimeInterval(5))
        let shanghai = regionalResults.first { $0.index == .shanghai }!
        check(shanghai.snapshot == nil && shanghai.failedCodes == [missingStock.id] && shanghai.indexQuote != nil, "永久缺少一只股票时须保留旧榜单、报告准确代码，同时更新指数")
        check(regionalResults.filter { $0.index != .shanghai }.allSatisfy { $0.snapshot?.isComplete == true && $0.error == nil }, "一个范围缺失不能拖住其他完整范围的榜单")
        regional.invalidateAndCancel()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarketRefreshTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MarketModel(directory: directory)
        let old = time.addingTimeInterval(-21 * 60)
        func quote(_ index: MarketIndex, at date: Date) -> MarketQuote {
            MarketQuote(security: index.security, name: index.name, price: 3500, percent: -1, change: -35, netInflow: nil, updatedAt: date)
        }
        let stock = MarketQuote(security: SecurityID(market: 1, code: "600000"), name: "测试股票", price: 12, percent: 1, change: 0.1, netInflow: 100, updatedAt: old)
        let oldSnapshot = MarketSnapshot(index: .shanghai, quote: quote(.shanghai, at: old), stocks: [stock], memberCount: 1, fetchedAt: old)
        model.snapshots[.shanghai] = oldSnapshot
        model.apply(results)
        check(model.indexQuotes[.shanghai]?.updatedAt == time && model.snapshots[.shanghai]?.quote.updatedAt == old, "11:30指数成功时必须独立更新，不能重写11:09旧榜单时间")
        check(model.indexErrors.isEmpty && model.errors.count == 3, "指数成功不能显示指数刷新失败，榜单失败仍须保留")
        let reloaded = MarketModel(directory: directory)
        check(reloaded.indexQuotes[.shanghai]?.updatedAt == time && reloaded.snapshots[.shanghai]?.quote.updatedAt == old, "重启后新指数和旧榜单各自保留原时间")
        let full = MarketSnapshot(index: .shanghai, quote: quote(.shanghai, at: time), stocks: [stock], memberCount: 1, fetchedAt: time)
        let success = [MarketResult(index: .shanghai, snapshot: full, error: nil, failedCodes: [], indexQuote: full.quote)]
        model.apply(success)
        check(model.snapshots[.shanghai]?.quote.updatedAt == time && model.errors.isEmpty, "恢复成功后替换旧榜单并清除失败状态")
        let log = try String(contentsOf: directory.appendingPathComponent("activity.log"), encoding: .utf8)
        check(log.contains("成分股查询失败") && log.contains("行情刷新") && log.contains("+08:00"), "运行日志应包含真实失败原因及北京时间")
        model.apply(MarketIndex.allCases.map { index in
            let snapshot = MarketSnapshot(index: index, quote: quote(index, at: time), stocks: [stock], memberCount: 1, fetchedAt: time)
            return MarketResult(index: index, snapshot: snapshot, error: nil, failedCodes: [], indexQuote: snapshot.quote)
        })
        check(model.monitoringTime == old, "仅指数更新而成分行情停滞时，监测不能误报恢复")
        let active = MarketQuote(security: SecurityID(market: 1, code: "600001"), name: "正常交易股", price: 12, percent: 1, change: 0.1, netInflow: 100, updatedAt: time)
        model.apply(MarketIndex.allCases.map { index in
            let snapshot = MarketSnapshot(index: index, quote: quote(index, at: time), stocks: [stock, active], memberCount: 2, fetchedAt: time)
            return MarketResult(index: index, snapshot: snapshot, error: nil, failedCodes: [], indexQuote: snapshot.quote)
        })
        check(model.monitoringTime == time, "单只股票停牌不能使整个正常更新的范围误报警")
        model.snapshots.removeValue(forKey: .csi300)
        check(model.monitoringTime == nil, "缺少范围时不能确认整体行情已恢复")
        print("通过 \(checks) 项行情刷新检查：入口切换、完整批次、只补缺失、代码校验、独立指数、缓存时间与恢复日志。")
    }
}

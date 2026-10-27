import Foundation

enum MarketIndex: String, Codable, CaseIterable, Identifiable {
    case shanghai, shenzhen, csi300
    var id: String { rawValue }
    var name: String {
        switch self { case .shanghai: return "上证指数"; case .shenzhen: return "深证成指"; case .csi300: return "沪深300" }
    }
    var security: SecurityID {
        switch self {
        case .shanghai: return SecurityID(market: 1, code: "000001")
        case .shenzhen: return SecurityID(market: 0, code: "399001")
        case .csi300: return SecurityID(market: 1, code: "000300")
        }
    }
    var node: String {
        switch self { case .shanghai: return "zhishu_000001"; case .shenzhen: return "zhishu_399001"; case .csi300: return "hs300" }
    }
    var scope: String { self == .shanghai ? "上证指数成分中的 A 股（不含 B 股）" : "\(name)成分股" }
}

struct SecurityID: Codable, Hashable, Identifiable {
    let market: Int
    let code: String
    var id: String { "\(market).\(code)" }
    var marketName: String {
        market == 1 ? "沪" : (["4", "8", "9"].contains(String(code.prefix(1))) ? "京" : "深")
    }
    var isExchangeFund: Bool { market == 1 ? code.hasPrefix("5") : ["15", "16", "18"].contains(String(code.prefix(2))) }
    var label: String { "\(marketName) \(code)" }
    static func parse(_ value: String) -> SecurityID? {
        let pieces = value.split(separator: ".")
        guard pieces.count == 2, let market = Int(pieces[0]), [0, 1].contains(market),
              pieces[1].count == 6, pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return SecurityID(market: market, code: String(pieces[1]))
    }
}

extension Issue {
    /// 将上市日历中的证券代码转换为行情接口使用的交易所代码。
    var marketSecurity: SecurityID? {
        guard securityCode.count == 6, securityCode.allSatisfy({ $0.isASCII && $0.isNumber }),
              let first = securityCode.first else { return nil }
        let market: Int
        if kind == .bond {
            if securityCode.hasPrefix("11") { market = 1 }
            else if securityCode.hasPrefix("12") { market = 0 }
            else { return nil }
        } else {
            switch first {
            case "6": market = 1
            case "0", "3", "4", "8", "9": market = 0
            default: return nil
            }
        }
        return SecurityID(market: market, code: securityCode)
    }
}

struct MarketQuote: Codable, Identifiable {
    let security: SecurityID
    let name: String
    let price: Double?
    let percent: Double?
    let change: Double?
    let netInflow: Double?
    let updatedAt: Date?
    var id: String { security.id }
}

struct StockSearchResult: Identifiable, Equatable {
    let security: SecurityID
    let name: String
    let marketName: String
    var id: String { security.id }
    var placeholderQuote: MarketQuote {
        MarketQuote(security: security, name: name, price: nil, percent: nil, change: nil, netInflow: nil, updatedAt: nil)
    }
}

enum StockSearch {
    static func parse(_ data: Data, includeFunds: Bool = false) throws -> [StockSearchResult] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["QuotationCodeTable"] as? [String: Any], table["Status"] as? Int == 0 else {
            throw FeedError(message: "股票搜索暂不可用，请稍后重试")
        }
        if table["Data"] is NSNull, table["TotalCount"] as? Int == 0 { return [] }
        guard let rows = table["Data"] as? [[String: Any]] else {
            throw FeedError(message: "股票搜索暂不可用，请稍后重试")
        }
        var seen = Set<SecurityID>()
        return rows.compactMap { row in
            guard let marketName = row["SecurityTypeName"] as? String, (["沪A", "深A", "京A"].contains(marketName) || (includeFunds && marketName == "基金")),
                  let raw = row["QuoteID"] as? String, let security = SecurityID.parse(raw),
                  marketName != "基金" || security.isExchangeFund,
                  row["Code"] as? String == security.code,
                  let name = row["Name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(security).inserted else { return nil }
            return StockSearchResult(security: security, name: name, marketName: marketName)
        }
    }

    static func local(_ query: String, quotes: [MarketQuote]) -> [StockSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        return quotes.filter { $0.name.lowercased().contains(term) || $0.security.code.contains(term) }
            .sorted { lhs, rhs in
                let a = lhs.security.code == term || lhs.name.lowercased() == term
                let b = rhs.security.code == term || rhs.name.lowercased() == term
                return a != b ? a : lhs.id < rhs.id
            }.prefix(20).map {
                StockSearchResult(security: $0.security, name: $0.name,
                                  marketName: $0.security.isExchangeFund ? "基金" : $0.security.marketName + "A")
            }
    }
}

enum RankingKind: String, CaseIterable, Identifiable {
    case gainers, losers, inflows, outflows
    var id: String { rawValue }
    var title: String {
        switch self { case .gainers: return "涨幅前十"; case .losers: return "跌幅前十"; case .inflows: return "资金流入前十"; case .outflows: return "资金流出前十" }
    }
    var isFlow: Bool { self == .inflows || self == .outflows }
    var positive: Bool { self == .gainers || self == .inflows }
    func value(_ quote: MarketQuote) -> Double? { isFlow ? quote.netInflow : quote.percent }
}

struct MarketSnapshot: Codable {
    let index: MarketIndex
    let quote: MarketQuote
    let stocks: [MarketQuote]
    let memberCount: Int
    let fetchedAt: Date
    var tradingDay: String? { quote.updatedAt.map { ChinaClock.day($0) } }
    var isComplete: Bool {
        memberCount > 0 && stocks.count == memberCount && Set(stocks.map(\.id)).count == memberCount &&
            quote.security == index.security && quote.price != nil && quote.percent != nil && quote.updatedAt != nil
    }
    func hasClosingData(at date: Date) -> Bool {
        guard isComplete, let updated = quote.updatedAt, tradingDay == ChinaClock.day(date),
              ChinaClock.day(fetchedAt) == ChinaClock.day(date) else { return false }
        return ChinaClock.isClosed(at: updated) && ChinaClock.isClosed(at: fetchedAt)
    }
    var eligibleStocks: [MarketQuote] {
        guard let updated = quote.updatedAt,
              let day = ChinaClock.calendar.dateInterval(of: .day, for: updated) else { return [] }
        // 每个快照只求一次北京时间的日期边界，避免给几千只股票逐个创建日期格式器。
        return stocks.filter { stock in
            guard let time = stock.updatedAt, time >= day.start, time < day.end,
                  let price = stock.price, price > 0 else { return false }
            return true
        }
    }
    func ranked(_ kind: RankingKind) -> [MarketQuote] {
        eligibleStocks.filter { quote in
            guard let value = kind.value(quote) else { return false }
            return kind.positive ? value > 0 : value < 0
        }.sorted { lhs, rhs in
            let a = kind.value(lhs)!, b = kind.value(rhs)!
            return a == b ? lhs.id < rhs.id : (kind.positive ? a > b : a < b)
        }.prefix(10).map { $0 }
    }
    func availableCount(_ kind: RankingKind) -> Int { eligibleStocks.filter { kind.value($0) != nil }.count }
}

/// 将多个指数快照合并为证券索引。指数之间可能有重叠成分股，按行情时间保留较新的记录。
enum MarketQuoteIndex {
    static func latest<S: Sequence>(from snapshots: S) -> [SecurityID: MarketQuote] where S.Element == MarketSnapshot {
        snapshots.reduce(into: [SecurityID: MarketQuote]()) { result, snapshot in
            for quote in snapshot.stocks {
                guard let current = result[quote.security] else {
                    result[quote.security] = quote
                    continue
                }
                let currentDate = current.updatedAt ?? .distantPast
                let quoteDate = quote.updatedAt ?? .distantPast
                if quoteDate >= currentDate { result[quote.security] = quote }
            }
        }
    }
}

struct MarketResult {
    let index: MarketIndex
    let snapshot: MarketSnapshot?
    let error: String?
    let failedCodes: [String]
    var indexQuote: MarketQuote? = nil
}

struct MarketQuoteBatch {
    let quotes: [MarketQuote]
    let error: String?
}

enum MarketRefreshSchedule {
    /// 无交易日历时，10 点后完整、成功的旧交易日行情仅用作降频依据。
    static func interval(at date: Date, snapshots: [MarketIndex: MarketSnapshot], hasError: Bool) -> TimeInterval? {
        guard TradingCalendar.isTradingDay(date) else { return nil }
        let parts = ChinaClock.calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let today = ChinaClock.day(date)
        let all = MarketIndex.allCases.compactMap { snapshots[$0] }
        let complete = all.count == MarketIndex.allCases.count && all.allSatisfy(\.isComplete)
        let oldDay = all.first?.tradingDay
        let likelyHoliday = minute >= 600 && complete && !hasError && oldDay != nil && oldDay! < today &&
            all.allSatisfy { $0.tradingDay == oldDay && ChinaClock.day($0.fetchedAt) == today }
        if minute >= 900 {
            if complete && !hasError && all.allSatisfy({ $0.hasClosingData(at: date) }) { return nil }
            return likelyHoliday ? 3600 : 900
        }
        if minute >= 540 { return hasError ? 60 : (likelyHoliday ? 3600 : 300) }
        return 3600
    }
    /// 午休和收盘后以最后一个交易时刻为准，不能把正常休市误报为行情落后。
    static func isStale(_ updatedAt: Date?, at date: Date) -> Bool {
        guard TradingCalendar.isTradingDay(date) else { return false }
        let start = ChinaClock.calendar.startOfDay(for: date)
        let minute = date.timeIntervalSince(start) / 60
        guard minute >= 570 else { return false }
        let expectedMinute = minute >= 900 ? 900 : (minute >= 690 && minute < 780 ? 690 : minute)
        guard let updatedAt = updatedAt else { return true }
        return start.addingTimeInterval(expectedMinute * 60).timeIntervalSince(updatedAt) > 360
    }
}

struct StockDetail: Codable {
    let quote: MarketQuote
    let open: Double?
    let previousClose: Double?
    let high: Double?
    let low: Double?
    let volume: Double?
    let amount: Double?
    let turnover: Double?
    let volumeRatio: Double?
    let marketCap: Double?
    let floatCap: Double?
    let pe: Double?
    let pb: Double?
}

struct DailyClose: Codable, Identifiable {
    let day: String
    let close: Double
    var id: String { day }
    var date: Date { MarketParsing.date(day)! }
}

enum MarketText {
    static func number(_ value: Double?, signed: Bool = false, suffix: String = "") -> String {
        guard let value = value else { return "—" }
        return String(format: signed ? "%+.2f" : "%.2f", value) + suffix
    }
    static func money(_ value: Double?, signed: Bool = false) -> String {
        guard let value = value else { return "—" }
        let unit = abs(value) >= 100_000_000 ? "亿" : "万"
        let amount = value / (unit == "亿" ? 100_000_000 : 10_000)
        return number(amount, signed: signed, suffix: unit)
    }
    static func quantity(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return abs(value) < 10_000 ? String(format: "%.0f", value) : money(value)
    }
    static func timestamp(_ date: Date?) -> String {
        guard let date = date else { return "时间未知" }
        return "\(ChinaClock.day(date)) \(ChinaClock.time(date))"
    }
    static func rankingCopy(snapshot: MarketSnapshot, kind: RankingKind) -> String {
        let lines = [
            "\(snapshot.index.name) · \(kind.title)",
            "数据时间：\(timestamp(snapshot.quote.updatedAt))",
            "口径：\(kind.isFlow ? "当日主力净流入额（元）" : "涨跌幅")"
        ] + snapshot.ranked(kind).enumerated().map { offset, quote in
            let value = kind.isFlow ? money(quote.netInflow, signed: true) : number(quote.percent, signed: true, suffix: "%")
            return "\(offset + 1). \(quote.name)（\(quote.security.code)）  \(value)"
        }
        return lines.joined(separator: "\n")
    }
}

enum MarketParsing {
    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let number = value.doubleValue
            return number.isFinite ? number : nil
        }
        if let value = value as? String, let number = Double(value), number.isFinite { return number }
        return nil
    }
    static func date(_ value: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = ChinaClock.calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        guard let date = format.date(from: value), ChinaClock.day(date) == value else { return nil }
        return date
    }
    static func timestamp(_ value: Any?) -> Date? {
        guard let time = number(value), time > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: time)
    }
    static func payload(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["rc"] as? Int) == 0, let payload = root["data"] as? [String: Any] else {
            throw FeedError(message: "行情数据源返回异常或格式已变化")
        }
        return payload
    }
    static func quotes(_ data: Data, expected: [SecurityID]? = nil) throws -> [MarketQuote] {
        let root = try payload(data)
        let rows: [[String: Any]]
        if let array = root["diff"] as? [[String: Any]] { rows = array }
        else if let object = root["diff"] as? [String: [String: Any]],
                Set(object.keys) == Set((0..<object.count).map(String.init)) {
            rows = (0..<object.count).compactMap { object[String($0)] }
        } else { throw FeedError(message: "批量行情格式异常") }
        guard let total = root["total"] as? Int, total == rows.count else {
            throw FeedError(message: "批量行情响应不完整")
        }
        let quotes = try rows.map { row -> MarketQuote in
            guard let code = row["f12"] as? String, let market = row["f13"] as? Int,
                  let security = SecurityID.parse("\(market).\(code)"), let name = row["f14"] as? String, !name.isEmpty else {
                throw FeedError(message: "行情缺少证券代码或名称")
            }
            return MarketQuote(security: security, name: name, price: number(row["f2"]), percent: number(row["f3"]),
                               change: number(row["f4"]), netInflow: number(row["f62"]), updatedAt: timestamp(row["f124"]))
        }
        guard Set(quotes.map(\.id)).count == quotes.count else { throw FeedError(message: "行情出现重复证券代码") }
        if let expected = expected, Set(quotes.map(\.security)) != Set(expected) {
            throw FeedError(message: "部分成分股行情缺失，保留上次完整榜单")
        }
        return quotes
    }
    static func members(_ data: Data, expected: Int, index: MarketIndex) throws -> [SecurityID] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == expected,
              expected > 0, expected <= 4000 else { throw FeedError(message: "成分股列表不完整") }
        if index == .shenzhen && expected != 500 { throw FeedError(message: "深证成指成分数量异常") }
        if index == .csi300 && expected != 300 { throw FeedError(message: "沪深300成分数量异常") }
        if index == .shanghai && expected < 1000 { throw FeedError(message: "上证指数成分数量异常") }
        let all = try rows.map { row -> SecurityID in
            guard let symbol = row["symbol"] as? String, symbol.count == 8,
                  let market = ["sh": 1, "sz": 0][String(symbol.prefix(2))],
                  let security = SecurityID.parse("\(market).\(symbol.suffix(6))") else { throw FeedError(message: "成分股代码格式异常") }
            return security
        }
        guard Set(all).count == all.count else { throw FeedError(message: "成分股列表存在重复，未确认完整性") }
        // 上证综指包含 B 股；应用只展示可以在 A 股账户关注的 A 股，明确排除 B 股。
        let filtered = all.filter { security in
            index == .shanghai ? security.market == 1 && security.code.hasPrefix("6") :
                ((security.market == 1 && security.code.hasPrefix("6")) || (security.market == 0 && (security.code.hasPrefix("0") || security.code.hasPrefix("3"))))
        }
        guard !filtered.isEmpty, index == .shanghai || filtered.count == all.count else { throw FeedError(message: "成分股范围异常") }
        return filtered
    }
    static func detail(_ data: Data, security: SecurityID) throws -> StockDetail {
        let row = try payload(data)
        guard let code = row["f57"] as? String, code == security.code, let name = row["f58"] as? String else {
            throw FeedError(message: "个股详情代码不匹配")
        }
        let quote = MarketQuote(security: security, name: name, price: number(row["f43"]), percent: number(row["f170"]),
                                change: number(row["f169"]), netInflow: number(row["f137"]), updatedAt: timestamp(row["f86"]))
        return StockDetail(quote: quote, open: number(row["f46"]), previousClose: number(row["f60"]), high: number(row["f44"]),
                           low: number(row["f45"]), volume: number(row["f47"]), amount: number(row["f48"]), turnover: number(row["f168"]),
                           volumeRatio: number(row["f50"]), marketCap: number(row["f116"]), floatCap: number(row["f117"]), pe: number(row["f162"]), pb: number(row["f167"]))
    }
    static func history(_ data: Data, security: SecurityID) throws -> [DailyClose] {
        let row = try payload(data)
        guard row["code"] as? String == security.code, let values = row["klines"] as? [String], !values.isEmpty else {
            throw FeedError(message: "日线数据暂不可用")
        }
        return try values.map { value in
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, date(String(parts[0])) != nil, let close = Double(parts[2]), close.isFinite, close > 0 else {
                throw FeedError(message: "日线数据格式异常")
            }
            return DailyClose(day: String(parts[0]), close: close)
        }.sorted { $0.day < $1.day }
    }
}

import CoreFoundation

enum MarketAPI {
    static let quoteFields = "f2,f3,f4,f12,f13,f14,f62,f124"
    static func url(_ base: String, _ parameters: [String: String]) -> URL {
        var parts = URLComponents(string: base)!
        parts.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config)
    }
    static func get(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Mozilla/5.0 SubscriptionReminder/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        for attempt in 0...1 {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw FeedError(message: "行情数据源响应无效") }
                guard response.statusCode == 200 else { throw FeedError(message: "行情接口 HTTP \(response.statusCode)") }
                return data
            } catch {
                if Task.isCancelled || attempt == 1 { throw error }
            }
        }
        throw FeedError(message: "行情查询失败")
    }
    static func fetchQuotes(_ securities: [SecurityID], session: URLSession) async throws -> [MarketQuote] {
        let batch = await fetchQuoteBatch(securities, session: session)
        guard batch.quotes.count == Set(securities).count else {
            throw FeedError(message: batch.error ?? "部分行情未获取")
        }
        return batch.quotes
    }
    static func failureDescription(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            switch value.code {
            case NSURLErrorTimedOut: return "行情请求超时（\(value.code)）"
            case NSURLErrorNetworkConnectionLost: return "行情接口断开连接（\(value.code)）"
            case NSURLErrorNotConnectedToInternet: return "网络未连接（\(value.code)）"
            case NSURLErrorCancelled: return "行情请求已取消或达到时限"
            default: return "行情网络错误（\(value.code)）"
            }
        }
        return error.localizedDescription
    }
    /// 每个入口严格校验代码、重复和响应条数；部分响应只保留已核实的股票，再补查缺失项。
    static func fetchQuoteBatch(_ securities: [SecurityID], session: URLSession) async -> MarketQuoteBatch {
        let requested = Set(securities)
        var quotes: [SecurityID: MarketQuote] = [:]
        var failures: [String] = []
        // clist 的 i: 筛选支持指定证券，且每页最多100条。旧 ulist 入口会间歇断连。
        for endpoint in ["clist/get", "ulist/get"] {
            let missing = securities.filter { quotes[$0] == nil }
            if missing.isEmpty || Task.isCancelled { break }
            do {
                var parameters = ["fltt": "2", "invt": "2", "np": "1", "pn": "1",
                                  "pz": String(missing.count), "fields": quoteFields,
                                  "ut": "bd1d9ddb04089700cf9c27f6f7426281", "fid": "f12", "po": "0"]
                if endpoint == "clist/get" { parameters["fs"] = missing.map { "i:" + $0.id }.joined(separator: ",") }
                else { parameters["secids"] = missing.map(\.id).joined(separator: ",") }
                let data = try await get(url("https://push2.eastmoney.com/api/qt/" + endpoint, parameters), session: session)
                let values = try MarketParsing.quotes(data)
                guard Set(values.map(\.security)).isSubset(of: Set(missing)) else {
                    throw FeedError(message: "行情响应包含未请求的证券")
                }
                for quote in values { quotes[quote.security] = quote }
                if quotes.count < requested.count { failures.append("批次缺少 \(requested.count - quotes.count) 只行情") }
            } catch { failures.append("\(endpoint)：\(failureDescription(error))") }
        }
        return MarketQuoteBatch(quotes: securities.compactMap { quotes[$0] },
                                error: quotes.count == requested.count ? nil : (failures.isEmpty ? "部分行情未获取" : failures.joined(separator: "；")))
    }
    /// 第一轮100只一批；只对缺失证券再用20只小批补查一次，成功批次不重复下载。
    static func fetchQuoteUniverse(_ securities: [SecurityID], session: URLSession, expiresAt: Date) async -> MarketQuoteBatch {
        var quotes: [SecurityID: MarketQuote] = [:]
        var failures: [String] = []
        for size in [100, 20] {
            let missing = securities.filter { quotes[$0] == nil }
            guard !missing.isEmpty, !Task.isCancelled, Date() < expiresAt else { break }
            let batches = stride(from: 0, to: missing.count, by: size).map { Array(missing[$0..<min($0 + size, missing.count)]) }
            await withTaskGroup(of: MarketQuoteBatch.self) { group in
                var next = 0
                func enqueue() {
                    let batch = batches[next]; next += 1
                    group.addTask { await fetchQuoteBatch(batch, session: session) }
                }
                for _ in 0..<min(10, batches.count) { enqueue() }
                for await result in group {
                    for quote in result.quotes { quotes[quote.security] = quote }
                    if let error = result.error { failures.append(error) }
                    if next < batches.count && !Task.isCancelled && Date() < expiresAt { enqueue() }
                }
            }
        }
        let error = Date() >= expiresAt ? "本轮行情查询达到28秒时限" : failures.last ?? "部分行情未获取"
        return MarketQuoteBatch(quotes: securities.compactMap { quotes[$0] }, error: quotes.count == securities.count ? nil : error)
    }
    static func searchStocks(_ query: String, includeFunds: Bool = false) async throws -> [StockSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let connection = session()
        defer { connection.invalidateAndCancel() }
        let data = try await get(url("https://searchapi.eastmoney.com/api/suggest/get", ["input": term, "type": "14", "count": "20"]), session: connection)
        return try StockSearch.parse(data, includeFunds: includeFunds)
    }
    static func fetchFavoriteQuotes(_ securities: [SecurityID]) async -> [MarketQuote] {
        guard !securities.isEmpty else { return [] }
        let connection = session()
        defer { connection.invalidateAndCancel() }
        let expiresAt = Date().addingTimeInterval(28)
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 28_000_000_000)
            if !Task.isCancelled { connection.invalidateAndCancel() }
        }
        defer { deadline.cancel() }
        return await fetchQuoteUniverse(securities, session: connection, expiresAt: expiresAt).quotes
    }
    static func fetchMembers(_ index: MarketIndex, session: URLSession) async throws -> [SecurityID] {
        let base = "https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/Market_Center."
        async let countData = get(url(base + "getHQNodeStockCount", ["node": index.node]), session: session)
        async let listData = get(url(base + "getHQNodeDataSimple", ["page": "1", "num": "3000", "sort": "symbol", "asc": "1", "node": index.node, "_s_r_a": "setlen"]), session: session)
        let (count, list) = try await (countData, listData)
        let text = String(data: count, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t")) ?? ""
        guard let expected = Int(text) else { throw FeedError(message: "无法确认成分股数量") }
        return try MarketParsing.members(list, expected: expected, index: index)
    }
    static func fetchAll() async -> [MarketResult] {
        let connection = session()
        defer { connection.invalidateAndCancel() }
        let expiresAt = Date().addingTimeInterval(28)
        // 到总时限取消在途请求，但仍返回已成功的指数和完整范围。
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 28_000_000_000)
            if !Task.isCancelled { connection.invalidateAndCancel() }
        }
        defer { deadline.cancel() }
        return await fetchAll(session: connection, expiresAt: expiresAt)
    }
    static func fetchAll(session: URLSession, expiresAt: Date) async -> [MarketResult] {
        var members: [MarketIndex: [SecurityID]] = [:]
        var errors: [MarketIndex: String] = [:]
        async let indexQuotes = fetchQuoteBatch(MarketIndex.allCases.map(\.security), session: session)
        await withTaskGroup(of: (MarketIndex, [SecurityID]?, String?).self) { group in
            for index in MarketIndex.allCases {
                group.addTask {
                    do { return (index, try await fetchMembers(index, session: session), nil) }
                    catch { return (index, nil, failureDescription(error)) }
                }
            }
            for await (index, codes, error) in group { members[index] = codes; errors[index] = error }
        }
        let universe = Set(members.values.flatMap { $0 }).sorted { $0.id < $1.id }
        let batch = await fetchQuoteUniverse(universe, session: session, expiresAt: expiresAt)
        let quotes = Dictionary(uniqueKeysWithValues: batch.quotes.map { ($0.security, $0) })
        let indices = await indexQuotes
        let indexMap = Dictionary(uniqueKeysWithValues: indices.quotes.filter { $0.updatedAt != nil && $0.price != nil && $0.percent != nil }.map { ($0.security, $0) })
        return MarketIndex.allCases.map { index in
            let quote = indexMap[index.security]
            guard let codes = members[index] else { return MarketResult(index: index, snapshot: nil, error: "成分股查询失败：\(errors[index] ?? "未知错误")", failedCodes: [], indexQuote: quote) }
            let missing = codes.filter { quotes[$0] == nil }.map(\.id)
            guard missing.isEmpty else {
                return MarketResult(index: index, snapshot: nil, error: "\(missing.count)/\(codes.count) 只成分股行情未获取：\(batch.error ?? "响应不完整")", failedCodes: missing, indexQuote: quote)
            }
            guard let quote = quote else {
                return MarketResult(index: index, snapshot: nil, error: "指数行情查询失败：\(indices.error ?? "关键行情字段缺失")", failedCodes: [index.security.id])
            }
            return MarketResult(index: index, snapshot: MarketSnapshot(index: index, quote: quote, stocks: codes.compactMap { quotes[$0] }, memberCount: codes.count, fetchedAt: Date()), error: nil, failedCodes: [], indexQuote: quote)
        }
    }
    static func fetchDetail(_ security: SecurityID) async throws -> StockDetail {
        let connection = session()
        defer { connection.finishTasksAndInvalidate() }
        let data = try await get(url("https://push2.eastmoney.com/api/qt/stock/get", ["secid": security.id, "fltt": "2", "invt": "2", "fields": "f43,f44,f45,f46,f47,f48,f50,f57,f58,f60,f116,f117,f137,f162,f167,f168,f169,f170,f86"]), session: connection)
        return try MarketParsing.detail(data, security: security)
    }
    static func fetchHistory(_ security: SecurityID) async throws -> [DailyClose] {
        let connection = session()
        defer { connection.finishTasksAndInvalidate() }
        let data = try await get(url("https://push2his.eastmoney.com/api/qt/stock/kline/get", ["secid": security.id, "klt": "101", "fqt": "1", "lmt": "60", "end": "20500101", "fields1": "f1,f2,f3,f4,f5,f6", "fields2": "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"]), session: connection)
        return try MarketParsing.history(data, security: security)
    }
}

import Foundation

enum PriceChartPeriod: String, CaseIterable, Identifiable {
    case intraday, day, week, month
    var id: String { rawValue }
    var title: String { switch self { case .intraday: return "分时"; case .day: return "日K"; case .week: return "周K"; case .month: return "月K" } }
    var tencent: String { switch self { case .intraday: return "minute"; case .day: return "day"; case .week: return "week"; case .month: return "month" } }
    var eastmoney: String { switch self { case .intraday: return "1"; case .day: return "101"; case .week: return "102"; case .month: return "103" } }
}

extension SecurityID {
    var tencentSymbol: String { (market == 1 ? "sh" : (marketName == "京" ? "bj" : "sz")) + code }
}

struct PriceBar: Identifiable, Equatable {
    let label: String
    let date: Date
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
    var id: String { label }
}

struct PriceChartData {
    let security: SecurityID
    let bars: [PriceBar]
    let period: PriceChartPeriod
    let previousClose: Double?
    let source: String
    let adjustment: String
    var lastTime: Date? { bars.last?.date }
}

struct FundIdentity: Identifiable, Equatable {
    let code: String
    let name: String
    let type: String
    var id: String { "fund-nav:" + code }
}
struct FundNAV: Identifiable, Equatable {
    let day: String
    let date: Date
    let unit: Double
    let accumulated: Double?
    let percent: Double?
    var id: String { day }
}
struct FundHistory {
    let fund: FundIdentity
    let values: [FundNAV]
}

enum ChartParsing {
    static func number(_ value: Any?) -> Double? {
        let n: Double?
        if let s = value as? String { n = Double(s) }
        else if let v = value as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID() { n = v.doubleValue }
        else { n = nil }
        return n.flatMap { $0.isFinite ? $0 : nil }
    }
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = ChinaClock.calendar.timeZone
        f.dateFormat = format; f.isLenient = false; return f
    }
    static func checkedDate(_ text: String, formatter: DateFormatter) -> Date? {
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }; return date
    }
    static func bar(_ row: [Any], formatter: DateFormatter) -> PriceBar? {
        guard row.count >= 6, let label = row[0] as? String, let date = checkedDate(label, formatter: formatter),
              let o = number(row[1]), let c = number(row[2]), let h = number(row[3]), let l = number(row[4]), let v = number(row[5]),
              min(o, c, h, l) > 0, h >= max(o, c), l <= min(o, c), h >= l, v >= 0 else { return nil }
        return PriceBar(label: label, date: date, open: o, close: c, high: h, low: l, volume: v)
    }
    static func unique(_ bars: [PriceBar]) -> [PriceBar] {
        var seen = Set<String>(); return bars.sorted { $0.date < $1.date }.filter { seen.insert($0.label).inserted }
    }
    static func tencent(_ data: Data, security: SecurityID, period: PriceChartPeriod) throws -> PriceChartData {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["code"] as? Int == 0,
              let table = root["data"] as? [String: Any], let block = table[security.tencentSymbol] as? [String: Any] else { throw FeedError(message: "图表证券或响应不匹配") }
        if period == .intraday {
            guard let group = block["data"] as? [String: Any], let day = group["date"] as? String,
                  let rows = group["data"] as? [String], let qt = block["qt"] as? [String: Any],
                  let quote = qt[security.tencentSymbol] as? [String], quote.count > 4, quote[2] == security.code else { throw FeedError(message: "分时日期或证券不匹配") }
            let f = formatter("yyyyMMdd HHmm")
            var prior = 0.0
            var bars: [PriceBar] = []
            for row in rows {
                let cols = row.split(separator: " ").map(String.init)
                guard cols.count >= 3, let date = checkedDate(day + " " + cols[0], formatter: f),
                      let price = number(cols[1]), price > 0, let cumulative = number(cols[2]), cumulative >= prior else { continue }
                let time = ChinaClock.calendar.dateComponents([.hour, .minute], from: date)
                let m = (time.hour ?? 0) * 60 + (time.minute ?? 0)
                guard (570...690).contains(m) || (780...900).contains(m) else { continue }
                bars.append(PriceBar(label: day + " " + cols[0], date: date, open: price, close: price, high: price, low: price, volume: cumulative - prior))
                prior = cumulative
            }
            guard !bars.isEmpty else { throw FeedError(message: "暂无分时成交数据") }
            return PriceChartData(security: security, bars: unique(bars), period: period, previousClose: number(quote[4]), source: "腾讯财经", adjustment: "实际成交价")
        }
        let adjusted = block["qfq" + period.tencent] as? [[Any]]
        guard let rows = adjusted ?? block[period.tencent] as? [[Any]] else { throw FeedError(message: "暂无K线数据") }
        let f = formatter("yyyy-MM-dd")
        let bars = unique(rows.compactMap { bar($0, formatter: f) })
        guard !bars.isEmpty else { throw FeedError(message: "K线字段无效") }
        return PriceChartData(security: security, bars: Array(bars.suffix(120)), period: period, previousClose: nil, source: "腾讯财经", adjustment: adjusted != nil ? "前复权" : "不复权")
    }
    static func eastmoney(_ data: Data, security: SecurityID, period: PriceChartPeriod) throws -> PriceChartData {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["rc"] as? Int == 0,
              let block = root["data"] as? [String: Any], block["code"] as? String == security.code,
              let rows = block[period == .intraday ? "trends" : "klines"] as? [String] else { throw FeedError(message: "备用图表证券或响应不匹配") }
        let f = formatter(period == .intraday ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd")
        let bars = unique(rows.compactMap { row -> PriceBar? in
            let values = row.components(separatedBy: ",")
            return bar(values, formatter: f)
        })
        guard !bars.isEmpty else { throw FeedError(message: "暂无有效图表数据") }
        return PriceChartData(security: security, bars: bars, period: period, previousClose: number(block["preClose"]), source: "东方财富", adjustment: period == .intraday ? "实际成交价" : "前复权")
    }
    static func funds(_ data: Data) throws -> [FundIdentity] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["ErrCode"] as? Int == 0,
              let rows = root["Datas"] as? [[String: Any]] else { throw FeedError(message: "基金搜索暂不可用") }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let code = row["CODE"] as? String, validFundCode(code), row["CATEGORY"] as? Int == 700,
                  let name = row["NAME"] as? String, !name.isEmpty, let info = row["FundBaseInfo"] as? [String: Any],
                  let type = info["FTYPE"] as? String, !type.contains("货币"), seen.insert(code).inserted else { return nil }
            return FundIdentity(code: code, name: name, type: type)
        }
    }
    static func validFundCode(_ code: String) -> Bool { code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber } }
    /// 只提取指定变量的 JSON 常量，不执行上游 JavaScript。
    static func variable(_ name: String, in source: String) throws -> Any {
        let pattern = #"\bvar\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*([^;]+);"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source), let data = source[range].data(using: .utf8) else { throw FeedError(message: "净值数据字段未公布") }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
    static func fundHistory(_ data: Data, fund: FundIdentity) throws -> FundHistory {
        guard data.count < 8_000_000, let source = String(data: data, encoding: .utf8),
              try variable("fS_code", in: source) as? String == fund.code,
              let rows = try variable("Data_netWorthTrend", in: source) as? [[String: Any]] else { throw FeedError(message: "基金代码或净值字段不匹配") }
        let accRows = (try? variable("Data_ACWorthTrend", in: source)) as? [[Any]] ?? []
        var accumulated: [String: Double] = [:]
        let f = formatter("yyyy-MM-dd")
        for row in accRows where row.count >= 2 {
            if let t = number(row[0]), let value = number(row[1]), value > 0 {
                accumulated[f.string(from: Date(timeIntervalSince1970: t / 1000))] = value
            }
        }
        var seen = Set<String>()
        let values = rows.compactMap { row -> FundNAV? in
            guard let t = number(row["x"]), t > 0, let value = number(row["y"]), value > 0 else { return nil }
            let date = Date(timeIntervalSince1970: t / 1000), day = f.string(from: date)
            guard seen.insert(day).inserted else { return nil }
            return FundNAV(day: day, date: date, unit: value, accumulated: accumulated[day], percent: number(row["equityReturn"]))
        }.sorted { $0.date < $1.date }
        guard !values.isEmpty else { throw FeedError(message: "暂无已公布净值；货币基金收益暂不支持") }
        return FundHistory(fund: fund, values: values)
    }
}

import CoreFoundation

enum DetailChartAPI {
    static func get(_ url: URL, session: URLSession, referer: String = "https://gu.qq.com/") async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000 else { throw FeedError(message: "图表接口响应无效") }
        return data
    }
    static func chart(_ security: SecurityID, period: PriceChartPeriod) async throws -> PriceChartData {
        let session = MarketAPI.session()
        let deadline = Task { try? await Task.sleep(nanoseconds: 18_000_000_000); if !Task.isCancelled { session.invalidateAndCancel() } }
        defer { deadline.cancel(); session.invalidateAndCancel() }
        return try await fetchChart(security, period: period, session: session)
    }
    static func fetchChart(_ security: SecurityID, period: PriceChartPeriod, session: URLSession) async throws -> PriceChartData {
        do {
            let url = period == .intraday
                ? MarketAPI.url("https://web.ifzq.gtimg.cn/appstock/app/minute/query", ["code": security.tencentSymbol])
                : MarketAPI.url("https://web.ifzq.gtimg.cn/appstock/app/fqkline/get", ["param": "\(security.tencentSymbol),\(period.tencent),,,120,qfq"])
            return try ChartParsing.tencent(await get(url, session: session), security: security, period: period)
        } catch { try Task.checkCancellation() }
        let params = period == .intraday
            ? ["secid": security.id, "ndays": "1", "iscr": "0", "fields1": "f1,f2,f3,f4,f5,f6,f7,f8", "fields2": "f51,f52,f53,f54,f55,f56,f57,f58"]
            : ["secid": security.id, "klt": period.eastmoney, "fqt": "1", "lmt": "120", "end": "20500101", "fields1": "f1,f2,f3,f4,f5,f6", "fields2": "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"]
        let path = period == .intraday ? "trends2" : "kline"
        return try ChartParsing.eastmoney(await get(MarketAPI.url("https://push2his.eastmoney.com/api/qt/stock/\(path)/get", params), session: session, referer: "https://quote.eastmoney.com/"), security: security, period: period)
    }
    static func searchFunds(_ query: String) async throws -> [FundIdentity] {
        let session = MarketAPI.session(); defer { session.invalidateAndCancel() }
        return try ChartParsing.funds(await get(MarketAPI.url("https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx", ["m": "1", "key": query]), session: session, referer: "https://fund.eastmoney.com/"))
    }
    static func fundHistory(_ fund: FundIdentity) async throws -> FundHistory {
        guard ChartParsing.validFundCode(fund.code) else { throw FeedError(message: "基金代码无效") }
        let session = MarketAPI.session(); defer { session.invalidateAndCancel() }
        return try ChartParsing.fundHistory(await get(URL(string: "https://fund.eastmoney.com/pingzhongdata/\(fund.code).js?v=\(Int(Date().timeIntervalSince1970 / 60))")!, session: session, referer: "https://fund.eastmoney.com/"), fund: fund)
    }
}

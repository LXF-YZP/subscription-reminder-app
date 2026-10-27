import Foundation

struct TradingCalendarYear: Codable {
    let year: Int
    let closedDays: Set<String>
    let source: String
    let fetchedAt: Date
}

/// 交易所周末始终休市，不采用行政调休工作日规则。未知年份明确回退到周末规则。
enum TradingCalendar {
    static let source = "https://www.sse.com.cn/disclosure/dealinstruc/closed/"
    private static let lock = NSLock()
    private static var years: [Int: TradingCalendarYear] = [2026: builtIn2026]
    static let builtIn2026: TradingCalendarYear = {
        let ranges = [("01-01", "01-03"), ("02-15", "02-23"), ("04-04", "04-06"),
                      ("05-01", "05-05"), ("06-19", "06-21"), ("09-25", "09-27"), ("10-01", "10-07")]
        var days = Set<String>()
        for (start, end) in ranges {
            var date = MarketParsing.date("2026-" + start)!
            let last = MarketParsing.date("2026-" + end)!
            while date <= last {
                days.insert(ChinaClock.day(date))
                date = ChinaClock.calendar.date(byAdding: .day, value: 1, to: date)!
            }
        }
        return TradingCalendarYear(year: 2026, closedDays: days, source: source,
                                   fetchedAt: MarketParsing.date("2026-10-22")!)
    }()
    static func schedule(for date: Date) -> TradingCalendarYear? {
        lock.lock(); defer { lock.unlock() }
        return years[ChinaClock.calendar.component(.year, from: date)]
    }
    static func install(_ value: TradingCalendarYear) throws {
        guard (2020...2100).contains(value.year), (10...50).contains(value.closedDays.count),
              value.source == source, value.closedDays.allSatisfy({
                  $0.hasPrefix("\(value.year)-") && MarketParsing.date($0) != nil
              }) else { throw FeedError(message: "交易日历不完整，保留原日历") }
        lock.lock(); defer { lock.unlock() }
        years[value.year] = value
    }
    static func isTradingDay(_ date: Date) -> Bool {
        !ChinaClock.isWeekend(date) && !(schedule(for: date)?.closedDays.contains(ChinaClock.day(date)) ?? false)
    }
    static func isTradingTime(_ date: Date) -> Bool {
        guard isTradingDay(date) else { return false }
        let minute = ChinaClock.calendar.component(.hour, from: date) * 60 + ChinaClock.calendar.component(.minute, from: date)
        return (570..<690).contains(minute) || (780..<900).contains(minute)
    }
    static func status(at date: Date = Date()) -> String {
        let day = isTradingDay(date) ? "交易日" : "休市日"
        return schedule(for: date).map { "\(day) · \($0.year)年交易所日历" } ?? "\(day) · 当年日历未确认，暂按周末规则"
    }
    static func parse(_ data: Data, at date: Date = Date()) throws -> TradingCalendarYear {
        guard let html = String(data: data, encoding: .utf8) else { throw FeedError(message: "交易日历编码异常") }
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+|&nbsp;", with: "", options: .regularExpression)
        let yearPattern = try NSRegularExpression(pattern: "([0-9]{4})年休市安排")
        guard let match = yearPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let year = Int(text[range]),
              let bodyStart = Range(match.range, in: text)?.upperBound else { throw FeedError(message: "未找到年度交易日历") }
        let body = String(text[bodyStart...].components(separatedBy: "相关公告")[0])
        var days = Set<String>()
        for name in ["元旦", "春节", "清明节", "劳动节", "端午节", "中秋节", "国庆节"] {
            let expression = try NSRegularExpression(pattern: name + "[：:]([0-9]{1,2})月([0-9]{1,2})日(?:[（(][^）)]*[）)])?(?:至([0-9]{1,2})月([0-9]{1,2})日(?:[（(][^）)]*[）)])?)?休市")
            guard let m = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else {
                throw FeedError(message: "交易日历缺少\(name)安排，保留原日历")
            }
            func number(_ index: Int) -> Int? { Range(m.range(at: index), in: body).flatMap { Int(body[$0]) } }
            guard let month = number(1), let day = number(2),
                  let first = MarketParsing.date(String(format: "%04d-%02d-%02d", year, month, day)),
                  let last = MarketParsing.date(String(format: "%04d-%02d-%02d", year, number(3) ?? month, number(4) ?? day)),
                  last >= first, last.timeIntervalSince(first) <= 15 * 86400 else { throw FeedError(message: "交易日历日期异常") }
            var cursor = first
            while cursor <= last {
                days.insert(ChinaClock.day(cursor))
                cursor = ChinaClock.calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
        }
        return TradingCalendarYear(year: year, closedDays: days, source: source, fetchedAt: date)
    }
    static func refresh(directory: URL) async throws -> TradingCalendarYear {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let data = try await MarketAPI.get(URL(string: source)!, session: session)
        let value = try parse(data)
        try install(value)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("trading-calendar.json"), options: .atomic)
        return value
    }
    static func load(directory: URL) {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("trading-calendar.json")),
           let value = try? JSONDecoder().decode(TradingCalendarYear.self, from: data) { try? install(value) }
    }
}

enum PriceAlertKind: String, Codable, CaseIterable, Identifiable {
    case priceAbove, priceBelow, percentAbove, percentBelow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .priceAbove: return "价格达到或超过"
        case .priceBelow: return "价格达到或低于"
        case .percentAbove: return "当日涨幅达到"
        case .percentBelow: return "当日跌幅达到"
        }
    }
    var isPercent: Bool { self == .percentAbove || self == .percentBelow }
}

struct PriceAlertRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let security: SecurityID
    let name: String
    let kind: PriceAlertKind
    let threshold: Double
    var enabled = true
    var token: String { "price:\(id)" }
    var summary: String { "\(kind.title) \(MarketText.number(threshold))\(kind.isPercent ? "%" : "元")" }
    var isValid: Bool {
        UUID(uuidString: id) != nil && SecurityID.parse(security.id) != nil && !name.isEmpty && name.count <= 60 &&
        threshold.isFinite && threshold > 0 && threshold <= (kind.isPercent ? 100 : 1_000_000)
    }
    func matches(_ quote: MarketQuote, at date: Date) -> Bool {
        guard enabled, isValid, quote.security == security, TradingCalendar.isTradingTime(date),
              let time = quote.updatedAt, ChinaClock.day(time) == ChinaClock.day(date),
              (-60...360).contains(date.timeIntervalSince(time)), let price = quote.price, price > 0 else { return false }
        switch kind {
        case .priceAbove: return price >= threshold
        case .priceBelow: return price <= threshold
        case .percentAbove: return quote.percent.map { $0 >= threshold } ?? false
        case .percentBelow: return quote.percent.map { $0 <= -threshold } ?? false
        }
    }
}

enum PaymentFollowUp {
    static func slot(at date: Date) -> String? {
        guard TradingCalendar.isTradingDay(date) else { return nil }
        let minute = ChinaClock.calendar.component(.hour, from: date) * 60 + ChinaClock.calendar.component(.minute, from: date)
        guard (885..<960).contains(minute) else { return nil }
        return "\(ChinaClock.day(date))@\(minute >= 930 ? "15:30" : "14:45")"
    }
    static func pending(state: AppState, at date: Date) -> [Issue] {
        guard let slot = slot(at: date) else { return [] }
        let sent = Set(state.sent[slot] ?? [])
        return state.todayPayment(at: date).filter {
            state.wonIssues.contains($0.id) && !state.paidIssues.contains($0.id) && !sent.contains("payment-followup:\($0.id)")
        }
    }
    static func status(_ issue: Issue, state: AppState, at date: Date = Date()) -> String? {
        if state.paidIssues.contains(issue.id) { return "已缴款" }
        guard state.wonIssues.contains(issue.id) else { return nil }
        guard issue.paymentDate == ChinaClock.day(date) else { return "已中签 · 待缴款" }
        let deadline = ChinaClock.calendar.startOfDay(for: date).addingTimeInterval(16 * 3600)
        let minutes = Int(ceil(deadline.timeIntervalSince(date) / 60))
        return minutes > 0 ? "已中签 · 距16:00约\(minutes)分钟（以券商截止时间为准）" : "已中签 · 请立即核实缴款结果"
    }
}

struct MarketHealthState: Codable, Equatable {
    var day = ""
    var failures = 0
    var episode: String?
    var recoveredEpisode: String?
    /// 午休不累计延迟，下午开盘不会将正常的11:30行情立刻判为异常。
    static func delay(latest: Date?, at date: Date) -> TimeInterval {
        let start = ChinaClock.calendar.startOfDay(for: date)
        let reference = max(latest ?? start, start.addingTimeInterval(570 * 60))
        return [(570.0, 690.0), (780.0, 900.0)].reduce(0) { result, interval in
            let from = max(reference, start.addingTimeInterval(interval.0 * 60))
            let to = min(date, start.addingTimeInterval(interval.1 * 60))
            return result + max(0, to.timeIntervalSince(from))
        }
    }
    mutating func observe(success: Bool, latest: Date?, at date: Date) {
        guard TradingCalendar.isTradingTime(date) else { return }
        resetDay(at: date)
        failures = success ? 0 : failures + 1
        update(success: success, latest: latest, at: date)
    }
    mutating func checkDelay(latest: Date?, at date: Date) {
        guard TradingCalendar.isTradingTime(date), day == ChinaClock.day(date) else { return }
        update(success: false, latest: latest, at: date)
    }
    private mutating func resetDay(at date: Date) {
        if day != ChinaClock.day(date) { self = MarketHealthState(); day = ChinaClock.day(date) }
    }
    private mutating func update(success: Bool, latest: Date?, at date: Date) {
        if failures >= 3 || Self.delay(latest: latest, at: date) >= 15 * 60 {
            if episode == nil { episode = UUID().uuidString; recoveredEpisode = nil }
        } else if success, latest != nil, let episode = episode {
            recoveredEpisode = episode; self.episode = nil
        }
    }

}

/// 备份只包含个人设置，不导入旧行情、通知去重或机器上的应用路径。
struct SettingsBackup: Codable {
    let format: String
    let version: Int
    let createdAt: Date
    let favorites: [SecurityID]
    let favoriteQuotes: [MarketQuote]
    let markedApplications: Set<String>
    let wonIssues: Set<String>
    let paidIssues: Set<String>
    let trackedIssues: [Issue]
    let notifyWhenEmpty: Bool
    let onlyMarkedForPayment: Bool
    let onlyMarkedForListing: Bool
    let notifyMarketHealth: Bool
    let priceAlerts: [PriceAlertRule]

    init(state: AppState, favorites: [SecurityID], quotes: [MarketQuote], at date: Date = Date()) {
        format = "SubscriptionReminderSettings"; version = 1; createdAt = date
        self.favorites = favorites; favoriteQuotes = quotes.filter { favorites.contains($0.security) }
        markedApplications = state.markedApplications; wonIssues = state.wonIssues; paidIssues = state.paidIssues
        trackedIssues = state.knownIssues.filter { state.markedApplications.contains($0.id) }
        notifyWhenEmpty = state.notifyWhenEmpty; onlyMarkedForPayment = state.onlyMarkedForPayment
        onlyMarkedForListing = state.onlyMarkedForListing; notifyMarketHealth = state.notifyMarketHealth
        priceAlerts = state.priceAlerts
    }
    static func decode(_ data: Data) throws -> SettingsBackup {
        guard data.count <= 2_000_000 else { throw FeedError(message: "备份文件超过2MB，请选择申购提醒导出的设置备份") }
        let value = try JSONDecoder().decode(SettingsBackup.self, from: data)
        try value.validate(); return value
    }
    func validate() throws {
        func validIssue(_ id: String) -> Bool {
            let pieces = id.split(separator: ":")
            return pieces.count == 3 && IssueKind(rawValue: String(pieces[0])) != nil &&
                MarketParsing.date(String(pieces[1])) != nil && pieces[2].count == 6 && pieces[2].allSatisfy { $0.isASCII && $0.isNumber }
        }
        guard format == "SubscriptionReminderSettings", version == 1, favorites.count <= 1000,
              favorites.allSatisfy({ SecurityID.parse($0.id) != nil }), Set(favorites).count == favorites.count,
              favoriteQuotes.count <= favorites.count, Set(favoriteQuotes.map(\.security)).count == favoriteQuotes.count,
              favoriteQuotes.allSatisfy({ favorites.contains($0.security) && !$0.name.isEmpty && $0.name.count <= 60 }),
              markedApplications.count <= 5000, markedApplications.allSatisfy(validIssue),
              wonIssues.isSubset(of: markedApplications), paidIssues.isSubset(of: wonIssues),
              trackedIssues.count <= markedApplications.count, Set(trackedIssues.map(\.id)).count == trackedIssues.count,
              trackedIssues.allSatisfy({ markedApplications.contains($0.id) && validIssue($0.id) && !$0.name.isEmpty && $0.name.count <= 60 }),
              priceAlerts.count <= 500, Set(priceAlerts.map(\.id)).count == priceAlerts.count,
              priceAlerts.allSatisfy({ $0.isValid && favorites.contains($0.security) }) else {
            throw FeedError(message: "备份格式或数据校验失败，原设置保持不变")
        }
    }
    func applying(to current: AppState) -> AppState {
        var state = current
        state.markedApplications = markedApplications; state.wonIssues = wonIssues; state.paidIssues = paidIssues
        state.trackedIssues = trackedIssues
        state.notifyWhenEmpty = notifyWhenEmpty; state.onlyMarkedForPayment = onlyMarkedForPayment
        state.onlyMarkedForListing = onlyMarkedForListing; state.notifyMarketHealth = notifyMarketHealth
        state.priceAlerts = priceAlerts
        return state
    }
    func restore(to directory: URL, current: AppState, write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> AppState {
        try validate()
        let updated = applying(to: current)
        let files: [(String, Data)] = [
            ("market-preferences.json", try JSONEncoder().encode(favorites)),
            ("favorite-quotes.json", try JSONEncoder().encode(favoriteQuotes)),
            ("state.json", try JSONEncoder().encode(updated))]
        let old = try files.map { name, _ -> (URL, Data?) in
            let url = directory.appendingPathComponent(name)
            return (url, FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        do { for (name, data) in files { try write(data, directory.appendingPathComponent(name)) } }
        catch {
            var rollbackFailed = false
            for (url, data) in old {
                do {
                    if let data = data { try data.write(to: url, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw FeedError(message: "恢复中断，部分文件回滚失败。请从 Backups 中的恢复前备份重新恢复，并检查磁盘可写状态。") }
            throw error
        }
        return updated
    }
}

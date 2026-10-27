import Foundation

enum ChinaClock {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    static func day(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }
    static func isWeekend(_ date: Date = Date()) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }
    static func dueSlot(at date: Date) -> String? {
        guard TradingCalendar.isTradingDay(date) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // 午间开机补上午提醒；收盘后不补发“可以申购”的通知。
        guard minute >= 570, minute < 900 else { return nil }
        return "\(day(date))@\(minute >= 870 ? "14:30" : "09:30")"
    }
    static func isClosed(at date: Date = Date()) -> Bool {
        (calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)) >= 900
    }
    static func addingDays(_ days: Int, to date: Date = Date()) -> String {
        day(calendar.date(byAdding: .day, value: days, to: date) ?? date)
    }
}

enum ActivityLogFile {
    static func append(_ message: String, to directory: URL, at date: Date = Date(), maxBytes: Int = 512_000) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("activity.log")
        let archived = directory.appendingPathComponent("activity.1.log")
        let line = Data("\(ChinaClock.timestamp(date)) \(message)\n".utf8)
        let existing = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if existing > 0 && existing + line.count > maxBytes {
            try? manager.removeItem(at: archived)
            try manager.moveItem(at: current, to: archived)
        }
        if !manager.fileExists(atPath: current.path) { manager.createFile(atPath: current.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

enum IssueKind: String, Codable, CaseIterable {
    case stock, bond
    var label: String { self == .stock ? "新股" : "可转债" }
    var report: String { self == .stock ? "RPTA_APP_IPOAPPLY" : "RPT_BOND_CB_LIST" }
    var dateField: String { self == .stock ? "APPLY_DATE" : "PUBLIC_START_DATE" }
    var columns: String {
        self == .stock
        ? "SECURITY_CODE,SECURITY_NAME,APPLY_CODE,APPLY_DATE,ISSUE_PRICE,ONLINE_APPLY_UPPER,MARKET_TYPE_NEW,IS_BEIJING,BALLOT_PAY_DATE,LISTING_DATE,SELECT_LISTING_DATE"
        : "SECURITY_CODE,SECURITY_NAME_ABBR,CORRECODE,CORRECODE_NAME_ABBR,PUBLIC_START_DATE,ISSUE_PRICE,RATING,BOND_START_DATE,LISTING_DATE"
    }
}

struct Issue: Codable, Equatable {
    let kind: IssueKind
    let name: String
    let securityCode: String
    let applyCode: String
    let applyDate: String
    let price: Double?
    let market: String
    let upperLimit: Int?
    let paymentDate: String?
    let listingDate: String?
    var id: String { "\(kind.rawValue):\(applyDate):\(applyCode)" }
    var priceText: String {
        guard let price = price, price > 0 else { return "待公布" }
        return String(format: "%.2f 元", price)
    }
}

struct FeedSnapshot: Codable, Equatable {
    let kind: IssueKind
    let fetchedAt: Date
    let issues: [Issue]
}

struct FeedResult {
    let kind: IssueKind
    let snapshot: FeedSnapshot?
    let error: String?
}

/// 只比较日历内容，抓取时间变化不构成新的成功日志。
struct QueryLogTracker {
    private var lastSucceeded: [IssueKind: Bool] = [:]
    private var lastIssues: [IssueKind: [Issue]] = [:]

    mutating func message(for result: FeedResult) -> String? {
        guard let snapshot = result.snapshot else {
            lastSucceeded[result.kind] = false
            return "\(result.kind.label)查询失败：\(result.error ?? "未知")"
        }
        let first = lastIssues[result.kind] == nil
        let recovered = lastSucceeded[result.kind] == false
        let changed = lastIssues[result.kind] != snapshot.issues
        lastIssues[result.kind] = snapshot.issues
        lastSucceeded[result.kind] = true
        guard first || recovered || changed else { return nil }
        let reason = recovered ? "从失败恢复" : (first ? "首次成功" : "结果变化")
        return "\(result.kind.label)查询成功（\(reason)），\(snapshot.issues.count) 条申购日历"
    }
}

struct AppState: Codable {
    var feeds: [FeedSnapshot] = []
    var sent: [String: [String]] = [:]
    var notifyWhenEmpty = false
    var thsPath: String?
    var markedApplications: Set<String> = []
    var onlyMarkedForPayment = false
    var onlyMarkedForListing = false
    var permissionLogKeys: Set<String> = []
    var wonIssues: Set<String> = []
    var paidIssues: Set<String> = []
    var priceAlerts: [PriceAlertRule] = []
    var notifyMarketHealth = true
    var marketHealth = MarketHealthState()
    var trackedIssues: [Issue] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try container.decodeIfPresent([FeedSnapshot].self, forKey: .feeds) ?? []
        sent = try container.decodeIfPresent([String: [String]].self, forKey: .sent) ?? [:]
        notifyWhenEmpty = try container.decodeIfPresent(Bool.self, forKey: .notifyWhenEmpty) ?? false
        thsPath = try container.decodeIfPresent(String.self, forKey: .thsPath)
        markedApplications = try container.decodeIfPresent(Set<String>.self, forKey: .markedApplications) ?? []
        onlyMarkedForPayment = try container.decodeIfPresent(Bool.self, forKey: .onlyMarkedForPayment) ?? false
        onlyMarkedForListing = try container.decodeIfPresent(Bool.self, forKey: .onlyMarkedForListing) ?? false
        permissionLogKeys = try container.decodeIfPresent(Set<String>.self, forKey: .permissionLogKeys) ?? []
        wonIssues = try container.decodeIfPresent(Set<String>.self, forKey: .wonIssues) ?? []
        paidIssues = try container.decodeIfPresent(Set<String>.self, forKey: .paidIssues) ?? []
        priceAlerts = try container.decodeIfPresent([PriceAlertRule].self, forKey: .priceAlerts) ?? []
        notifyMarketHealth = try container.decodeIfPresent(Bool.self, forKey: .notifyMarketHealth) ?? true
        marketHealth = try container.decodeIfPresent(MarketHealthState.self, forKey: .marketHealth) ?? MarketHealthState()
        trackedIssues = try container.decodeIfPresent([Issue].self, forKey: .trackedIssues) ?? []
    }
    mutating func put(_ snapshot: FeedSnapshot) {
        feeds.removeAll { $0.kind == snapshot.kind }
        feeds.append(snapshot)
        for issue in snapshot.issues where markedApplications.contains(issue.id) {
            trackedIssues.removeAll { $0.id == issue.id }; trackedIssues.append(issue)
        }
    }
    var knownIssues: [Issue] {
        var values = Dictionary(trackedIssues.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for issue in feeds.flatMap(\.issues) { values[issue.id] = issue }
        return values.values.sorted { ($0.applyDate, $0.id) > ($1.applyDate, $1.id) }
    }
    mutating func setApplied(_ id: String, _ applied: Bool) {
        if applied {
            markedApplications.insert(id)
            if let issue = knownIssues.first(where: { $0.id == id }) {
                trackedIssues.removeAll { $0.id == id }; trackedIssues.append(issue)
            }
        } else {
            markedApplications.remove(id); wonIssues.remove(id); paidIssues.remove(id)
            trackedIssues.removeAll { $0.id == id }
        }
    }
    mutating func setWon(_ id: String, _ won: Bool) {
        if won { setApplied(id, true); wonIssues.insert(id) }
        else { wonIssues.remove(id); paidIssues.remove(id) }
    }
    mutating func setPaid(_ id: String, _ paid: Bool) {
        if paid { setWon(id, true); paidIssues.insert(id) }
        else { paidIssues.remove(id) }
    }
    func today(at date: Date = Date()) -> [Issue] {
        feeds.flatMap(\.issues).filter { $0.applyDate == ChinaClock.day(date) }
            .sorted { ($0.kind.rawValue, $0.applyCode) < ($1.kind.rawValue, $1.applyCode) }
    }
    func todayPayment(at date: Date = Date()) -> [Issue] {
        feeds.flatMap(\.issues).filter { $0.paymentDate == ChinaClock.day(date) && $0.market != "北交所" }
            .sorted { ($0.kind.rawValue, $0.applyCode) < ($1.kind.rawValue, $1.applyCode) }
    }
    func todayListing(at date: Date = Date()) -> [Issue] {
        feeds.flatMap(\.issues).filter { $0.listingDate == ChinaClock.day(date) }
            .sorted { ($0.kind.rawValue, $0.applyCode) < ($1.kind.rawValue, $1.applyCode) }
    }
    mutating func recordPermissionBlock(slot: String, tokens: [String]) -> Bool {
        var changed = false
        for token in tokens {
            if permissionLogKeys.insert("\(slot)|\(token)").inserted { changed = true }
        }
        return changed
    }
    mutating func prune(at date: Date = Date()) {
        let cutoff = ChinaClock.addingDays(-7, to: date)
        sent = sent.filter { String($0.key.prefix(10)) >= cutoff }
        permissionLogKeys = Set(permissionLogKeys.filter { String($0.prefix(10)) >= cutoff })
    }
}

struct FeedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum IssueAPI {
    static func url(kind: IssueKind, day: String, page: Int, host: String) -> URL {
        var components = URLComponents(string: "https://\(host)/api/data/v1/get")!
        let values = [
            "reportName": kind.report, "columns": kind.columns,
            "sortColumns": kind.dateField, "sortTypes": "1", "pageSize": "100",
            "pageNumber": String(page), "filter": "(\(kind.dateField)>='\(day)')",
            "source": "WEB", "client": "WEB"
        ]
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func parse(_ data: Data, kind: IssueKind) throws -> (issues: [Issue], pages: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedError(message: "数据源返回了无效响应")
        }
        // 公开接口用业务码 9201 表示筛选后没有记录（已用空日期范围核实）。
        if root["code"] as? Int == 9201 && root["message"] as? String == "返回数据为空" {
            return ([], 0)
        }
        guard root["success"] as? Bool == true else {
            throw FeedError(message: root["message"] as? String ?? "数据源返回了无效响应")
        }
        // 缺少 result/data 不能当作“当天没有申购”。
        guard let result = root["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]],
              let pages = result["pages"] as? Int else {
            throw FeedError(message: "数据格式变化，请稍后重试")
        }
        let issues = try rows.compactMap { row -> Issue? in
            func string(_ key: String) -> String? {
                guard let value = row[key] as? String, !value.isEmpty, value != "-" else { return nil }
                return value
            }
            func normalizedDate(_ key: String) -> String? {
                guard let raw = string(key) else { return nil }
                let value = String(raw.prefix(10))
                return validDay(value) ? value : nil
            }
            let nameKey = kind == .stock ? "SECURITY_NAME" : "SECURITY_NAME_ABBR"
            let codeKey = kind == .stock ? "APPLY_CODE" : "CORRECODE"
            guard let name = string(nameKey), let securityCode = string("SECURITY_CODE"),
                  let applyDateRaw = string(kind.dateField) else {
                throw FeedError(message: "申购日历缺少关键字段")
            }
            // 没有公众申购代码的债券不属于网上申购，不使用配债代码替代。
            guard let applyCode = string(codeKey) else {
                if kind == .bond { return nil }
                throw FeedError(message: "新股缺少申购代码")
            }
            guard applyCode.count == 6, applyCode.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw FeedError(message: "申购代码格式异常")
            }
            let day = String(applyDateRaw.prefix(10))
            guard validDay(day) else { throw FeedError(message: "申购日期格式异常") }
            let isBeijing = (row["IS_BEIJING"] as? NSNumber)?.boolValue == true
            let market = kind == .bond ? "可转债" : (isBeijing ? "北交所" : (string("MARKET_TYPE_NEW") ?? "A股"))
            let paymentDate: String?
            let listingDate: String?
            if kind == .stock {
                paymentDate = isBeijing ? nil : normalizedDate("BALLOT_PAY_DATE")
                listingDate = normalizedDate("LISTING_DATE") ?? normalizedDate("SELECT_LISTING_DATE")
            } else {
                paymentDate = normalizedDate("BOND_START_DATE")
                listingDate = normalizedDate("LISTING_DATE")
            }
            return Issue(kind: kind, name: name, securityCode: securityCode,
                         applyCode: applyCode, applyDate: day,
                         price: (row["ISSUE_PRICE"] as? NSNumber)?.doubleValue,
                         market: market, upperLimit: (row["ONLINE_APPLY_UPPER"] as? NSNumber)?.intValue,
                         paymentDate: paymentDate, listingDate: listingDate)
        }
        return (issues, pages)
    }

    private static func validDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ChinaClock.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: value) else { return false }
        return ChinaClock.day(parsed) == value
    }

    static func fetch(_ kind: IssueKind, at date: Date = Date()) async -> FeedResult {
        var lastError = "网络暂不可用"
        let startDay = ChinaClock.addingDays(-45, to: date)
        // 同一公开数据源的两个入口，最多尝试两次，单次请求限制 12 秒。
        for host in ["datacenter-web.eastmoney.com", "datacenter.eastmoney.com"] {
            do {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 12
                config.timeoutIntervalForResource = 18
                let session = URLSession(configuration: config)
                defer { session.finishTasksAndInvalidate() }
                var issues: [Issue] = []
                var page = 1
                var pages = 1
                repeat {
                    var request = URLRequest(url: url(kind: kind, day: startDay, page: page, host: host))
                    request.setValue("Mozilla/5.0 SubscriptionReminder/1.0", forHTTPHeaderField: "User-Agent")
                    request.setValue("https://data.eastmoney.com/", forHTTPHeaderField: "Referer")
                    let (data, response) = try await session.data(for: request)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        throw FeedError(message: "数据源暂时无法访问")
                    }
                    let parsed = try parse(data, kind: kind)
                    pages = parsed.pages
                    guard pages <= 5 else { throw FeedError(message: "日历数据量异常，未确认完整性") }
                    issues.append(contentsOf: parsed.issues)
                    page += 1
                } while page <= pages
                var seen = Set<String>()
                issues = issues.filter { seen.insert($0.id).inserted }.sorted { ($0.applyDate, $0.applyCode) < ($1.applyDate, $1.applyCode) }
                return FeedResult(kind: kind, snapshot: FeedSnapshot(kind: kind, fetchedAt: Date(), issues: issues), error: nil)
            } catch { lastError = error.localizedDescription }
        }
        return FeedResult(kind: kind, snapshot: nil, error: lastError)
    }
    static func fetchAll(at date: Date = Date()) async -> [FeedResult] {
        async let stocks = fetch(.stock, at: date)
        async let bonds = fetch(.bond, at: date)
        return await [stocks, bonds]
    }
}

struct ReminderPlan {
    let category: ReminderCategory
    let slot: String
    let issues: [Issue]
    let complete: Bool
    let tokens: [String]
}

enum ReminderCategory {
    case subscription, payment, listing
}

enum ReminderPlanner {
    static func effectiveSnapshots(state: AppState, results: [FeedResult], at date: Date) -> [IssueKind: FeedSnapshot] {
        let today = ChinaClock.day(date)
        var snapshots: [IssueKind: FeedSnapshot] = [:]
        for kind in IssueKind.allCases {
            if let fetched = results.first(where: { $0.kind == kind })?.snapshot,
               ChinaClock.day(fetched.fetchedAt) == today {
                snapshots[kind] = fetched
            } else if let cached = state.feeds.first(where: { $0.kind == kind && ChinaClock.day($0.fetchedAt) == today }) {
                snapshots[kind] = cached
            }
        }
        return snapshots
    }

    static func hasUsableTodaySnapshot(state: AppState, results: [FeedResult], at date: Date) -> Bool {
        !effectiveSnapshots(state: state, results: results, at: date).isEmpty
    }

    static func plan(state: AppState, results: [FeedResult], at date: Date,
                     category: ReminderCategory = .subscription) -> ReminderPlan? {
        guard let slot = ChinaClock.dueSlot(at: date) else { return nil }
        let snapshots = effectiveSnapshots(state: state, results: results, at: date)
        let complete = snapshots.count == IssueKind.allCases.count
        let sent = Set(state.sent[slot] ?? [])
        let today = ChinaClock.day(date)
        let all = snapshots.values.flatMap(\.issues)
        let issues: [Issue]
        let tokens: (Issue) -> String
        switch category {
        case .subscription:
            issues = all.filter { $0.applyDate == today && !state.markedApplications.contains($0.id) && !sent.contains($0.id) }
            tokens = { $0.id }
        case .payment:
            issues = all.filter {
                $0.paymentDate == today && $0.market != "北交所" && !state.paidIssues.contains($0.id) &&
                (!state.onlyMarkedForPayment || state.markedApplications.contains($0.id)) &&
                !sent.contains("payment:\($0.id)")
            }
            tokens = { "payment:\($0.id)" }
        case .listing:
            issues = all.filter {
                $0.listingDate == today &&
                (!state.onlyMarkedForListing || state.markedApplications.contains($0.id)) &&
                !sent.contains("listing:\($0.id)")
            }
            tokens = { "listing:\($0.id)" }
        }
        if !issues.isEmpty {
            return ReminderPlan(category: category, slot: slot, issues: issues.sorted { $0.id < $1.id }, complete: complete, tokens: issues.map(tokens))
        }
        guard category == .subscription, complete, !sent.contains("empty") else { return nil }
        guard !all.contains(where: { $0.applyDate == today }) else { return nil }
        return ReminderPlan(category: category, slot: slot, issues: [], complete: true, tokens: ["empty"])
    }
}

import Foundation

@main struct CoreTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1
        }
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let morning = date("2026-10-21T01:30:00Z")
        let afternoon = date("2026-10-21T06:30:00Z")
        check(ChinaClock.day(date("2026-10-20T16:01:00Z")) == "2026-10-21", "必须按北京时间跨日")
        check(ChinaClock.timestamp(morning).hasSuffix("+08:00"), "日志时间必须是带 +08:00 的北京时间")
        check(ChinaClock.dueSlot(at: date("2026-10-21T01:29:00Z")) == nil, "9:30 前不可提醒")
        check(ChinaClock.dueSlot(at: morning) == "2026-10-21@09:30", "9:30 应触发")
        check(ChinaClock.dueSlot(at: date("2026-10-21T05:00:00Z")) == "2026-10-21@09:30", "午间启动应补查上午")
        check(ChinaClock.dueSlot(at: afternoon) == "2026-10-21@14:30", "14:30 应再次提醒")
        check(ChinaClock.dueSlot(at: date("2026-10-21T07:00:00Z")) == nil, "15:00 不再补发申购通知")
        check(ChinaClock.dueSlot(at: date("2026-10-24T02:00:00Z")) == nil, "周末不生成申购提醒")
        let bondData = Data(#"{"success":true,"result":{"pages":1,"data":[{"SECURITY_CODE":"127119","SECURITY_NAME_ABBR":"测试转债","CORRECODE":"070887","CORRECODEO":"080887","PUBLIC_START_DATE":"2026-10-21 00:00:00","BOND_START_DATE":"2026-10-21 00:00:00","LISTING_DATE":"2026-10-21 00:00:00","ISSUE_PRICE":100}]}}"#.utf8)
        let bond = try IssueAPI.parse(bondData, kind: .bond).issues[0]
        check(bond.applyCode == "070887", "申购代码应保留前导零，不能误用证券代码或配债代码")
        check(bond.paymentDate == "2026-10-21" && bond.listingDate == "2026-10-21", "可转债缴款日和上市日字段应解析")
        check(bond.marketSecurity == SecurityID(market: 0, code: "127119"), "深市可转债详情应使用行情证券代码")
        let shBond = Issue(kind: .bond, name: "沪市转债", securityCode: "113001", applyCode: "783001",
                           applyDate: "2026-10-20", price: 100, market: "可转债", upperLimit: nil,
                           paymentDate: nil, listingDate: nil)
        check(shBond.marketSecurity == SecurityID(market: 1, code: "113001"), "沪市可转债详情应使用行情证券代码")
        let stockData = Data(#"{"success":true,"result":{"pages":1,"data":[{"SECURITY_CODE":"920306","SECURITY_NAME":"测试新股","APPLY_CODE":"920306","APPLY_DATE":"2026-10-22 00:00:00","ISSUE_PRICE":null,"IS_BEIJING":1,"BALLOT_PAY_DATE":"2026-10-24 00:00:00","SELECT_LISTING_DATE":"2026-10-30 00:00:00"}]}}"#.utf8)
        let stock = try IssueAPI.parse(stockData, kind: .stock).issues[0]
        check(stock.market == "北交所", "需包括北交所")
        check(stock.marketSecurity == SecurityID(market: 0, code: "920306"), "北交所新股详情应使用北交所行情代码")
        check(stock.paymentDate == nil && stock.listingDate == "2026-10-30", "北交所不提醒缴款并解析拟上市日")
        check(stock.priceText == "待公布", "未公布价格不能显示零元")
        let shStockData = Data(#"{"success":true,"result":{"pages":1,"data":[{"SECURITY_CODE":"688999","SECURITY_NAME":"沪市新股","APPLY_CODE":"787999","APPLY_DATE":"2026-10-19 00:00:00","MARKET_TYPE_NEW":"科创板","IS_BEIJING":0,"BALLOT_PAY_DATE":"2026-10-21 00:00:00","LISTING_DATE":"2026-10-28 00:00:00","SELECT_LISTING_DATE":"2026-10-29 00:00:00"}]}}"#.utf8)
        let shStock = try IssueAPI.parse(shStockData, kind: .stock).issues[0]
        check(shStock.marketSecurity == SecurityID(market: 1, code: "688999"), "沪市新股详情应使用沪市行情代码")
        check(shStock.paymentDate == "2026-10-21" && shStock.listingDate == "2026-10-28", "沪深新股使用完整缴款日，上市日优先实际字段")
        let fallbackData = Data(String(data: shStockData, encoding: .utf8)!.replacingOccurrences(of: "2026-10-28", with: "2026-02-30").utf8)
        let fallbackStock = try IssueAPI.parse(fallbackData, kind: .stock).issues[0]
        check(fallbackStock.listingDate == "2026-10-29", "无效上市日期应回退到有效拟上市日")
        let missingDatesData = Data(String(data: shStockData, encoding: .utf8)!.replacingOccurrences(of: "2026-10-21 00:00:00", with: "-03").utf8)
        let missingDateStock = try IssueAPI.parse(missingDatesData, kind: .stock).issues[0]
        check(missingDateStock.paymentDate == nil, "日期片段不能生成缴款提醒")
        for bad in [#"{"success":false,"message":"上游失败"}"#, #"{"success":true,"result":null}"#, #"{"success":true,"result":{"pages":1}}"#] {
            do { _ = try IssueAPI.parse(Data(bad.utf8), kind: .stock); fatalError("查询异常被误判为无申购") }
            catch { checks += 1 }
        }
        let empty = try IssueAPI.parse(Data(#"{"success":true,"result":{"pages":0,"data":[]}}"#.utf8), kind: .stock)
        check(empty.issues.isEmpty, "真实空结果应正常处理")
        let emptyBusinessCode = try IssueAPI.parse(Data(#"{"success":false,"result":null,"message":"返回数据为空","code":9201}"#.utf8), kind: .bond)
        check(emptyBusinessCode.issues.isEmpty, "上游明确的无记录业务码应正常处理")
        var state = AppState()
        let bondFeed = FeedSnapshot(kind: .bond, fetchedAt: morning, issues: [bond])
        let stockFeed = FeedSnapshot(kind: .stock, fetchedAt: morning, issues: [stock])
        let results = [FeedResult(kind: .bond, snapshot: bondFeed, error: nil), FeedResult(kind: .stock, snapshot: stockFeed, error: nil)]
        state.put(bondFeed)
        state.put(stockFeed)
        check(state.today(at: morning) == [bond], "明日申购不能混入今日")
        let morningPlan = ReminderPlanner.plan(state: state, results: results, at: morning)!
        check(morningPlan.issues == [bond] && morningPlan.complete, "完整结果应包含今日申购")
        state.sent[morningPlan.slot] = morningPlan.tokens
        check(ReminderPlanner.plan(state: state, results: results, at: morning) == nil, "上午重复检查不可重复通知")
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        check(ReminderPlanner.plan(state: restored, results: results, at: morning) == nil, "应用重启后应保留去重记录")
        check(ReminderPlanner.plan(state: state, results: results, at: afternoon)?.issues == [bond], "下午应再次提醒同一项目")
        let partial = [results[0], FeedResult(kind: .stock, snapshot: nil, error: "断网")]
        let partialPlan = ReminderPlanner.plan(state: AppState(), results: partial, at: morning)!
        check(!partialPlan.complete && partialPlan.issues == [bond], "部分失败应保留另一类有效提醒")
        let failed = [FeedResult(kind: .stock, snapshot: nil, error: "断网"), FeedResult(kind: .bond, snapshot: nil, error: "断网")]
        check(ReminderPlanner.plan(state: state, results: failed, at: morning) == nil, "断网不可触发无申购提醒")
        check(!ReminderPlanner.hasUsableTodaySnapshot(state: AppState(), results: failed, at: morning), "当天确实没有成功结果或缓存时应判为无可用结果")
        var fallbackState = AppState()
        fallbackState.put(bondFeed)
        let fallback = ReminderPlanner.plan(state: fallbackState, results: failed, at: morning)!
        check(fallback.issues == [bond] && !fallback.complete, "查询失败时使用当天已有的成功快照兜底")
        fallbackState.put(stockFeed)
        check(ReminderPlanner.plan(state: fallbackState, results: failed, at: morning)?.complete == true, "两类同日缓存都可用时应生成完整提醒")
        check(ReminderPlanner.hasUsableTodaySnapshot(state: fallbackState, results: failed, at: morning), "当天缓存可用时不应发送查询失败通知")
        check(!ReminderPlanner.hasUsableTodaySnapshot(state: fallbackState, results: failed, at: date("2026-10-22T01:30:00Z")), "昨天缓存不能阻止当天的查询失败通知")
        let noIssues = [FeedResult(kind: .stock, snapshot: FeedSnapshot(kind: .stock, fetchedAt: morning, issues: []), error: nil), FeedResult(kind: .bond, snapshot: FeedSnapshot(kind: .bond, fetchedAt: morning, issues: []), error: nil)]
        check(ReminderPlanner.plan(state: AppState(), results: noIssues, at: morning)?.tokens == ["empty"], "确认无申购后才能标记空结果")
        var marked = fallbackState
        marked.markedApplications.insert(bond.id)
        check(ReminderPlanner.plan(state: marked, results: results, at: morning) == nil, "尚未发送过但已标记的申购不再提醒，也不误报无申购")
        check(ReminderPlanner.plan(state: fallbackState, results: noIssues, at: morning)?.tokens == ["empty"], "最新成功空结果必须覆盖当天旧缓存项目")
        var weekendState = AppState()
        weekendState.notifyWhenEmpty = true
        let weekend = date("2026-10-24T01:30:00Z")
        let weekendResults = IssueKind.allCases.map { FeedResult(kind: $0, snapshot: FeedSnapshot(kind: $0, fetchedAt: weekend, issues: []), error: nil) }
        check(ReminderPlanner.plan(state: weekendState, results: weekendResults, at: weekend) == nil, "周末即使开启无申购通知也不发送空提醒")
        let payment = ReminderPlanner.plan(state: state, results: results, at: morning, category: .payment)!
        let listing = ReminderPlanner.plan(state: state, results: results, at: morning, category: .listing)!
        check(payment.issues == [bond] && payment.tokens == ["payment:\(bond.id)"], "缴款计划应按缴款日使用独立 token")
        check(listing.issues == [bond] && listing.tokens == ["listing:\(bond.id)"], "上市计划应按上市日使用独立 token")
        var paymentSent = state
        paymentSent.sent[payment.slot, default: []].append(contentsOf: payment.tokens)
        check(ReminderPlanner.plan(state: paymentSent, results: results, at: morning, category: .payment) == nil, "同一上午的缴款提醒只发一次")
        check(ReminderPlanner.plan(state: paymentSent, results: results, at: morning, category: .listing)?.issues == [bond], "申购和缴款去重记录不得抑制上市提醒")
        check(ReminderPlanner.plan(state: paymentSent, results: results, at: afternoon, category: .payment)?.issues == [bond], "下午应再次提醒缴款")
        paymentSent.sent[listing.slot, default: []].append(contentsOf: listing.tokens)
        check(ReminderPlanner.plan(state: paymentSent, results: results, at: morning, category: .listing) == nil, "上市提醒同一时段应去重")
        var markedOnly = state
        markedOnly.onlyMarkedForPayment = true
        check(ReminderPlanner.plan(state: markedOnly, results: results, at: morning, category: .payment) == nil, "仅提醒已标记缴款时应过滤未标记项目")
        markedOnly.markedApplications.insert(bond.id)
        check(ReminderPlanner.plan(state: markedOnly, results: results, at: morning, category: .payment)?.issues == [bond], "仅提醒已标记缴款时应保留已标记项目")
        markedOnly.onlyMarkedForListing = true
        markedOnly.markedApplications.removeAll()
        check(ReminderPlanner.plan(state: markedOnly, results: results, at: morning, category: .listing) == nil, "仅提醒已标记上市时应过滤未标记项目")
        markedOnly.markedApplications.insert(bond.id)
        check(ReminderPlanner.plan(state: markedOnly, results: results, at: morning, category: .listing)?.issues == [bond], "仅提醒已标记上市时应保留已标记项目")
        let legacy = try JSONDecoder().decode(AppState.self, from: Data(#"{"feeds":[],"sent":{},"notifyWhenEmpty":true,"thsPath":null}"#.utf8))
        check(legacy.notifyWhenEmpty && legacy.markedApplications.isEmpty && !legacy.onlyMarkedForListing, "旧状态文件缺少新增设置时仍可读取")
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fallbackState)) as! [String: Any]
        var oldFeeds = legacyObject["feeds"] as! [[String: Any]]
        for index in oldFeeds.indices {
            oldFeeds[index]["issues"] = (oldFeeds[index]["issues"] as! [[String: Any]]).map { issue in
                var oldIssue = issue
                oldIssue.removeValue(forKey: "paymentDate")
                oldIssue.removeValue(forKey: "listingDate")
                return oldIssue
            }
        }
        legacyObject["feeds"] = oldFeeds
        let oldCache = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(oldCache.today(at: morning).map(\.applyCode) == [bond.applyCode] && oldCache.todayPayment(at: morning).isEmpty, "旧版真实项目缓存不含新增日期时仍能恢复申购列表")
        var blocked = AppState()
        check(blocked.recordPermissionBlock(slot: morningPlan.slot, tokens: [bond.id]), "无权限时首次未发送的提醒应记日志")
        check(!blocked.recordPermissionBlock(slot: morningPlan.slot, tokens: [bond.id]), "同一提醒被权限阻止只记录一次")
        var blockedRestored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(blocked))
        check(!blockedRestored.recordPermissionBlock(slot: morningPlan.slot, tokens: [bond.id]), "重启后仍保留无权限日志去重")
        check(blockedRestored.recordPermissionBlock(slot: "2026-10-21@14:30", tokens: [bond.id]), "下午的独立提醒被阻止时应记录")
        blockedRestored.prune(at: date("2026-10-30T01:30:00Z"))
        check(blockedRestored.permissionLogKeys.isEmpty, "超过7天的权限去重记录应清理")
        var queryLog = QueryLogTracker()
        check(queryLog.message(for: results[0])?.contains("首次成功") == true, "启动后首次成功查询应记录")
        check(queryLog.message(for: results[0]) == nil, "内容相同的成功查询应静默")
        let laterResult = FeedResult(kind: .bond, snapshot: FeedSnapshot(kind: .bond, fetchedAt: afternoon, issues: [bond]), error: nil)
        check(queryLog.message(for: laterResult) == nil, "仅抓取时间变化不应记录成功日志")
        check(queryLog.message(for: failed[1]) != nil && queryLog.message(for: failed[1]) != nil, "连续失败每次均应记录")
        check(queryLog.message(for: laterResult)?.contains("从失败恢复") == true, "从失败恢复即使结果相同也应记录")
        check(queryLog.message(for: noIssues[1])?.contains("结果变化") == true, "成功日历内容变化应记录")
        let tomorrow = date("2026-10-22T01:30:00Z")
        check(ReminderPlanner.plan(state: state, results: results, at: tomorrow) == nil, "历史缓存不可作为今日的已核实数据")
        let query = URLComponents(url: IssueAPI.url(kind: .bond, day: "2026-10-21", page: 1, host: "datacenter-web.eastmoney.com"), resolvingAgainstBaseURL: false)!
        check(query.queryItems!.first(where: { $0.name == "filter" })!.value == "(PUBLIC_START_DATE>='2026-10-21')", "过滤参数须正确编码")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 512_001).write(to: temporary.appendingPathComponent("activity.log"))
        try Data("旧归档\n".utf8).write(to: temporary.appendingPathComponent("activity.1.log"))
        try ActivityLogFile.append("轮换测试", to: temporary, at: morning)
        let archived = try Data(contentsOf: temporary.appendingPathComponent("activity.1.log"))
        let currentLog = String(data: try Data(contentsOf: temporary.appendingPathComponent("activity.log")), encoding: .utf8)!
        check(archived.count == 512_001 && currentLog.contains("+08:00 轮换测试"), "日志超限后应保留 activity.1.log 并写北京时间")
        print("通过 \(checks) 项核心检查：提醒时刻、跨日、去重、数据解析、部分失败与缓存。")
    }
}

import Foundation
import AppKit

@main struct FeatureTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func rejected(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }
        func date(_ value: String) -> Date {
            ISO8601DateFormatter().date(from: value + "+08:00")!
        }
        let now = date("2026-10-22T10:00:00")
        for day in ["2026-01-01", "2026-02-16", "2026-02-23", "2026-04-06", "2026-05-05", "2026-06-19", "2026-09-25", "2026-10-07", "2026-02-14", "2026-02-28", "2026-05-09", "2026-10-10"] {
            let value = date(day + "T10:00:00")
            check(!TradingCalendar.isTradingDay(value) && ChinaClock.dueSlot(at: value) == nil, "节假日和调休周末不可通知：" + day)
            check(MarketRefreshSchedule.interval(at: value, snapshots: [:], hasError: true) == nil, "休市不自动请求行情")
        }
        check(TradingCalendar.isTradingDay(date("2026-02-24T10:00:00")), "春节后恢复交易")
        check(TradingCalendar.isTradingDay(date("2026-10-08T10:00:00")), "国庆后恢复交易")
        check(!TradingCalendar.isTradingTime(date("2026-10-22T11:30:00")) && !TradingCalendar.isTradingTime(date("2026-10-22T15:00:00")), "午休及收盘不触发条件")
        check(TradingCalendar.isTradingTime(date("2026-10-22T13:00:00")), "下午开盘时可以触发")
        check(TradingCalendar.status(at: date("2098-01-02T10:00:00")).contains("未确认"), "未知年份不能冒充准确日历")
        let html = "<strong>2026年休市安排</strong><table>" + [
            "元旦：1月1日（星期四）至1月3日（星期六）休市",
            "春节：2月15日（星期日）至2月23日（星期一）休市",
            "清明节：4月4日（星期六）至4月6日（星期一）休市",
            "劳动节：5月1日（星期五）至5月5日（星期二）休市",
            "端午节：6月19日（星期五）至6月21日（星期日）休市",
            "中秋节：9月25日（星期五）至9月27日（星期日）休市",
            "国庆节：10月1日（星期四）至10月7日（星期三）休市"
        ].map { "<tr><td>\($0)</td></tr>" }.joined() + "</table>相关公告"
        let calendar = try TradingCalendar.parse(Data(html.utf8), at: now)
        check(calendar.closedDays == TradingCalendar.builtIn2026.closedDays, "官方年度表解析与内置日历一致")
        check(rejected { _ = try TradingCalendar.parse(Data(html.replacingOccurrences(of: "春节：", with: "缺少：").utf8)) }, "不完整年度表必须拒绝")
        check(rejected { try TradingCalendar.install(TradingCalendarYear(year: 2026, closedDays: ["2026-02-30"], source: TradingCalendar.source, fetchedAt: now)) }, "无效日历不得覆盖已确认安排")
        check(!TradingCalendar.isTradingDay(date("2026-10-01T10:00:00")), "损坏后仍保留旧日历")
        if CommandLine.arguments.count > 1 {
            let real = try TradingCalendar.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), at: now)
            check(real.closedDays == TradingCalendar.builtIn2026.closedDays, "实际官方HTML解析通过")
        }

        let security = SecurityID(market: 1, code: "600519")
        func quote(_ price: Double? = 100, _ percent: Double? = 3, at time: Date? = nil) -> MarketQuote {
            MarketQuote(security: security, name: "测试股票", price: price, percent: percent, change: nil, netInflow: nil, updatedAt: time ?? now)
        }
        let above = PriceAlertRule(security: security, name: "测试股票", kind: .priceAbove, threshold: 100)
        let below = PriceAlertRule(security: security, name: "测试股票", kind: .priceBelow, threshold: 100)
        let gain = PriceAlertRule(security: security, name: "测试股票", kind: .percentAbove, threshold: 3)
        let loss = PriceAlertRule(security: security, name: "测试股票", kind: .percentBelow, threshold: 3)
        check(above.matches(quote(), at: now) && below.matches(quote(), at: now), "价格阈值包含等于")
        check(!above.matches(quote(99), at: now) && !below.matches(quote(101), at: now), "价格阈值方向正确")
        check(gain.matches(quote(), at: now) && loss.matches(quote(100, -3), at: now), "跌幅正数输入应转换负数")
        check(!loss.matches(quote(), at: now), "上涨不得触发下跌条件")
        check(!above.matches(quote(at: now.addingTimeInterval(-361)), at: now), "落后超过6分钟不能触发")
        check(!above.matches(quote(at: now.addingTimeInterval(61)), at: now), "远期错误行情不能触发")
        check(!above.matches(quote(at: date("2026-10-21T10:00:00")), at: now), "旧日行情不能触发")
        check(!above.matches(quote(nil), at: now), "没有价格不能触发")
        check(!above.matches(quote(at: date("2026-10-22T12:00:00")), at: date("2026-10-22T12:00:00")), "午休不发条件通知")
        check(!above.matches(quote(at: date("2026-10-01T10:00:00")), at: date("2026-10-01T10:00:00")), "节假日不发条件通知")
        var disabled = above; disabled.enabled = false
        check(!disabled.matches(quote(), at: now), "关闭规则不提醒")
        check(!PriceAlertRule(security: security, name: "测试", kind: .priceAbove, threshold: -1).isValid, "负数阈值拒绝")
        check(!PriceAlertRule(security: security, name: "测试", kind: .percentAbove, threshold: 101).isValid, "百分比必须在允许范围")
        check(!PriceAlertRule(security: security, name: "测试", kind: .priceAbove, threshold: .nan).isValid, "非有限值拒绝")

        let issue = Issue(kind: .stock, name: "测试新股", securityCode: "688999", applyCode: "787999", applyDate: "2026-10-20", price: 20, market: "科创板", upperLimit: 5000, paymentDate: "2026-10-22", listingDate: "2026-10-30")
        let beijing = Issue(kind: .stock, name: "北交所新股", securityCode: "920999", applyCode: "920999", applyDate: "2026-10-20", price: 20, market: "北交所", upperLimit: 10000, paymentDate: "2026-10-22", listingDate: nil)
        var state = AppState()
        state.put(FeedSnapshot(kind: .stock, fetchedAt: now, issues: [issue, beijing]))
        state.put(FeedSnapshot(kind: .bond, fetchedAt: now, issues: []))
        state.setWon(issue.id, true)
        check(state.markedApplications.contains(issue.id) && state.trackedIssues.count == 1, "中签同时标记已申购并保存项目资料")
        let plan = ReminderPlanner.plan(state: state, results: [], at: now, category: .payment)
        check(plan?.issues.map(\.id) == [issue.id], "缴款计划排除北交所")
        let late = date("2026-10-22T14:45:00")
        check(PaymentFollowUp.pending(state: state, at: late).map(\.id) == [issue.id], "中签未缴款增加提醒")
        let firstSlot = PaymentFollowUp.slot(at: late)!
        state.sent[firstSlot] = ["payment-followup:\(issue.id)"]
        check(PaymentFollowUp.pending(state: state, at: late).isEmpty, "附加提醒同一时段去重")
        check(PaymentFollowUp.pending(state: state, at: date("2026-10-22T15:30:00")).count == 1, "15:30可再次提醒")
        check(PaymentFollowUp.slot(at: date("2026-10-22T16:00:00")) == nil, "16点后不补缴款通知")
        check(PaymentFollowUp.status(issue, state: state, at: late)?.contains("75分钟") == true, "参考截止提示按北京时间计算")
        state.setPaid(issue.id, true)
        check(state.wonIssues.contains(issue.id) && state.markedApplications.contains(issue.id), "缴款状态包含中签与申购")
        check(ReminderPlanner.plan(state: state, results: [], at: now, category: .payment) == nil, "缴款后停止正常缴款提醒")
        check(PaymentFollowUp.pending(state: state, at: date("2026-10-22T15:30:00")).isEmpty, "缴款后停止附加提醒")
        state.put(FeedSnapshot(kind: .stock, fetchedAt: now, issues: []))
        check(state.knownIssues.map(\.id) == [issue.id], "项目移出日历后仍能管理已申购记录")
        state.setWon(issue.id, false)
        check(state.paidIssues.isEmpty && state.markedApplications.contains(issue.id), "取消中签应清缴款状态并保留申购")
        state.setPaid(issue.id, true); state.setApplied(issue.id, false)
        check(state.paidIssues.isEmpty && state.wonIssues.isEmpty && state.trackedIssues.isEmpty, "取消申购清理关联状态")
        let legacy = try JSONDecoder().decode(AppState.self, from: Data("{}".utf8))
        check(legacy.notifyMarketHealth && legacy.priceAlerts.isEmpty && legacy.paidIssues.isEmpty, "老状态文件兼容新字段默认值")
        state.priceAlerts = [above]
        state.sent[ChinaClock.day(now) + "@price"] = [above.token]
        let reopened = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        check(reopened.sent[ChinaClock.day(now) + "@price"] == [above.token], "条件每日去重跨重启保存")
        check(reopened.sent["2026-10-23@price"] == nil, "条件次日可重新提醒")

        var health = MarketHealthState()
        health.observe(success: false, latest: now, at: now)
        health.checkDelay(latest: now, at: now.addingTimeInterval(20))
        check(health.failures == 1 && health.episode == nil, "定时检查延迟不累计网络失败")
        health.observe(success: false, latest: now, at: now.addingTimeInterval(60))
        check(health.episode == nil, "两次失败不报警")
        health.observe(success: false, latest: now, at: now.addingTimeInterval(120))
        let episode = health.episode
        check(episode != nil && health.failures == 3, "连续3次失败报警")
        health.observe(success: false, latest: now, at: now.addingTimeInterval(180))
        check(health.episode == episode, "同一异常只保留一个通知标识")
        health.observe(success: true, latest: now.addingTimeInterval(240), at: now.addingTimeInterval(240))
        check(health.episode == nil && health.recoveredEpisode == episode && health.failures == 0, "恢复保留对应异常标识以去重")
        health.observe(success: true, latest: now, at: now.addingTimeInterval(900))
        check(health.episode != nil && health.recoveredEpisode == nil, "接口成功但行情落后15分钟也报警")
        var morning = MarketHealthState()
        morning.observe(success: false, latest: nil, at: date("2026-10-22T09:31:00"))
        check(morning.episode == nil, "开盘给予15分钟宽限")
        morning.checkDelay(latest: nil, at: date("2026-10-22T09:45:00"))
        check(morning.episode != nil, "开盘无行情15分钟后报警")
        check(MarketHealthState.delay(latest: date("2026-10-22T11:30:00"), at: date("2026-10-22T13:00:00")) == 0, "午休不累计数据延迟")
        check(MarketHealthState.delay(latest: date("2026-10-22T11:30:00"), at: date("2026-10-22T13:15:00")) == 900, "下午开盘15分钟未更新报警")
        let unchanged = health
        health.observe(success: false, latest: nil, at: date("2026-10-22T12:00:00"))
        check(health == unchanged, "午休不累计失败也不恢复")
        health.observe(success: false, latest: nil, at: date("2026-10-01T10:00:00"))
        check(health == unchanged, "假期不累计失败")
        health.observe(success: true, latest: date("2026-10-23T10:00:00"), at: date("2026-10-23T10:00:00"))
        check(health.episode == nil && health.recoveredEpisode == nil && health.day == "2026-10-23", "跨日不误发昨天的恢复通知")

        state = AppState()
        state.put(FeedSnapshot(kind: .stock, fetchedAt: now, issues: [issue]))
        state.setPaid(issue.id, true); state.priceAlerts = [above, loss]
        state.notifyMarketHealth = false; state.onlyMarkedForPayment = true
        let backup = SettingsBackup(state: state, favorites: [security], quotes: [quote()], at: now)
        let backupJSON = try JSONEncoder().encode(backup)
        let decoded = try SettingsBackup.decode(backupJSON)
        check(decoded.priceAlerts == state.priceAlerts && decoded.paidIssues == state.paidIssues, "备份完整保存规则和三种标记")
        var current = AppState(); current.sent = ["2026-10-22@price": [above.token]]
        current.thsPath = "/本机的同花顺.app"; current.permissionLogKeys = ["本机通知状态"]
        current.put(FeedSnapshot(kind: .bond, fetchedAt: now, issues: []))
        let applied = decoded.applying(to: current)
        check(applied.sent == current.sent && applied.thsPath == current.thsPath && applied.feeds == current.feeds && applied.permissionLogKeys == current.permissionLogKeys, "恢复保留现有行情日历、通知去重和本机路径")
        check(!applied.notifyMarketHealth && applied.onlyMarkedForPayment && applied.trackedIssues.map(\.id) == [issue.id], "恢复个人设置与已标记项目资料")
        check(rejected { _ = try SettingsBackup.decode(Data("损坏JSON".utf8)) }, "损坏备份拒绝")
        check(rejected { _ = try SettingsBackup.decode(Data(repeating: 0, count: 2_000_001)) }, "超大备份拒绝")
        var bad = try JSONSerialization.jsonObject(with: backupJSON) as! [String: Any]
        bad["favorites"] = [String]()
        check(rejected { _ = try SettingsBackup.decode(JSONSerialization.data(withJSONObject: bad)) }, "规则不属于自选时拒绝，不能产生孤立提醒")
        bad = try JSONSerialization.jsonObject(with: backupJSON) as! [String: Any]; bad["wonIssues"] = [String]()
        check(rejected { _ = try SettingsBackup.decode(JSONSerialization.data(withJSONObject: bad)) }, "缴款不能没有中签状态")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatureTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try backup.restore(to: directory, current: current)
        let saved = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        check(saved.paidIssues == state.paidIssues && saved.sent == current.sent, "磁盘恢复与内存一致")
        let loadedMarket = MarketModel(directory: directory)
        check(loadedMarket.favorites == [security] && loadedMarket.favoriteQuotes.first?.name == "测试股票", "恢复自选文件可重载名称及行情")
        let originalPreferences = try JSONEncoder().encode([SecurityID]())
        let preferencesURL = directory.appendingPathComponent("market-preferences.json")
        try originalPreferences.write(to: preferencesURL)
        let originalState = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        var writes = 0
        check(rejected {
            _ = try backup.restore(to: directory, current: current, write: { data, url in
                writes += 1
                if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
        }, "第二个文件写入失败须明确失败")
        let afterPreferences = try Data(contentsOf: preferencesURL)
        let afterState = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        check(writes == 2 && afterPreferences == originalPreferences && afterState == originalState, "恢复中途失败回滚已写入的自选文件，保持原state不变")
        let blocked = directory.appendingPathComponent("favorite-quotes.json")
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("占位".utf8).write(to: blocked.appendingPathComponent("file"))
        check(rejected { _ = try backup.restore(to: directory, current: current) }, "目标无法读取时应在任何写入前退出")

        let rules = PriceAlertRulesModel()
        rules.onEdit = { value in rules.update(value, sent: []) }
        rules.add(quote: quote(), kind: .priceAbove, input: "100")
        check(rules.rules.count == 1, "规则窗口可新增条件")
        rules.add(quote: quote(), kind: .priceAbove, input: "100")
        check(rules.rules.count == 1 && rules.error != nil, "窗口避免相同规则重复")
        let ruleID = rules.rules[0].id
        rules.setEnabled(ruleID, false)
        check(!rules.rules[0].enabled && rules.rules[0].id == ruleID, "关闭再开启保留原去重标识")
        rules.remove(ruleID)
        check(rules.rules.isEmpty, "规则窗口可删除条件")
        print("通过 \(checks) 项功能检查")
    }
}

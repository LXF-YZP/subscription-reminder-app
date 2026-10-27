import Foundation

@main struct MarketTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError(message) } catch { checks += 1 }
        }
        let now = MarketParsing.date("2026-10-21")!
        let old = MarketParsing.date("2026-10-20")!
        func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let session = instant("2026-10-21T02:00:00Z") // 北京时间 10:00
        let close = instant("2026-10-21T07:10:00Z") // 北京时间 15:10
        let saturday = instant("2026-10-24T02:00:00Z")
        func quote(_ code: String, pct: Double? = nil, flow: Double? = nil, time: Date? = now, price: Double? = 12) -> MarketQuote {
            MarketQuote(security: SecurityID(market: 0, code: code), name: "测试\(code)", price: price, percent: pct, change: nil, netInflow: flow, updatedAt: time)
        }
        func snapshots(quoteTime: Date, fetchedAt: Date) -> [MarketIndex: MarketSnapshot] {
            Dictionary(uniqueKeysWithValues: MarketIndex.allCases.map { index in
                let indexQuote = MarketQuote(security: index.security, name: index.name, price: 3000, percent: 1, change: 30, netInflow: nil, updatedAt: quoteTime)
                return (index, MarketSnapshot(index: index, quote: indexQuote, stocks: [quote("000001", pct: 1, flow: 100, time: quoteTime)], memberCount: 1, fetchedAt: fetchedAt))
            })
        }
        let closing = snapshots(quoteTime: close, fetchedAt: close)
        let morning = snapshots(quoteTime: session, fetchedAt: session)
        let holiday = snapshots(quoteTime: old, fetchedAt: session)
        check(MarketRefreshSchedule.interval(at: saturday, snapshots: [:], hasError: false) == nil, "周末不自动刷新行情")
        check(MarketRefreshSchedule.interval(at: session, snapshots: [:], hasError: false) == 300, "正常交易时段每5分钟刷新")
        check(MarketRefreshSchedule.interval(at: session, snapshots: holiday, hasError: false) == 3600, "工作日成功取得一致旧交易日行情时每小时探测")
        check(MarketRefreshSchedule.interval(at: session, snapshots: holiday, hasError: true) == 60, "查询失败不能用旧交易日判断休市，盘中应1分钟后重试")
        check(MarketRefreshSchedule.interval(at: close, snapshots: closing, hasError: false) == nil, "收盘完整数据后停止自动刷新")
        check(MarketRefreshSchedule.interval(at: close, snapshots: closing, hasError: true) == 900, "收盘后查询失败每15分钟重试")
        check(MarketRefreshSchedule.interval(at: close, snapshots: morning, hasError: false) == 900, "当天上午快照不能误认为完整收盘数据")
        check(MarketRefreshSchedule.interval(at: close, snapshots: snapshots(quoteTime: session, fetchedAt: close), hasError: false) == 900, "收盘后抓取但指数仍为盘中时间时应继续刷新")
        check(MarketRefreshSchedule.interval(at: close, snapshots: snapshots(quoteTime: old, fetchedAt: old), hasError: false) == 900, "昨天的缓存不能直接推断今天休市")
        check(MarketRefreshSchedule.interval(at: session, snapshots: morning, hasError: false) == 300, "当天盘中行情仍按5分钟更新")
        var incomplete = closing
        incomplete.removeValue(forKey: .csi300)
        check(MarketRefreshSchedule.interval(at: close, snapshots: incomplete, hasError: false) == 900, "缺少任一指数不能停止刷新")
        incomplete = closing
        incomplete[.csi300] = morning[.csi300]
        check(MarketRefreshSchedule.interval(at: close, snapshots: incomplete, hasError: false) == 900, "一个范围尚未收盘不能停止刷新")
        let full = closing[.shanghai]!
        incomplete[.csi300] = MarketSnapshot(index: .csi300, quote: closing[.csi300]!.quote, stocks: full.stocks, memberCount: 2, fetchedAt: close)
        check(MarketRefreshSchedule.interval(at: close, snapshots: incomplete, hasError: false) == 900, "成分行情不完整不能停止刷新")
        check(!MarketSnapshot(index: .shanghai, quote: full.quote, stocks: full.stocks + full.stocks, memberCount: 2, fetchedAt: close).isComplete, "重复成分行情不能作为完整数据")
        check(MarketRefreshSchedule.interval(at: instant("2026-10-21T01:45:00Z"), snapshots: holiday, hasError: false) == 300, "10点前旧交易日行情不作为休市依据")
        check(MarketRefreshSchedule.isStale(instant("2026-10-22T03:09:00Z"), at: instant("2026-10-22T03:35:00Z")), "11:35仍为11:09的数据应提示时间落后")
        check(!MarketRefreshSchedule.isStale(instant("2026-10-22T03:30:00Z"), at: instant("2026-10-22T04:45:00Z")), "午休11:30的行情不能误报过期")
        check(MarketRefreshSchedule.isStale(instant("2026-10-22T03:30:00Z"), at: instant("2026-10-22T05:10:00Z")), "下午复市后旧上午数据必须提示过期")
        check(!MarketRefreshSchedule.isStale(instant("2026-10-22T07:00:00Z"), at: instant("2026-10-22T13:00:00Z")), "15点收盘行情晚间仍有效")
        check(!MarketRefreshSchedule.isStale(old, at: saturday), "周末不将最近交易行情误报为盘中延迟")
        check(!MarketRefreshSchedule.isStale(old, at: instant("2026-10-22T01:00:00Z")), "盘前不要求当天成交行情")
        let rows = [quote("000001", pct: 3, flow: -300), quote("000002", pct: -5, flow: 500), quote("000003", pct: -2, flow: -600),
                    quote("000004", pct: 3, flow: 200), quote("000005", pct: 0, flow: 0), quote("000006"),
                    quote("000007", pct: 30, flow: 9999, time: old), quote("000008", pct: 50, flow: 99999, price: 0),
                    quote("000009", pct: 90, flow: 999999, time: nil)]
        let snapshot = MarketSnapshot(index: .shenzhen, quote: quote("399001", pct: -1), stocks: rows, memberCount: rows.count, fetchedAt: now)
        check(snapshot.ranked(.gainers).map(\.security.code) == ["000001", "000004"], "涨幅榜只收正值，并列按代码稳定排序")
        check(snapshot.ranked(.losers).map(\.security.code) == ["000002", "000003"], "跌幅榜应最负在前")
        check(snapshot.ranked(.inflows).map(\.security.code) == ["000002", "000004"], "流入榜按主力净额降序，与涨跌幅独立")
        check(snapshot.ranked(.outflows).map(\.security.code) == ["000003", "000001"], "流出榜按主力净额升序")
        check(snapshot.availableCount(.gainers) == 5 && snapshot.availableCount(.inflows) == 5, "停牌旧日、时间缺失、零价格及缺失指标应排除")
        let boundary = MarketSnapshot(index: .shenzhen, quote: quote("399001", time: session), stocks: [
            quote("000001", pct: 1, time: instant("2026-10-20T16:00:00Z")),
            quote("000002", pct: 2, time: instant("2026-10-21T15:59:59Z")),
            quote("000003", pct: 3, time: instant("2026-10-20T15:59:59Z")),
            quote("000004", pct: 4, time: instant("2026-10-21T16:00:00Z"))
        ], memberCount: 4, fetchedAt: session)
        check(boundary.eligibleStocks.map(\.security.code) == ["000001", "000002"], "日期过滤以北京时间零点为界，不能误用UTC日期或包含次日零点")
        check(MarketSnapshot(index: .shenzhen, quote: quote("399001", time: nil), stocks: rows, memberCount: rows.count, fetchedAt: now).eligibleStocks.isEmpty, "缺少指数行情日期时不可生成榜单")
        let many = (1...15).map { quote(String(format: "%06d", $0), pct: Double($0)) }
        let ten = MarketSnapshot(index: .shenzhen, quote: quote("399001"), stocks: many, memberCount: 15, fetchedAt: now).ranked(.gainers)
        check(ten.count == 10 && ten.first?.percent == 15 && ten.last?.percent == 6, "榜单只取真正前十")
        let largeRows = (0..<3000).map { quote(String(100000 + $0), pct: Double($0), flow: -Double($0)) }
        let large = MarketSnapshot(index: .shenzhen, quote: quote("399001"), stocks: largeRows, memberCount: largeRows.count, fetchedAt: now)
        let rankingStart = ProcessInfo.processInfo.systemUptime
        let total = RankingKind.allCases.reduce(0) { $0 + large.ranked($1).count + large.availableCount($1) }
        let rankingTime = ProcessInfo.processInfo.systemUptime - rankingStart
        check(total == 12020 && rankingTime < 2, "3000只股票的四榜计算不能再次阻塞界面数秒")
        check(SecurityID(market: 1, code: "000001") != SecurityID(market: 0, code: "000001"), "上证指数和平安银行不可因代码相同混淆")
        check(SecurityID.parse("0.000001")?.code == "000001", "证券代码前导零应保留")
        check(SecurityID.parse("2.600519") == nil && SecurityID.parse("1.123") == nil, "非法代码必须拒绝")
        let suggestions = Data(#"{"QuotationCodeTable":{"Status":0,"Data":[{"Code":"000001","Name":"上证指数","SecurityTypeName":"指数","QuoteID":"1.000001"},{"Code":"000001","Name":"平安银行","SecurityTypeName":"深A","QuoteID":"0.000001"},{"Code":"600519","Name":"贵州茅台","SecurityTypeName":"沪A","QuoteID":"1.600519"},{"Code":"920001","Name":"纬达光电","Classify":"NEEQ","SecurityTypeName":"京A","QuoteID":"0.920001"},{"Code":"000001","Name":"重复","SecurityTypeName":"深A","QuoteID":"0.000001"},{"Code":"000002","Name":"不匹配","SecurityTypeName":"深A","QuoteID":"0.000001"},{"Code":"00700","Name":"腾讯控股","SecurityTypeName":"港股","QuoteID":"116.00700"},{"Code":"000003","Name":" ","SecurityTypeName":"深A","QuoteID":"0.000003"}]}}"#.utf8)
        let matches = try StockSearch.parse(suggestions)
        check(matches.map(\.id) == ["0.000001", "1.600519", "0.920001"], "搜索只保留沪深京A股、去重并核对证券代码")
        check(matches.first?.name == "平安银行", "相同代码的指数不能误当股票")
        check(matches.last?.marketName == "京A" && matches.last?.security.label == "京 920001", "北交所的NEEQ分类也必须支持")
        check(matches[1].placeholderQuote.name == "贵州茅台" && matches[1].placeholderQuote.price == nil, "未取得行情也应保留搜索名称，不编造价格")
        let emptySearch = try StockSearch.parse(Data(#"{"QuotationCodeTable":{"Status":0,"TotalCount":0,"Data":null}}"#.utf8))
        check(emptySearch.isEmpty, "实际接口无匹配时Data为null应返回空结果")
        let emptyArray = try StockSearch.parse(Data(#"{"QuotationCodeTable":{"Status":0,"Data":[]}}"#.utf8))
        check(emptyArray.isEmpty, "空搜索数组也应正常处理")
        rejects("搜索业务失败不能当成无结果") { _ = try StockSearch.parse(Data(#"{"QuotationCodeTable":{"Status":1,"Data":[]}}"#.utf8)) }
        rejects("缺少搜索数据不能当成无结果") { _ = try StockSearch.parse(Data(#"{"QuotationCodeTable":{"Status":0}}"#.utf8)) }
        rejects("异常的null不能掩盖丢失的搜索结果") { _ = try StockSearch.parse(Data(#"{"QuotationCodeTable":{"Status":0,"TotalCount":2,"Data":null}}"#.utf8)) }
        check(StockSearch.local(" 贵州 ", quotes: matches.map(\.placeholderQuote)).map(\.id) == ["1.600519"], "本地支持去首尾空格和部分名称搜索")
        check(StockSearch.local("000001", quotes: matches.map(\.placeholderQuote)).first?.security.code == "000001", "本地按代码搜索保留前导零")
        check(StockSearch.local("   ", quotes: matches.map(\.placeholderQuote)).isEmpty, "空搜索不展示全部股票")
        check(MarketParsing.number("-") == nil && MarketParsing.number(NSNull()) == nil && MarketParsing.number(true) == nil, "缺失值和布尔值不能解析成0或1")
        check(MarketParsing.number("nan") == nil && MarketParsing.number("inf") == nil, "非有限数不能进入排名")
        let valid = Data(#"{"rc":0,"data":{"total":1,"diff":[{"f2":11.41,"f3":-0.26,"f4":-0.03,"f12":"000001","f13":0,"f14":"平安银行","f62":24211938,"f124":1792567020}]}}"#.utf8)
        let parsed = try MarketParsing.quotes(valid, expected: [SecurityID(market: 0, code: "000001")])[0]
        check(parsed.price == 11.41 && parsed.percent == -0.26, "fltt=2小数不应再次除以100")
        check(parsed.netInflow == 24211938 && ChinaClock.day(parsed.updatedAt!) == "2026-10-21", "资金单位是元，更新时间须按北京时间")
        rejects("不能接受缺少成分的批次") { _ = try MarketParsing.quotes(valid, expected: [SecurityID(market: 0, code: "000001"), SecurityID(market: 0, code: "000002")]) }
        rejects("业务失败不能当成空榜") { _ = try MarketParsing.quotes(Data(#"{"rc":102,"data":null}"#.utf8)) }
        rejects("条数不符必须拒绝") { _ = try MarketParsing.quotes(Data(#"{"rc":0,"data":{"total":2,"diff":[]}}"#.utf8)) }
        let duplicate = Data(#"{"rc":0,"data":{"total":2,"diff":[{"f12":"000001","f13":0,"f14":"a"},{"f12":"000001","f13":0,"f14":"b"}]}}"#.utf8)
        rejects("重复行情不能冒充完整批次") { _ = try MarketParsing.quotes(duplicate) }
        let members = (0..<500).map { ["symbol": String(format: "sz%06d", $0)] }
        let szMembers = try MarketParsing.members(JSONSerialization.data(withJSONObject: members), expected: 500, index: .shenzhen)
        check(szMembers.count == 500, "深证成指应验证500只")
        rejects("截断成员列表不可接受") { _ = try MarketParsing.members(JSONSerialization.data(withJSONObject: Array(members.prefix(100))), expected: 500, index: .shenzhen) }
        rejects("不能用全深市股票代替成分股") { _ = try MarketParsing.members(JSONSerialization.data(withJSONObject: members), expected: 500, index: .csi300) }
        let sh = (0..<1000).map { ["symbol": String(format: "sh%06d", 600000 + $0)] } + [["symbol": "sh900901"]]
        let shMembers = try MarketParsing.members(JSONSerialization.data(withJSONObject: sh), expected: 1001, index: .shanghai)
        check(shMembers.count == 1000 && shMembers.allSatisfy { $0.code.hasPrefix("6") }, "上证榜单必须按声明排除B股")
        let bars = try MarketParsing.history(Data(#"{"rc":0,"data":{"code":"000001","klines":["2026-10-21,10,11,12,9,100","2026-10-20,9,10,11,8,200"]}}"#.utf8), security: parsed.security)
        check(bars.map(\.close) == [10, 11], "日线必须读收盘列，且日期有序")
        rejects("图表不能接收别的股票") { _ = try MarketParsing.history(Data(#"{"rc":0,"data":{"code":"600519","klines":["2026-10-21,10,11"]}}"#.utf8), security: parsed.security) }
        check(MarketText.money(-123456789, signed: true) == "-1.23亿" && MarketText.number(nil) == "—", "金额单位和缺失标记应正确")
        let duplicateQuote = quote("000001", pct: 4, time: now)
        let newerQuote = quote("000001", pct: 6, time: now.addingTimeInterval(60))
        let merged = MarketQuoteIndex.latest(from: [
            MarketSnapshot(index: .shanghai, quote: quote("000001"), stocks: [duplicateQuote], memberCount: 1, fetchedAt: now),
            MarketSnapshot(index: .csi300, quote: quote("000300"), stocks: [newerQuote], memberCount: 1, fetchedAt: now)
        ])
        check(merged.count == 1 && merged[duplicateQuote.security]?.percent == 6, "跨指数重复股票应合并并保留较新行情")
        let copied = MarketText.rankingCopy(snapshot: snapshot, kind: .gainers)
        check(copied.contains("涨幅前十") && copied.contains("测试000001") && copied.contains("000001") && copied.contains("数据时间"), "榜单复制文本应包含标题、名称、代码和时间")
        let restored = try JSONDecoder().decode(MarketSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(restored.ranked(.outflows).map(\.id) == snapshot.ranked(.outflows).map(\.id), "磁盘缓存恢复后榜单排序应一致")
        print("通过 \(checks) 项行情检查：范围、排序、资金方向、缺失与过期、完整性、精度、日线、缓存、自选索引、股票搜索和复制文本。")
    }
}

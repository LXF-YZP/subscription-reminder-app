import AppKit
import UserNotifications
import UniformTypeIdentifiers

let bundleID = "local.yuezhiping.subscription-reminder"
let appTitle = "申购提醒"

@MainActor
enum StatusBarText {
    static func configure(_ button: NSStatusBarButton, count: Int) {
        let icon = NSImage(systemSymbolName: "calendar.badge.plus", accessibilityDescription: appTitle)
        icon?.isTemplate = true
        button.imagePosition = .imageLeft
        button.image = icon
        button.attributedTitle = title(count: count)
        guard let badge = overflowBadge(count: count), let icon = icon else { return }
        // 数量超出带圈字符范围时，合并绘制图标、文字和数量，始终保留左侧图标。
        let label = title(count: count)
        let gap: CGFloat = 4
        let size = NSSize(width: icon.size.width + gap + label.size().width + badge.size.width,
                          height: max(icon.size.height, label.size().height, badge.size.height))
        let combined = NSImage(size: size, flipped: false) { rect in
            icon.draw(at: NSPoint(x: 0, y: (rect.height - icon.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            label.draw(at: NSPoint(x: icon.size.width + gap, y: (rect.height - label.size().height) / 2))
            badge.draw(at: NSPoint(x: icon.size.width + gap + label.size().width, y: (rect.height - badge.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        combined.isTemplate = true
        button.attributedTitle = NSAttributedString(string: "")
        button.image = combined
    }

    static func title(count: Int) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let scalar: Int?
        switch count {
        case 1...20: scalar = 0x245F + count
        case 21...35: scalar = 0x3250 + count - 20
        case 36...50: scalar = 0x32B0 + count - 35
        default: scalar = nil
        }
        if let scalar = scalar, let character = UnicodeScalar(scalar) {
            return NSAttributedString(string: "\(appTitle)\(character)", attributes: attributes)
        }
        return NSAttributedString(string: appTitle, attributes: attributes)
    }

    static func overflowBadge(count: Int) -> NSImage? {
        guard count > 50 else { return nil }
        // Unicode 带圈数字最多到 50；更大的数量按同一字体绘制，避免截断实际数量。
        let font = NSFont.menuBarFont(ofSize: 0)
        let number = NSAttributedString(string: String(count), attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let height = ceil(font.ascender - font.descender) + 2
        let size = NSSize(width: max(height, ceil(number.size().width) + 4), height: height)
        let badge = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1
            outline.stroke()
            number.draw(at: NSPoint(x: (rect.width - number.size().width) / 2, y: (rect.height - number.size().height) / 2))
            return true
        }
        badge.isTemplate = true
        return badge
    }
}

@MainActor
final class Store {
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("state.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SubscriptionReminder", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func load() -> AppState {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(AppState.self, from: data) else { return AppState() }
        return state
    }
    func write(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
    func save(_ state: AppState) {
        do { try write(state) } catch { log("保存失败：\(error.localizedDescription)") }
    }
    func log(_ message: String) {
        try? ActivityLogFile.append(message, to: directory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let store: Store
    override init() { store = Store(); super.init() }
    init(store: Store) { self.store = store; super.init() }
    var state = AppState()
    var statusItem: NSStatusItem!
    var timer: Timer?
    var fetching = false
    var lastAttempt = Date.distantPast
    var attemptedSlot: String?
    var lastResults: [FeedResult] = []
    var errors: [IssueKind: String] = [:]
    var queryLog = QueryLogTracker()
    var notificationAllowed = false
    var notificationDenied = false
    var notificationStatusKnown = false
    var checkingNotificationStatus = false
    var lastNotificationStatusSignature: String?
    var pendingNotifications = Set<String>()
    var day = ChinaClock.day()
    lazy var market = MarketWindowController(directory: store.directory)
    lazy var favoriteSearch = FavoriteSearchWindowController(model: market.model)
    lazy var alertRules = PriceAlertRulesModel()
    lazy var priceAlertWindow = PriceAlertWindowController(rules: alertRules, market: market.model,
        showStock: { [weak self] in self?.market.showStock($0) })
    var lastMarketRound: Date?
    var calendarRefreshing = false
    var calendarLastAttempt = Date.distantPast
    var calendarLastError: String?
    var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 同一应用只能保留一个菜单栏实例。
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if CommandLine.arguments.contains("--show-market") {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name(bundleID + ".show-market"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            NSApp.terminate(nil)
            return
        }
        TradingCalendar.load(directory: store.directory)
        state = store.load()
        state.prune()
        for id in state.markedApplications { state.setApplied(id, true) }
        alertRules.onEdit = { [weak self] rules in
            guard let self = self else { return }
            var updated = self.state; updated.priceAlerts = rules
            do {
                try self.store.write(updated); self.state = updated
                self.alertRules.error = nil
                self.syncRuleWindow(); self.processExtraReminders()
            } catch { self.alertRules.error = "保存失败：\(error.localizedDescription)" }
        }
        syncRuleWindow()
        market.openTHS = { [weak self] in self?.openTHS(nil) }
        market.model.onChange = { [weak self] in self?.marketDidChange() }
        market.model.onRefreshCompleted = { [weak self] in self?.marketRefreshCompleted() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showMarket(_:)), name: Notification.Name(bundleID + ".show-market"), object: nil)
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        UNUserNotificationCenter.current().delegate = self
        let open = UNNotificationAction(identifier: "OPEN_THS", title: "打开同花顺", options: [.foreground])
        let detail = UNNotificationAction(identifier: "DETAILS", title: "查看今日事项", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "SUBSCRIPTIONS", actions: [open, detail], intentIdentifiers: [], options: [])
        ])
        rebuildMenu()
        store.log("启动；版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")；提醒时间 09:30 / 14:30（北京时间）")
        updateNotificationStatus()
        requestNotifications(nil)
        refreshTradingCalendar()
        refresh()
        // 按交易时段和缓存完整性决定是否刷新行情。
        refreshMarketIfDue()
        if CommandLine.arguments.contains("--show-market") { market.show() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func woke() { updateNotificationStatus(); refreshTradingCalendar(); refresh(); refreshMarketIfDue() }
    func tick() {
        let now = Date()
        updateNotificationStatus()
        refreshTradingCalendar()
        processExtraReminders(at: now)
        refreshMarketIfDue(at: now)
        let newDay = ChinaClock.day(now)
        if newDay != day {
            day = newDay
            errors.removeAll()
            rebuildMenu()
            refresh()
            return
        }
        let slot = ChinaClock.dueSlot(at: now)
        let hour = ChinaClock.calendar.component(.hour, from: now)
        let interval: TimeInterval = (TradingCalendar.isTradingDay(now) && hour >= 8 && hour < 16) ? 300 : 3600
        if (slot != nil && slot != attemptedSlot) || now.timeIntervalSince(lastAttempt) >= interval { refresh() }
    }

    func refreshMarketIfDue(at now: Date = Date()) {
        guard TradingCalendar.isTradingDay(now) else { return }
        let schedule = market.model.automaticRefreshInterval(at: now)
        guard let schedule = schedule else { return }
        market.model.refreshIfDue(interval: schedule)
    }

    @objc func refreshNow(_ sender: Any?) { refresh(); market.model.refresh() }
    func refresh() {
        guard !fetching else { return }
        fetching = true
        let requestedAt = Date()
        lastAttempt = requestedAt
        attemptedSlot = ChinaClock.dueSlot(at: requestedAt)
        rebuildMenu()
        Task {
            let results = await IssueAPI.fetchAll(at: requestedAt)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.fetching = false
                self.lastResults = results
                for result in results {
                    if let message = self.queryLog.message(for: result) { self.store.log(message) }
                    if let snapshot = result.snapshot {
                        self.state.put(snapshot)
                        self.errors.removeValue(forKey: result.kind)
                    } else {
                        self.errors[result.kind] = result.error ?? "查询失败"
                    }
                }
                self.state.prune()
                self.store.save(self.state)
                self.rebuildMenu()
                self.processReminder(results)
                self.processExtraReminders()
            }
        }
    }

    func processReminder(_ results: [FeedResult]) {
        let now = Date()
        guard notificationStatusKnown, let slot = ChinaClock.dueSlot(at: now) else { return }
        let categories: [ReminderCategory] = [.subscription, .payment, .listing]
        for category in categories {
            guard let plan = ReminderPlanner.plan(state: state, results: results, at: now, category: category) else { continue }
            if category == .subscription && plan.issues.isEmpty && !state.notifyWhenEmpty {
                record(tokens: plan.tokens, slot: plan.slot)
                continue
            }
            let stocks = plan.issues.filter { $0.kind == .stock }.count
            let bonds = plan.issues.filter { $0.kind == .bond }.count
            let title: String
            switch category {
            case .subscription: title = plan.issues.isEmpty ? "今日暂无新股和可转债申购" : "今日申购：新股 \(stocks) 只 · 可转债 \(bonds) 只"
            case .payment: title = "今日中签缴款：\(plan.issues.count) 只"
            case .listing: title = "今日上市：\(plan.issues.count) 只"
            }
            var lines = plan.issues.prefix(6).map { issue in
                let detail = category == .subscription ? issue.applyCode : "\(issue.kind.label) · \(issue.securityCode)"
                let status = category == .payment ? (PaymentFollowUp.status(issue, state: state).map { " · " + $0 } ?? "") : ""
                return "\(issue.name)  \(detail)\(status)"
            }
            if plan.issues.count > 6 { lines.append("另有 \(plan.issues.count - 6) 只，点击查看完整列表") }
            if !plan.complete { lines.append("部分日历暂未查到，正在重试") }
            if !plan.issues.isEmpty {
                switch category {
                case .subscription: lines.append("请到同花顺「新股申购」核实并申请")
                case .payment: lines.append("如已中签，请在同花顺核实并按时备足资金；本工具无法获知个人中签结果。")
                case .listing: lines.append("请在同花顺核实上市安排与持仓。")
                }
            }
            notify(title: title, body: lines.joined(separator: "\n"), slot: plan.slot, tokens: plan.tokens)
        }
        if !errors.isEmpty && !ReminderPlanner.hasUsableTodaySnapshot(state: state, results: results, at: now) && !(state.sent[slot] ?? []).contains("query-error") {
            let names = IssueKind.allCases.filter { errors[$0] != nil }.map(\.label).joined(separator: "、")
            notify(title: "\(names)日历暂时查询失败", body: "5 分钟后自动重试；你也可以先到同花顺查看今日申购。", slot: slot, tokens: ["query-error"])
        }
    }

    func record(tokens: [String], slot: String) {
        state.sent[slot] = Array(Set((state.sent[slot] ?? []) + tokens)).sorted()
        store.save(state)
        if slot.hasSuffix("@price") { syncRuleWindow() }
    }
    func notify(title: String, body: String, slot: String, tokens: [String], route: String = "issues", security: String? = nil) {
        guard notificationStatusKnown, !tokens.isEmpty, !Set(tokens).isSubset(of: Set(state.sent[slot] ?? [])) else { return }
        let key = slot + ":" + tokens.sorted().joined(separator: ",")
        guard notificationAllowed else {
            if state.recordPermissionBlock(slot: slot, tokens: tokens) {
                store.log("提醒因通知权限未开启而未发送：\(title)；\(slot)")
                store.save(state)
            }
            return
        }
        guard !pendingNotifications.contains(key) else { return }
        pendingNotifications.insert(key)
        let content = UNMutableNotificationContent()
        content.title = title
        let label = route == "stock" ? "自选股提醒" : (route == "market" ? "行情监测" : "\(slot.suffix(5)) 提醒")
        content.subtitle = "\(ChinaClock.day()) · \(label)"
        content.userInfo = ["route": route]
        if let security = security { content.userInfo["security"] = security }
        content.body = body.isEmpty ? "菜单栏可查看后续申购日历。" : body
        content.sound = .default
        content.categoryIdentifier = route == "issues" ? "SUBSCRIPTIONS" : ""
        let identifier = "reminder-\(key)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingNotifications.remove(key)
                if let error = error { self.store.log("通知发送失败：\(error.localizedDescription)") }
                else {
                    self.record(tokens: tokens, slot: slot)
                    self.store.log("已提交系统提醒：\(title)；\(slot)")
                }
            }
        }
    }

    @objc func requestNotifications(_ sender: Any?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error = error { self?.store.log("通知授权请求失败：\(error.localizedDescription)") }
                self?.updateNotificationStatus()
            }
        }
    }
    func updateNotificationStatus() {
        guard !checkingNotificationStatus else { return }
        checkingNotificationStatus = true
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingNotificationStatus = false
                self.notificationStatusKnown = true
                self.notificationAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.notificationDenied = settings.authorizationStatus == .denied
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
                let style: String
                switch settings.alertStyle {
                case .none: style = "无"
                case .banner: style = "横幅"
                case .alert: style = "提醒"
                @unknown default: style = "未知"
                }
                let signature = "authorization=\(settings.authorizationStatus.rawValue),style=\(style),alert=\(settings.alertSetting.rawValue),sound=\(settings.soundSetting.rawValue)"
                if self.lastNotificationStatusSignature != signature {
                    let prefix = self.lastNotificationStatusSignature == nil ? "启动通知状态" : "通知权限或样式变化"
                    self.store.log("\(prefix)：版本 \(version)；\(signature)")
                    self.lastNotificationStatusSignature = signature
                }
                self.rebuildMenu()
                self.processReminder(self.lastResults)
                self.processExtraReminders()
            }
        }
    }
    func menuWillOpen(_ menu: NSMenu) { updateNotificationStatus() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            if response.actionIdentifier == "OPEN_THS" { self?.openTHS(nil) }
            else if response.notification.request.content.userInfo["route"] as? String == "stock",
                    let raw = response.notification.request.content.userInfo["security"] as? String,
                    let security = SecurityID.parse(raw) {
                let quote = self?.market.model.quote(for: security) ?? MarketQuote(security: security, name: security.code,
                    price: nil, percent: nil, change: nil, netInflow: nil, updatedAt: nil)
                self?.market.showStock(quote)
            } else if response.notification.request.content.userInfo["route"] as? String == "market" { self?.showMarket(nil) }
            else { self?.showDetails(nil) }
            completionHandler()
        }
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, action: Selector? = nil, value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        menu.addItem(item)
        return item
    }
    func heading(_ menu: NSMenu, _ text: String) {
        let item = add(menu, text)
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
    }
    func submenu(_ menu: NSMenu, _ title: String) -> NSMenu {
        let child = NSMenu()
        add(menu, title).submenu = child
        return child
    }
    func issueRow(_ menu: NSMenu, _ issue: Issue, future: Bool) {
        let applied = state.markedApplications.contains(issue.id)
        let prefix = future ? "\(issue.applyDate.suffix(5))  " : ""
        let status = state.paidIssues.contains(issue.id) ? " · 已缴款" : (state.wonIssues.contains(issue.id) ? " · 已中签" : "")
        let row = add(menu, "\(prefix)\(applied ? "✓ " : "")\(issue.name)  ·  \(issue.applyCode)\(status)")
        let submenu = NSMenu()
        heading(submenu, issue.name)
        add(submenu, "\(issue.kind.label) · \(issue.market) · \(issue.applyDate)")
        add(submenu, "申购代码：\(issue.applyCode)  /  证券代码：\(issue.securityCode)")
        add(submenu, "发行价：\(issue.priceText)")
        if let paymentDate = issue.paymentDate { add(submenu, "预计缴款日：\(paymentDate)") }
        if let listingDate = issue.listingDate { add(submenu, "预计上市日：\(listingDate)") }
        let cancelLabel = state.wonIssues.contains(issue.id) ? "取消已申购及中签/缴款标记" : "取消已申购标记"
        let mark = add(submenu, applied ? cancelLabel : "标记已申购", action: #selector(toggleApplied(_:)), value: issue.id)
        mark.state = applied ? .on : .off
        if issue.market != "北交所", issue.applyDate <= ChinaClock.day() {
            let won = add(submenu, state.wonIssues.contains(issue.id) ? "取消已中签及缴款标记" : "标记已中签（券商核实后）", action: #selector(toggleWon(_:)), value: issue.id)
            won.state = state.wonIssues.contains(issue.id) ? .on : .off
            let paid = add(submenu, state.paidIssues.contains(issue.id) ? "取消已缴款标记" : "标记已缴款", action: #selector(togglePaid(_:)), value: issue.id)
            paid.state = state.paidIssues.contains(issue.id) ? .on : .off
            if let status = PaymentFollowUp.status(issue, state: state) { add(submenu, status) }
        }
        if let upper = issue.upperLimit { add(submenu, "申购上限：\(upper.formatted()) 股") }
        if issue.market == "北交所" { add(submenu, "北交所申购需预缴资金及相应交易权限") }
        submenu.addItem(.separator())
        add(submenu, "复制申购代码", action: #selector(copyCode(_:)), value: issue.applyCode)
        add(submenu, "打开同花顺", action: #selector(openTHS(_:)))
        row.submenu = submenu
    }
    func listingRow(_ menu: NSMenu, _ issue: Issue) {
        guard let security = issue.marketSecurity else {
            issueRow(menu, issue, future: false)
            return
        }
        let quote = market.model.quote(for: security) ?? MarketQuote(security: security, name: issue.name,
            price: nil, percent: nil, change: nil, netInflow: nil, updatedAt: nil)
        add(menu, "\(issue.name)  ·  \(security.code)  ·  \(issue.kind.label)",
            action: #selector(showIssueDetail(_:)), value: quote)
    }
    func rebuildMenu() {
        guard statusItem != nil else { return }
        let today = state.today()
        let pendingCount = today.filter { !state.markedApplications.contains($0.id) }.count
        let old = state.feeds.contains { ChinaClock.day($0.fetchedAt) != ChinaClock.day() }
        var calendarNotices: [String] = []
        if old { calendarNotices.append("部分数据为历史缓存，请刷新确认") }
        for kind in IssueKind.allCases where errors[kind] != nil {
            let sameDay = state.feeds.contains { $0.kind == kind && ChinaClock.day($0.fetchedAt) == ChinaClock.day() }
            calendarNotices.append(sameDay ? "⚠ \(kind.label)查询失败，使用今日缓存并重试" : "⚠ \(kind.label)查询失败，稍后重试")
        }
        var tooltip = ["申购提醒  ·  \(ChinaClock.day())", "每日 09:30 / 14:30  ·  北京时间"]
        if fetching { tooltip.append("正在更新申购日历…") }
        else if let date = state.feeds.map(\.fetchedAt).max() { tooltip.append("更新于 \(ChinaClock.day(date)) \(ChinaClock.time(date))") }
        tooltip.append("今日申购：共 \(today.count) 只，待申购 \(pendingCount) 只")
        tooltip.append(contentsOf: calendarNotices)
        tooltip.append("提醒事项：申购、中签缴款与上市")
        tooltip.append(TradingCalendar.status())
        tooltip.append(marketHealthLabel)
        if let button = statusItem.button { StatusBarText.configure(button, count: pendingCount) }
        statusItem.button?.setAccessibilityLabel("申购提醒，今日待申购新股和可转债共 \(pendingCount) 只")
        statusItem.button?.toolTip = tooltip.joined(separator: "\n")
        let menu = NSMenu()
        menu.delegate = self
        let subscriptions = submenu(menu, "今日申购（\(today.count) 只）\(ChinaClock.isClosed() ? " · 已收盘" : "")")
        for notice in calendarNotices { add(subscriptions, notice) }
        if !calendarNotices.isEmpty { subscriptions.addItem(.separator()) }
        for kind in IssueKind.allCases {
            let items = today.filter { $0.kind == kind }
            heading(subscriptions, "\(kind.label)  \(items.count) 只")
            if items.isEmpty {
                let hasFresh = state.feeds.contains { $0.kind == kind && ChinaClock.day($0.fetchedAt) == ChinaClock.day() }
                add(subscriptions, hasFresh ? "今日暂无\(kind.label)申购\(errors[kind] != nil ? "（今日缓存）" : "")" : "暂未确认，请到同花顺查看")
            }
            for issue in items { issueRow(subscriptions, issue, future: false) }
        }
        let favorites = market.model.favoriteQuotes
        let favoritesMenu = submenu(menu, "自选股（\(favorites.count) 只）")
        add(favoritesMenu, "搜索添加股票或场内基金…", action: #selector(showFavoriteSearch(_:)))
        add(favoritesMenu, "基金走势与净值…", action: #selector(showFundDetails(_:)))
        add(favoritesMenu, "条件提醒…", action: #selector(showPriceAlerts(_:)))
        favoritesMenu.addItem(.separator())
        if favorites.isEmpty {
            add(favoritesMenu, "暂无自选股，可按名称或代码搜索添加")
        } else {
            for quote in favorites {
                let change = MarketText.number(quote.percent, signed: true, suffix: "%")
                let prefix = "\(quote.name)  ·  \(quote.security.code)  \(MarketText.number(quote.price))  "
                let time = quote.updatedAt.map { ChinaClock.day($0) == ChinaClock.day() ? ChinaClock.time($0) : MarketText.timestamp($0) } ?? "时间未知"
                let suffix = MarketRefreshSchedule.isStale(quote.updatedAt, at: Date()) ? " · 缓存" : ""
                let item = add(favoritesMenu, prefix + change + "  ·  " + time + suffix, action: #selector(showFavorite(_:)), value: quote.security.id)
                if let percent = quote.percent, percent != 0 {
                    let title = NSMutableAttributedString(string: item.title)
                    title.addAttribute(.foregroundColor, value: percent > 0 ? NSColor.systemRed : NSColor.systemGreen,
                                       range: NSRange(location: (prefix as NSString).length, length: (change as NSString).length))
                    item.attributedTitle = title
                }
            }
        }
        let calendarComplete = ReminderPlanner.effectiveSnapshots(state: state, results: lastResults, at: Date()).count == IssueKind.allCases.count
        let payments = state.todayPayment()
        let paymentsMenu = submenu(menu, "今日缴款（\(payments.count) 只）")
        if payments.isEmpty { add(paymentsMenu, calendarComplete ? "暂无今日缴款项目" : "日历尚未完整确认，请到同花顺核实") }
        else { add(paymentsMenu, "如已中签，请核实并按时备足资金") }
        for issue in payments { issueRow(paymentsMenu, issue, future: false) }
        let listings = state.todayListing()
        let listingsMenu = submenu(menu, "今日上市（\(listings.count) 只）")
        if listings.isEmpty { add(listingsMenu, calendarComplete ? "暂无今日上市项目" : "日历尚未完整确认，请到同花顺核实") }
        for issue in listings { listingRow(listingsMenu, issue) }
        let future = state.feeds.flatMap(\.issues).filter { $0.applyDate > ChinaClock.day() }.sorted { ($0.applyDate, $0.applyCode) < ($1.applyDate, $1.applyCode) }
        if !future.isEmpty {
            let upcoming = submenu(menu, "后续申购日历（\(future.count) 只）")
            for issue in future.prefix(60) { issueRow(upcoming, issue, future: true) }
        }
        menu.addItem(.separator())
        add(menu, "行情与排行榜…", action: #selector(showMarket(_:)))
        for index in MarketIndex.allCases {
            let quote = market.model.indexQuotes[index]
            let cached = market.model.indexErrors[index] != nil || quote?.updatedAt.map { ChinaClock.day($0) } != ChinaClock.day() || MarketRefreshSchedule.isStale(quote?.updatedAt, at: Date())
            let prefix = "\(index.name)  "
            let values = "\(MarketText.number(quote?.price))  \(MarketText.number(quote?.percent, signed: true, suffix: "%"))"
            let item = add(menu, prefix + values + (cached ? " · 缓存" : ""), action: #selector(showMarket(_:)), value: index.rawValue)
            if let percent = quote?.percent, percent != 0 {
                let title = NSMutableAttributedString(string: item.title)
                title.addAttribute(.foregroundColor, value: percent > 0 ? NSColor.systemRed : NSColor.systemGreen,
                                   range: NSRange(location: (prefix as NSString).length, length: (values as NSString).length))
                item.attributedTitle = title
            }
        }
        menu.addItem(.separator())
        add(menu, "立即刷新", action: #selector(refreshNow(_:))).isEnabled = !fetching
        let settings = add(menu, "设置")
        let settingsMenu = NSMenu()
        add(settingsMenu, "提醒时间：09:30、14:30（北京时间）")
        let empty = add(settingsMenu, "当天无申购时也通知", action: #selector(toggleEmpty(_:)))
        empty.state = state.notifyWhenEmpty ? .on : .off
        let payment = add(settingsMenu, "缴款提醒仅针对已申购项目", action: #selector(togglePaymentMarkedOnly(_:)))
        payment.state = state.onlyMarkedForPayment ? .on : .off
        let listing = add(settingsMenu, "上市提醒仅针对已申购项目", action: #selector(toggleListingMarkedOnly(_:)))
        listing.state = state.onlyMarkedForListing ? .on : .off
        let login = add(settingsMenu, "登录后自动启动", action: #selector(toggleLogin(_:)))
        login.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
        add(settingsMenu, "打开同花顺…", action: #selector(openTHS(_:)))
        add(settingsMenu, "选择同花顺客户端…", action: #selector(chooseTHS(_:)))
        add(settingsMenu, "发送测试通知", action: #selector(testNotification(_:)))
        add(settingsMenu, notificationAllowed ? "系统通知设置…" : "开启系统通知…", action: #selector(openNotificationSettings(_:)))
        add(settingsMenu, "查看运行记录", action: #selector(showLogs(_:)))
        addFeatureSettings(settingsMenu)
        settingsMenu.addItem(.separator())
        add(settingsMenu, "退出申购提醒", action: #selector(quit(_:)))
        settings.submenu = settingsMenu
        if !notificationAllowed {
            menu.addItem(.separator())
            add(menu, "⚠ 请允许通知，以便定时弹出提醒", action: #selector(openNotificationSettings(_:)))
        }
        menu.addItem(.separator())
        add(menu, "数据：东方财富 · 申购资格以券商为准")
        statusItem.menu = menu
    }

    @objc func copyCode(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
    @objc func toggleApplied(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.setApplied(id, !state.markedApplications.contains(id))
        store.save(state)
        rebuildMenu()
    }
    @objc func togglePaymentMarkedOnly(_ sender: Any?) {
        state.onlyMarkedForPayment.toggle(); store.save(state); rebuildMenu()
    }
    @objc func toggleListingMarkedOnly(_ sender: Any?) {
        state.onlyMarkedForListing.toggle(); store.save(state); rebuildMenu()
    }
    @objc func showMarket(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.representedObject as? String
        market.show(index: index.flatMap { MarketIndex(rawValue: $0) })
    }
    @objc func showFavorite(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let security = SecurityID.parse(raw),
              let quote = market.model.quote(for: security) else {
            market.show()
            return
        }
        market.showStock(quote)
    }
    @objc func showIssueDetail(_ sender: NSMenuItem) {
        guard let quote = sender.representedObject as? MarketQuote else { return }
        market.showStock(quote)
    }
    @objc func showFundDetails(_ sender: Any?) { market.stockDetail.funds.show() }
    @objc func showFavoriteSearch(_ sender: Any?) {
        favoriteSearch.show()
    }
    @objc func openTHS(_ sender: Any?) {
        if let path = state.thsPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        for root in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let apps = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            if let app = apps.first(where: { $0.pathExtension == "app" && ($0.lastPathComponent.contains("同花顺") || $0.lastPathComponent.lowercased().contains("hexin")) }) {
                state.thsPath = app.path
                store.save(state)
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "选择同花顺客户端"
        alert.informativeText = "没有找到本机的同花顺。你可以选择应用，或在手机同花顺中进入「交易 → 新股申购」查看申购清单。"
        alert.addButton(withTitle: "选择应用")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn { chooseTHS(nil) }
    }
    @objc func chooseTHS(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择同花顺客户端"
        panel.message = "选中同花顺 .app 后，以后可以从提醒中直接打开。"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.thsPath = url.path
            store.save(state)
        }
    }
    @objc func showDetails(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(ChinaClock.day()) 今日事项\(ChinaClock.isClosed() ? "（已收盘）" : "")"
        let complete = ReminderPlanner.effectiveSnapshots(state: state, results: lastResults, at: Date()).count == IssueKind.allCases.count
        let emptyText = complete ? "暂无项目" : "日历尚未完整确认，请到同花顺核实"
        var lines = ["今日申购"]
        let subscriptions = state.today().map { "\(state.markedApplications.contains($0.id) ? "[已申购] " : "")\($0.kind.label)：\($0.name)  \($0.applyCode)  发行价 \($0.priceText)" }
        lines += subscriptions.isEmpty ? [emptyText] : subscriptions
        lines.append("\n今日缴款（如已中签，请备足资金）")
        let payments = state.todayPayment().map { "\($0.kind.label)：\($0.name)  \($0.securityCode)  \(PaymentFollowUp.status($0, state: state) ?? "请核实是否中签")" }
        lines += payments.isEmpty ? [emptyText] : payments
        lines.append("\n今日上市")
        let listings = state.todayListing().map { "\($0.kind.label)：\($0.name)  \($0.securityCode)" }
        lines += listings.isEmpty ? [emptyText] : listings
        if !errors.isEmpty { lines.append("\n部分日历查询失败，展示已有缓存。") }
        lines.append("\n本工具无法查询个人中签结果。申购资格、缴款和上市安排以同花顺券商页面为准。")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "打开同花顺")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn { openTHS(nil) }
    }
    @objc func toggleEmpty(_ sender: Any?) {
        state.notifyWhenEmpty.toggle()
        store.save(state)
        rebuildMenu()
    }
    @objc func toggleLogin(_ sender: Any?) {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            do { try FileManager.default.removeItem(at: launchAgentURL) }
            catch { store.log("关闭登录启动失败：\(error.localizedDescription)") }
        } else {
            let config: [String: Any] = [
                "Label": bundleID,
                "ProgramArguments": [Bundle.main.executablePath!],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
                "ThrottleInterval": 30,
                "StandardOutPath": store.directory.appendingPathComponent("launch.out.log").path,
                "StandardErrorPath": store.directory.appendingPathComponent("launch.err.log").path
            ]
            do {
                try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
                try data.write(to: launchAgentURL, options: .atomic)
            } catch { store.log("设置登录启动失败：\(error.localizedDescription)") }
        }
        rebuildMenu()
    }
    @objc func testNotification(_ sender: Any?) {
        guard notificationAllowed else { openNotificationSettings(nil); return }
        let content = UNMutableNotificationContent()
        content.title = "申购提醒已就绪"
        content.body = "每天北京时间 09:30 和 14:30 检查新股与可转债。点击菜单栏「申购」查看清单。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.store.log(error.map { "测试通知失败：\($0.localizedDescription)" } ?? "已提交测试通知")
            }
        }
    }
    @objc func openNotificationSettings(_ sender: Any?) {
        if !notificationAllowed && !notificationDenied { requestNotifications(nil) }
        else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    @objc func showLogs(_ sender: Any?) { NSWorkspace.shared.open(store.directory) }
    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }
}

@main
struct SubscriptionReminder {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--market-check") {
            Task {
                let start = Date()
                let results = await MarketAPI.fetchAll()
                struct Check: Encodable {
                    let index: String
                    let memberCount: Int
                    let quote: MarketQuote?
                    let rankings: [String: [MarketQuote]]
                    let error: String?
                    let failedCodes: [String]
                }
                struct Report: Encodable { let elapsedSeconds: Double; let results: [Check] }
                let report = Report(elapsedSeconds: Date().timeIntervalSince(start), results: results.map { result in
                    Check(index: result.index.name, memberCount: result.snapshot?.memberCount ?? 0, quote: result.indexQuote,
                          rankings: Dictionary(uniqueKeysWithValues: RankingKind.allCases.map { ($0.title, result.snapshot?.ranked($0) ?? []) }), error: result.error, failedCodes: result.failedCodes)
                })
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(data: try! encoder.encode(report), encoding: .utf8)!)
                exit(results.allSatisfy { $0.snapshot != nil } ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if let position = CommandLine.arguments.firstIndex(of: "--stock-check") {
            guard CommandLine.arguments.count > position + 1, let security = SecurityID.parse(CommandLine.arguments[position + 1]) else {
                fputs("用法：--stock-check 1.600519（1=沪市，0=深市）\n", stderr); exit(2)
            }
            Task {
                do {
                    async let detail = MarketAPI.fetchDetail(security)
                    async let history = MarketAPI.fetchHistory(security)
                    struct Report: Encodable { let detail: StockDetail; let historyCount: Int; let recent: [DailyClose] }
                    let (value, bars) = try await (detail, history)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    print(String(data: try encoder.encode(Report(detail: value, historyCount: bars.count, recent: Array(bars.suffix(3)))), encoding: .utf8)!)
                    exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--check") {
            Task {
                let results = await IssueAPI.fetchAll()
                var state = AppState()
                for result in results { if let snapshot = result.snapshot { state.put(snapshot) } }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = (try? encoder.encode(state)) ?? Data()
                print(String(data: data, encoding: .utf8) ?? "{}")
                for result in results { if let error = result.error { fputs("\(result.kind.label)：\(error)\n", stderr) } }
                exit(results.allSatisfy { $0.error == nil } ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--notification-status") {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("authorizationStatus=\(settings.authorizationStatus.rawValue) alertStyle=\(settings.alertStyle.rawValue) alertSetting=\(settings.alertSetting.rawValue) soundSetting=\(settings.soundSetting.rawValue)")
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

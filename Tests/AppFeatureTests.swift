import AppKit
import SwiftUI

@main struct AppFeatureTests {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppFeatureTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = AppDelegate(store: Store(directory: directory))
        delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        delegate.statusItem.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        let now = ISO8601DateFormatter().date(from: "2026-10-22T10:00:00+08:00")!
        func quote(_ code: String, _ percent: Double, at time: Date = now) -> MarketQuote {
            MarketQuote(security: SecurityID(market: 1, code: code), name: percent > 0 ? "上涨测试股" : "下跌测试股", price: 12.34, percent: percent, change: nil, netInflow: nil, updatedAt: time)
        }
        let up = quote("600001", 3)
        let down = quote("600002", -2)
        try delegate.market.model.addFavorite(up)
        try delegate.market.model.addFavorite(down)
        let issue = Issue(kind: .stock, name: "待申购测试", securityCode: "688999", applyCode: "787999", applyDate: ChinaClock.day(), price: 20, market: "科创板", upperLimit: 1000, paymentDate: ChinaClock.day(), listingDate: ChinaClock.day())
        let bondIssue = Issue(kind: .bond, name: "待上市转债", securityCode: "127001", applyCode: "070001", applyDate: ChinaClock.addingDays(-1), price: 100, market: "可转债", upperLimit: nil, paymentDate: ChinaClock.day(), listingDate: ChinaClock.day())
        delegate.state.put(FeedSnapshot(kind: .stock, fetchedAt: now, issues: [issue]))
        delegate.state.put(FeedSnapshot(kind: .bond, fetchedAt: now, issues: [bondIssue]))
        delegate.rebuildMenu()
        var menu = delegate.statusItem.menu!
        check(delegate.statusItem.button?.image != nil && delegate.statusItem.button?.attributedTitle.string == "申购提醒①", "待申购时保留图标及同字体圈数字")
        check(menu.items.first?.submenu != nil && menu.items.first?.title.hasPrefix("今日申购") == true, "今日申购只占一行，右侧展开")
        check(!menu.items.contains { $0.title.hasPrefix("申购提醒") || $0.title.hasPrefix("每日") || $0.title.hasPrefix("更新于") }, "头部信息仅保留悬浮提示")
        let settings = menu.item(withTitle: "设置")!.submenu!
        check(settings.item(withTitle: "退出申购提醒") != nil && menu.item(withTitle: "退出申购提醒") == nil, "退出入口仍在设置")
        check(settings.item(withTitle: "导出设置与自选股…") != nil && settings.item(withTitle: "从备份恢复…") != nil, "备份恢复入口可见")
        check(settings.item(withTitle: "申购记录与中签管理")?.submenu != nil, "中签管理可随时进入")
        let favorites = menu.items.first { $0.title.hasPrefix("自选股") }!.submenu!
        check(favorites.item(withTitle: "搜索添加股票或场内基金…") != nil && favorites.item(withTitle: "条件提醒…") != nil && favorites.item(withTitle: "基金走势与净值…") != nil, "自选搜索和条件提醒在右侧")
        let upItem = favorites.items.first { $0.representedObject as? String == up.id }!
        let downItem = favorites.items.first { $0.representedObject as? String == down.id }!
        check(upItem.title.contains("12.34") && upItem.title.contains("10:00:00"), "自选菜单显示实际报价及时间")
        let redRange = (upItem.title as NSString).range(of: "+3.00%")
        let greenRange = (downItem.title as NSString).range(of: "-2.00%")
        check(upItem.attributedTitle?.attribute(.foregroundColor, at: redRange.location, effectiveRange: nil) as? NSColor == .systemRed, "上涨百分比仍用红色")
        check(downItem.attributedTitle?.attribute(.foregroundColor, at: greenRange.location, effectiveRange: nil) as? NSColor == .systemGreen, "下跌百分比仍用绿色")
        check(upItem.action == #selector(AppDelegate.showFavorite(_:)), "股票条目仍直接打开详情")
        let listings = menu.items.first { $0.title.hasPrefix("今日上市") }!.submenu!
        let stockListing = listings.items.first { ($0.representedObject as? MarketQuote)?.security.code == "688999" }
        let bondListing = listings.items.first { ($0.representedObject as? MarketQuote)?.security.code == "127001" }
        check(stockListing?.action == #selector(AppDelegate.showIssueDetail(_:)) && stockListing?.submenu == nil,
              "今日上市新股可直接点击打开详情")
        check((stockListing?.representedObject as? MarketQuote)?.security.market == 1,
              "沪市上市新股详情使用正确证券代码")
        check(bondListing?.action == #selector(AppDelegate.showIssueDetail(_:)) && bondListing?.submenu == nil,
              "今日上市可转债可直接点击打开详情")
        check((bondListing?.representedObject as? MarketQuote)?.security.market == 0,
              "深市上市转债详情使用正确证券代码")
        let action = NSMenuItem(); action.representedObject = issue.id
        delegate.toggleApplied(action)
        check(delegate.statusItem.button?.image != nil && delegate.statusItem.button?.attributedTitle.string == "申购提醒", "标记已申购后只隐藏数量，保留图标文字")
        delegate.toggleWon(action); delegate.togglePaid(action)
        check(delegate.state.paidIssues.contains(issue.id) && delegate.store.load().paidIssues.contains(issue.id), "菜单缴款操作确实落盘")
        delegate.rebuildMenu(); menu = delegate.statusItem.menu!
        let payments = menu.items.first { $0.title.hasPrefix("今日缴款") }!.submenu!
        check(payments.items.contains { $0.title.contains("已缴款") }, "今日缴款清单直接显示缴款状态")
        delegate.toggleApplied(action)
        check(delegate.state.wonIssues.isEmpty && delegate.state.paidIssues.isEmpty, "取消申购时清理中签及缴款")

        delegate.notificationStatusKnown = true; delegate.notificationAllowed = false
        let rule = PriceAlertRule(security: up.security, name: up.name, kind: .percentAbove, threshold: 3)
        delegate.state.priceAlerts = [rule]
        delegate.processExtraReminders(at: now)
        let blocked = delegate.state.permissionLogKeys
        delegate.processExtraReminders(at: now)
        check(blocked.count == 1 && delegate.state.permissionLogKeys == blocked, "同一条件无权限只记一次")
        check(delegate.state.sent[ChinaClock.day(now) + "@price"] == nil, "无权限不能消耗当天规则提醒")
        delegate.state.sent[ChinaClock.day(now) + "@price"] = [rule.token]
        delegate.state.permissionLogKeys = []
        delegate.processExtraReminders(at: now)
        check(delegate.state.permissionLogKeys.isEmpty, "已发规则在执行层不再提交通知")
        delegate.market.model.toggleFavorite(up.security)
        delegate.marketDidChange()
        check(delegate.state.priceAlerts.isEmpty && delegate.store.load().priceAlerts.isEmpty, "移除自选同时移除对应规则并保存")
        let backup = delegate.currentSettingsBackup()
        try backup.validate()
        check(backup.favorites == [down.security], "菜单导出使用当前自选设置")

        let rules = PriceAlertRulesModel()
        rules.update([PriceAlertRule(security: down.security, name: down.name, kind: .percentBelow, threshold: 3)], sent: [])
        let host = NSHostingView(rootView: PriceAlertRulesView(rules: rules, market: delegate.market.model, showStock: { _ in }, close: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; host.wantsLayer = true; host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("无法创建位图") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/price-alert-preview.png"))
        check(bitmap.pixelsWide >= 920, "条件提醒窗口实际完成布局与渲染")
        window.close()
        print("通过 \(checks) 项菜单及功能接入检查；未发送系统通知、未修改用户数据。")
    }
}

import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    func syncRuleWindow() {
        alertRules.update(state.priceAlerts, sent: state.sent[ChinaClock.day() + "@price"] ?? [])
    }
    func marketDidChange() {
        let existing = Set(market.model.favorites)
        let removed = state.priceAlerts.filter { !existing.contains($0.security) }
        if !removed.isEmpty {
            state.priceAlerts.removeAll { !existing.contains($0.security) }
            store.save(state)
            store.log("删除自选股时移除对应条件提醒：\(removed.count)条")
        }
        syncRuleWindow()
        rebuildMenu()
        processExtraReminders()
    }
    func marketRefreshCompleted(at now: Date = Date()) {
        lastMarketRound = now
        let before = state.marketHealth
        let success = market.model.errors.isEmpty && market.model.indexErrors.isEmpty &&
            market.model.snapshots.count == MarketIndex.allCases.count && market.model.snapshots.values.allSatisfy(\.isComplete)
        state.marketHealth.observe(success: success, latest: market.model.monitoringTime, at: now)
        if before != state.marketHealth { store.save(state) }
        if before.episode != state.marketHealth.episode {
            store.log(state.marketHealth.episode == nil ? "行情监测：已恢复，三个范围数据重新更新" : "行情监测：连续失败或数据延迟超过15分钟")
        }
        processExtraReminders(at: now)
    }
    func processExtraReminders(at now: Date = Date()) {
        guard notificationStatusKnown, TradingCalendar.isTradingDay(now) else { return }
        if TradingCalendar.isTradingTime(now) {
            let slot = ChinaClock.day(now) + "@price"
            let sent = Set(state.sent[slot] ?? [])
            if !state.priceAlerts.isEmpty {
                let quotes = Dictionary(uniqueKeysWithValues: market.model.favoriteQuotes.map { ($0.security, $0) })
                for rule in state.priceAlerts where !sent.contains(rule.token) {
                    guard let quote = quotes[rule.security], rule.matches(quote, at: now) else { continue }
                    let body = "\(rule.summary)\n现价 \(MarketText.number(quote.price))元，涨跌幅 \(MarketText.number(quote.percent, signed: true, suffix: "%"))\n行情时间 \(MarketText.timestamp(quote.updatedAt))"
                    notify(title: "\(quote.name) · 条件已满足", body: body, slot: slot, tokens: [rule.token], route: "stock", security: rule.security.id)
                }
            }
            if lastMarketRound != nil, !market.model.refreshing {
                let before = state.marketHealth
                state.marketHealth.checkDelay(latest: market.model.monitoringTime, at: now)
                if before != state.marketHealth { store.save(state); rebuildMenu() }
            }
            processMarketHealth(at: now)
        }
        if let slot = PaymentFollowUp.slot(at: now) {
            let pending = PaymentFollowUp.pending(state: state, at: now)
            if !pending.isEmpty {
                let lines = pending.prefix(6).map { "\($0.name) \($0.securityCode)" }
                notify(title: "中签待缴款：\(pending.count)只", body: (lines + ["你已标记中签，请核实可用资金。距16:00的参考截止时间渐近，具体以券商为准；缴款后请标记已缴款。"]).joined(separator: "\n"),
                       slot: slot, tokens: pending.map { "payment-followup:\($0.id)" })
            }
        }
    }
    func processMarketHealth(at now: Date) {
        guard state.notifyMarketHealth, state.marketHealth.day == ChinaClock.day(now) else { return }
        let slot = ChinaClock.day(now) + "@health"
        let sent = Set(state.sent[slot] ?? [])
        if let episode = state.marketHealth.episode, !sent.contains("health:\(episode)") {
            notify(title: "行情更新异常", body: "交易时段已连续查询失败3次，或行情已落后15分钟。当前保留最近数据，正在自动重试；点击查看行情与实际时间。", slot: slot, tokens: ["health:\(episode)"], route: "market")
        } else if let recovered = state.marketHealth.recoveredEpisode,
                  sent.contains("health:\(recovered)"), !sent.contains("recovered:\(recovered)") {
            notify(title: "行情更新已恢复", body: "三个范围的指数和完整榜单已重新更新。行情时间 \(MarketText.timestamp(market.model.monitoringTime))。", slot: slot, tokens: ["recovered:\(recovered)"], route: "market")
        }
    }
    var marketHealthLabel: String {
        guard state.marketHealth.day == ChinaClock.day() else { return "行情监测：尚未检查" }
        if state.marketHealth.episode != nil { return "⚠ 行情监测：数据更新异常" }
        if state.marketHealth.recoveredEpisode != nil { return "行情监测：已恢复" }
        return state.marketHealth.failures > 0 ? "行情监测：查询失败，正在重试" : "行情监测：正常"
    }
    func refreshTradingCalendar(force: Bool = false) {
        guard !calendarRefreshing else { return }
        let now = Date()
        if !force, ChinaClock.day(calendarLastAttempt) == ChinaClock.day(now),
           calendarLastError == nil || now.timeIntervalSince(calendarLastAttempt) < 3600 { return }
        calendarRefreshing = true; calendarLastAttempt = now
        Task {
            do {
                let value = try await TradingCalendar.refresh(directory: store.directory)
                calendarLastError = nil
                store.log("交易日历已更新：\(value.year)年，\(value.closedDays.count)个休市日期；来源上交所")
            } catch {
                calendarLastError = error.localizedDescription
                store.log("交易日历联网更新失败，继续使用已确认日历：\(error.localizedDescription)")
            }
            calendarRefreshing = false
            rebuildMenu()
        }
    }
    @objc func refreshCalendarNow(_ sender: Any?) { refreshTradingCalendar(force: true) }
    @objc func showPriceAlerts(_ sender: Any?) { syncRuleWindow(); priceAlertWindow.show() }
    @objc func toggleHealthAlerts(_ sender: Any?) {
        state.notifyMarketHealth.toggle(); store.save(state); rebuildMenu(); processExtraReminders()
    }
    @objc func toggleWon(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.setWon(id, !state.wonIssues.contains(id))
        store.save(state); rebuildMenu(); processExtraReminders()
    }
    @objc func togglePaid(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.setPaid(id, !state.paidIssues.contains(id))
        store.save(state); rebuildMenu()
    }
    func addFeatureSettings(_ menu: NSMenu) {
        menu.addItem(.separator())
        add(menu, "自选股条件提醒…", action: #selector(showPriceAlerts(_:)))
        let records = submenu(menu, "申购记录与中签管理")
        add(records, "中签由你在券商核实后手动标记")
        let issues = state.knownIssues.filter { state.markedApplications.contains($0.id) }
        if issues.isEmpty { add(records, "暂无已申购记录，请先在申购项目中标记") }
        for issue in issues.prefix(120) { issueRow(records, issue, future: true) }
        if issues.count > 120 { add(records, "仅展示最近120条记录，全部记录会随设置备份") }
        let health = add(menu, "行情异常及恢复通知", action: #selector(toggleHealthAlerts(_:)))
        health.state = state.notifyMarketHealth ? .on : .off
        add(menu, marketHealthLabel, action: #selector(showMarket(_:)))
        let calendar = submenu(menu, "交易日历")
        add(calendar, TradingCalendar.status())
        if let value = TradingCalendar.schedule(for: Date()) { add(calendar, "日历确认时间：\(MarketText.timestamp(value.fetchedAt))") }
        if let error = calendarLastError { add(calendar, "联网更新失败：\(error)") }
        add(calendar, "更新交易日历", action: #selector(refreshCalendarNow(_:))).isEnabled = !calendarRefreshing
        add(calendar, "查看交易所休市安排", action: #selector(openCalendarSource(_:)))
        menu.addItem(.separator())
        add(menu, "导出设置与自选股…", action: #selector(exportSettings(_:)))
        add(menu, "从备份恢复…", action: #selector(importSettings(_:)))
    }
    @objc func openCalendarSource(_ sender: Any?) { NSWorkspace.shared.open(URL(string: TradingCalendar.source)!) }
    func currentSettingsBackup() -> SettingsBackup {
        SettingsBackup(state: state, favorites: market.model.favorites, quotes: market.model.favoriteQuotes)
    }
    func backupData(_ value: SettingsBackup) throws -> Data {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    func featureError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.runModal()
    }
    @objc func exportSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出申购提醒设置"
        panel.nameFieldStringValue = "申购提醒设置-\(ChinaClock.day()).json"
        panel.allowedContentTypes = [.json]
        panel.message = "包含自选股、条件提醒、申购/中签/缴款标记和提醒设置。"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self = self else { return }
            do {
                try self.backupData(self.currentSettingsBackup()).write(to: url, options: .atomic)
                self.store.log("已导出个人设置备份")
            } catch { self.featureError("导出失败", error.localizedDescription) }
        }
    }
    @objc func importSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "恢复申购提醒设置"; panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "用备份替换当前自选股、条件、标记和提醒设置。恢复前自动保存一份当前设置，行情及今日通知记录继续保留。"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self = self else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 2_000_000 else { throw FeedError(message: "备份超过2MB，请选择本工具导出的文件") }
                let backup = try SettingsBackup.decode(Data(contentsOf: url))
                let directory = self.store.directory.appendingPathComponent("Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let automatic = directory.appendingPathComponent("恢复前-\(ChinaClock.day())-\(UUID().uuidString).json")
                try self.backupData(self.currentSettingsBackup()).write(to: automatic, options: .atomic)
                self.state = try backup.restore(to: self.store.directory, current: self.state)
                self.market.model.reloadFavorites()
                self.syncRuleWindow(); self.rebuildMenu()
                self.store.log("已恢复个人设置；恢复前备份位于 \(automatic.lastPathComponent)")
                self.featureError("设置已恢复", "已恢复\(backup.favorites.count)只自选股、\(backup.priceAlerts.count)条条件和\(backup.markedApplications.count)条申购标记。恢复前的设置保存在运行数据目录的 Backups 中。")
            } catch { self.featureError("恢复失败", "\(error.localizedDescription)\n请检查备份文件；恢复前备份可在运行数据目录的 Backups 中查看。") }
        }
    }
}

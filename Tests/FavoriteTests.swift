import AppKit
import SwiftUI

@main struct FavoriteTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError(message) } catch { checks += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FavoriteTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MarketModel(directory: directory)
        let stock = StockSearchResult(security: SecurityID(market: 0, code: "920001"), name: "纬达光电", marketName: "京A")
        var changes = 0
        model.onChange = { changes += 1 }
        try model.addFavorite(stock.placeholderQuote)
        check(model.favorites == [stock.security] && changes == 1, "搜索添加应立即存储并通知菜单更新")
        check(model.favoriteQuotes.first?.name == stock.name && model.snapshots.isEmpty, "非指数成分股也必须显示")
        check(model.quote(for: stock.security)?.name == stock.name, "范围外自选必须能打开详情")
        try model.addFavorite(stock.placeholderQuote)
        check(model.favorites.count == 1 && changes == 1, "重复添加必须幂等，不能变成取消自选")
        let reloaded = MarketModel(directory: directory)
        check(reloaded.favorites == [stock.security] && reloaded.favoriteQuotes.first?.name == stock.name, "重启后代码和名称必须保留")
        check(reloaded.favoriteQuotes.first?.price == nil, "没有行情时不可显示虚假价格")
        let now = Date()
        func quote(_ price: Double, at date: Date) -> MarketQuote {
            MarketQuote(security: stock.security, name: stock.name, price: price, percent: 2, change: 0.2, netInflow: 300, updatedAt: date)
        }
        reloaded.updateFavoriteQuotes([quote(12, at: now)])
        check(reloaded.favoriteQuotes.first?.price == 12, "独立自选行情应更新列表")
        reloaded.updateFavoriteQuotes([])
        check(reloaded.favoriteQuotes.first?.price == 12, "查询失败或空批次不能清除旧行情")
        reloaded.updateFavoriteQuotes([quote(9, at: now.addingTimeInterval(-60))])
        check(reloaded.quote(for: stock.security)?.price == 12, "旧响应不能覆盖较新的自选行情")
        let index = MarketIndex.csi300
        reloaded.snapshots[index] = MarketSnapshot(index: index, quote: quote(12, at: now), stocks: [quote(13, at: now.addingTimeInterval(60))], memberCount: 1, fetchedAt: now)
        check(reloaded.favoriteQuotes.first?.price == 13 && reloaded.quote(for: stock.security)?.price == 13, "成分缓存和自选缓存必须选较新行情")
        check(MarketModel(directory: directory).favoriteQuotes.first?.price == 12, "独立行情缓存应能从磁盘恢复")
        reloaded.toggleFavorite(stock.security)
        check(reloaded.favorites.isEmpty && MarketModel(directory: directory).favorites.isEmpty, "取消自选后应持久化删除")
        reloaded.updateFavoriteQuotes([quote(14, at: now.addingTimeInterval(120))])
        check(reloaded.favoriteCache.isEmpty, "添加时未完成的查询不能复活已删除的自选")

        let legacy = SecurityID(market: 0, code: "000001")
        try JSONEncoder().encode([legacy, legacy]).write(to: model.preferencesURL, options: .atomic)
        let legacyModel = MarketModel(directory: directory)
        check(legacyModel.favorites == [legacy], "旧格式自选列表兼容并去重")
        check(legacyModel.favoriteQuotes.first?.security == legacy && legacyModel.quote(for: legacy) != nil, "旧自选没有名称缓存时仍须展示并可查看详情")

        try FileManager.default.removeItem(at: model.preferencesURL)
        try FileManager.default.createDirectory(at: model.preferencesURL, withIntermediateDirectories: false)
        let blocked = MarketModel(directory: directory)
        rejects("列表保存失败必须返回错误") { try blocked.addFavorite(stock.placeholderQuote) }
        check(blocked.favorites.isEmpty && blocked.favoriteQuotes.isEmpty, "列表写入失败不能假装添加成功")
        check(MarketModel(directory: directory).favorites.isEmpty, "孤立缓存不能在下次启动时变成自选")
        try FileManager.default.removeItem(at: model.preferencesURL)
        try FileManager.default.removeItem(at: model.favoriteCacheURL)
        try FileManager.default.createDirectory(at: model.favoriteCacheURL, withIntermediateDirectories: false)
        rejects("名称缓存失败也不能添加成功") { try blocked.addFavorite(stock.placeholderQuote) }
        check(!FileManager.default.fileExists(atPath: model.preferencesURL.path), "名称保存失败不能留下丢失名称的列表")
        print("通过 \(checks) 项自选股检查：添加、去重、范围外股票、重启恢复、行情合并、删除、旧格式与写入失败。")
    }
}

import AppKit
import SwiftUI

@MainActor
final class PriceAlertRulesModel: ObservableObject {
    @Published private(set) var rules: [PriceAlertRule] = []
    @Published var sentTokens: Set<String> = []
    @Published var error: String?
    var onEdit: (([PriceAlertRule]) -> Void)?
    func update(_ value: [PriceAlertRule], sent: [String]) {
        rules = value; sentTokens = Set(sent)
    }
    func add(quote: MarketQuote, kind: PriceAlertKind, input: String) {
        guard let threshold = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "请输入有效数字，例如 12.50 或 3。"; return
        }
        let rule = PriceAlertRule(security: quote.security, name: quote.name, kind: kind, threshold: threshold)
        guard rule.isValid, rules.count < 500 else {
            error = "价格请输入0到100万元之间的正数；涨跌幅请输入0到100之间的正数。最多保存500条。"; return
        }
        guard !rules.contains(where: { $0.security == rule.security && $0.kind == kind && $0.threshold == threshold }) else {
            error = "已存在相同条件，可直接开启已有提醒。"; return
        }
        error = nil; onEdit?(rules + [rule])
    }
    func setEnabled(_ id: String, _ enabled: Bool) {
        var updated = rules
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].enabled = enabled; onEdit?(updated)
    }
    func remove(_ id: String) { onEdit?(rules.filter { $0.id != id }) }
}

struct PriceAlertRulesView: View {
    @ObservedObject var rules: PriceAlertRulesModel
    @ObservedObject var market: MarketModel
    var showStock: (MarketQuote) -> Void
    var close: () -> Void
    @State private var selected = ""
    @State private var kind = PriceAlertKind.priceAbove
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自选股条件提醒").font(.title2.bold())
            Text("交易时段随行情刷新检查；同一条件每天只通知一次，重启后也不会重复。点击通知可打开股票详情。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker("股票", selection: $selected) {
                    Text("选择自选股").tag("")
                    ForEach(market.favoriteQuotes) { quote in
                        Text("\(quote.name) \(quote.security.code)").tag(quote.id)
                    }
                }.frame(width: 250)
                Picker("条件", selection: $kind) {
                    ForEach(PriceAlertKind.allCases) { value in Text(value.title).tag(value) }
                }.frame(width: 210)
                TextField(kind.isPercent ? "例如 3" : "例如 12.50", text: $input).frame(width: 95)
                Text(kind.isPercent ? "%" : "元").foregroundStyle(.secondary)
                Button("添加") {
                    guard let quote = market.favoriteQuotes.first(where: { $0.id == selected }) else { return }
                    rules.add(quote: quote, kind: kind, input: input)
                    if rules.error == nil { input = "" }
                }.disabled(selected.isEmpty || input.isEmpty)
            }
            Text("跌幅填正数，例如填3表示跌至 −3%。条件满足即提醒；添加时已满足的条件也会提醒。删除自选股会同时移除其条件。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = rules.error { Text(error).foregroundStyle(.red).font(.callout) }
            Divider()
            if rules.rules.isEmpty {
                Spacer()
                Text(market.favorites.isEmpty ? "请先在菜单「自选股 → 搜索添加股票或场内基金」加入股票。" : "尚未设置条件提醒。请选择股票并添加条件。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rules.rules) { rule in
                            HStack(spacing: 12) {
                                Toggle("启用", isOn: Binding(get: { rule.enabled }, set: { rules.setEnabled(rule.id, $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(rule.name)  ·  \(rule.security.code)").font(.headline)
                                    Text(rule.summary).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(!rule.enabled ? "已停用" : (rules.sentTokens.contains(rule.token) ? "今日已提醒" : "待触发"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("详情") { if let quote = market.quote(for: rule.security) { showStock(quote) } }
                                Button("删除") { rules.remove(rule.id) }
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Text("提醒使用公开行情，数据时间落后超过6分钟时不触发。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 850, minHeight: 460)
        .onChange(of: market.favorites) { favorites in
            if !favorites.contains(where: { $0.id == selected }) { selected = "" }
        }
    }
}

@MainActor
final class PriceAlertWindowController {
    private(set) var window: NSWindow?
    let rules: PriceAlertRulesModel
    let market: MarketModel
    let showStock: (MarketQuote) -> Void
    init(rules: PriceAlertRulesModel, market: MarketModel, showStock: @escaping (MarketQuote) -> Void) {
        self.rules = rules; self.market = market; self.showStock = showStock
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "申购提醒 · 自选股条件提醒"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 500)
            window.contentView = NSHostingView(rootView: PriceAlertRulesView(rules: rules, market: market,
                showStock: showStock, close: { [weak self] in self?.window?.close() }))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

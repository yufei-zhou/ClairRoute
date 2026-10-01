import SwiftUI

struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    @State private var filter = ""
    @State private var selected: String?
    private var rows: [ConnectionSnapshot] {
        model.connections.filter { filter.isEmpty || [$0.process, $0.processPath, $0.host, $0.destinationIP, $0.rule, $0.chains.joined(separator: " ")].contains(where: { $0.localizedCaseInsensitiveContains(filter) }) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(rows.count) 条连接").font(.headline)
                Spacer(); TextField("搜索进程、域名或节点", text: $filter).frame(width: 240)
            }
            if !model.status.coreRunning {
                ContentUnavailableView("内核尚未运行", systemImage: "network")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selected) {
                    TableColumn("进程") { row in Text(row.process.isEmpty ? "未识别" : row.process).help(row.processPath) }.width(min: 90, ideal: 120)
                    TableColumn("目标") { row in Text((row.host.isEmpty ? row.destinationIP : row.host) + ":\(row.destinationPort)").lineLimit(1).help(row.destinationIP) }.width(min: 140, ideal: 200)
                    TableColumn("网络", value: \.network).width(55)
                    TableColumn("命中规则") { row in Text(ruleLabel(row)).lineLimit(1) }
                    TableColumn("出站") { row in Text(chainLabel(row.chains)).lineLimit(1).help(chainLabel(row.chains)) }
                }.contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        Button("为此进程添加规则") { model.ruleForProcess(row) }.disabled(row.process.isEmpty && row.processPath.isEmpty)
                        Button("为此域名添加规则") { model.addRule(RoutingRule(kind: .domain, value: row.host)) }.disabled(row.host.isEmpty)
                    }
                }
                if let selected, let row = rows.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.processPath.isEmpty ? "进程路径不可用" : row.processPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("\(row.destinationIP):\(row.destinationPort) · ↑ \(bytes(row.upload)) · ↓ \(bytes(row.download))").font(.caption)
                        HStack {
                            Button("为此进程添加规则") { model.ruleForProcess(row) }.disabled(row.process.isEmpty && row.processPath.isEmpty)
                            Button("为此域名添加规则") { model.addRule(RoutingRule(kind: .domain, value: row.host)) }.disabled(row.host.isEmpty)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(22)
        .onAppear { model.connectionPanelVisible = true }
        .onDisappear { model.connectionPanelVisible = false }
    }
    private func ruleLabel(_ row: ConnectionSnapshot) -> String {
        if !row.rule.isEmpty { return row.rule + (row.rulePayload.isEmpty ? "" : ": " + row.rulePayload) }
        if row.chains.contains("GLOBAL") { return "全局模式" }
        switch model.mode {
        case .global: return "全局模式"
        case .direct: return "直连模式"
        case .rule: return "规则信息不可用"
        }
    }
    private func chainLabel(_ chains: [String]) -> String {
        let visible = chains.filter { name in
            guard name.hasPrefix("NODE_"), name.utf8.count == 41,
                  let id = UUID(uuidString: String(name.dropFirst(5))) else { return true }
            return String(name.dropFirst(5)).lowercased() != id.uuidString.lowercased()
        }
        // Preserve the original data, and keep a useful fallback if there is no
        // readable wrapper in an incomplete core snapshot.
        let display = visible.isEmpty ? chains : visible
        return display.isEmpty ? "未识别" : display.joined(separator: " → ")
    }
    private func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary) }
}

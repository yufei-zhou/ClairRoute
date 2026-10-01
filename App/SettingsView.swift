import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel
    private let pages = [("运行", "power"), ("节点与订阅", "server.rack"), ("规则", "line.3.horizontal.decrease.circle"), ("连接", "point.3.connected.trianglepath.dotted"), ("高级与维护", "gearshape")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("ClairRoute", systemImage: "network").font(.title2.weight(.semibold)).padding(.bottom, 24)
                ForEach(pages, id: \.0) { page in
                    Button {
                        model.selectedPage = page.0
                    } label: {
                        Label(page.0, systemImage: page.1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .background(model.selectedPage == page.0 ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("page-" + page.0)
                }
                Spacer()
                Label(model.phaseLabel, systemImage: model.systemSymbol).foregroundStyle(model.status.coreRunning ? .green : .primary)
            }.padding(20).frame(width: 190).background(.bar)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(model.selectedPage).font(.title2.bold())
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("应用配置") { Task { await model.applySavedConfiguration() } }
                        .buttonStyle(.borderedProminent).disabled(model.busy || library.migrationRequired)
                }.padding(24)
                Divider()
                if library.migrationRequired {
                    HStack(spacing: 12) {
                        Text("旧凭据需从钥匙串迁移到本机配置文件。")
                        Spacer()
                        Button("迁移旧配置") { model.perform { try library.migrateLegacyCredentials() } }
                            .disabled(model.busy)
                    }.padding(16).background(.orange.opacity(0.09))
                }
                Group {
                    switch model.selectedPage {
                    case "节点与订阅": LibraryView(model: model, library: library).disabled(library.migrationRequired)
                    case "规则": RulesView(model: model, library: library).disabled(library.migrationRequired)
                    case "连接": ConnectionsView(model: model)
                    case "高级与维护": AdvancedView(model: model, library: library)
                    default: runtime
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.error ?? library.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled).lineLimit(4)
                        Spacer()
                        Button("关闭") { model.error = nil }
                    }.font(.callout).padding(14).background(.orange.opacity(0.09))
                }
            }
        }.frame(minWidth: 1000, minHeight: 700)
        .onChange(of: model.selectedPage) { _, page in model.connectionPanelVisible = page == "连接" }
    }
    private var runtime: some View {
        Form {
            Section("流量接管") {
                Toggle("增强模式（TUN）", isOn: Binding(get: { model.status.tunEnabled }, set: { v in Task { await model.setTUN(v) } }))
                Toggle("系统代理", isOn: Binding(get: { model.status.systemProxyEnabled }, set: { v in Task { await model.setSystemProxy(v) } }))
            }.disabled(!model.signed || model.busy || library.migrationRequired)
            Section("出站策略") {
                Picker("模式", selection: Binding(get: { model.mode }, set: { v in Task { await model.changeMode(v) } })) {
                    Text("规则").tag(OutboundMode.rule); Text("全局").tag(OutboundMode.global); Text("直连").tag(OutboundMode.direct)
                }.pickerStyle(.segmented).disabled(model.busy || library.migrationRequired)
                LabeledContent("当前节点", value: library.selectedNode ?? library.nodes.first?.name ?? "尚未添加")
                LabeledContent("用户规则", value: "\(library.rules.count) 条 · 兜底 \(library.fallbackPolicy)")
            }
            Section("运行状态") {
                LabeledContent("Helper", value: model.helperConnected ? "已连接并验签" : "未连接")
                LabeledContent("内核", value: model.status.coreVersion ?? "未启动")
                LabeledContent("恢复记录", value: !model.helperConnected ? "尚未确认" : (model.status.recoveryPending ? "待恢复" : "无待恢复修改"))
                if model.status.recoveryPending || model.status.phase == .needsAttention {
                    Text(model.status.message).font(.callout).textSelection(.enabled)
                }
                HStack {
                    Button("读取状态") { Task { await model.refreshStatus() } }
                    Button("恢复网络并关闭代理") { Task { _ = await model.stopAndRestore() } }.disabled(model.busy)
                }
            }
            Section("限时网络验收") {
                Button("开始 120 秒系统代理验收") { Task { await model.startLimitedSystemProxyTrial() } }
                    .disabled(!model.signed || model.busy || model.status.coreRunning || library.migrationRequired)
                Button("开始 120 秒 TUN 验收") { Task { await model.startLimitedTrial() } }
                    .disabled(!model.signed || model.busy || model.status.coreRunning || library.migrationRequired)
            }
            if !model.signed {
                Section { Text("未安装签名版本，网络开关不可用。") }
            }
        }.formStyle(.grouped)
    }
}

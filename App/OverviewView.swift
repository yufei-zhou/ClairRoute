import SwiftUI

/// Home page: current state, the two takeover switches, outbound mode and recovery.
struct OverviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel

    private var editingLocked: Bool { model.busy || library.migrationRequired }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: model.statusSymbol)
                        .font(.system(size: 30))
                        .foregroundStyle(model.statusTint)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.phaseLabel).font(.title3.weight(.semibold))
                        if model.needsAttention || (model.signed && !model.helperConnected) {
                            Text(model.statusDetail).font(.callout).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }

            Section("流量接管") {
                Toggle(isOn: Binding(get: { model.status.tunEnabled }, set: { value in Task { await model.setTUN(value) } })) {
                    Text("增强模式（TUN）")
                }
                Toggle(isOn: Binding(get: { model.status.systemProxyEnabled }, set: { value in Task { await model.setSystemProxy(value) } })) {
                    Text("系统代理")
                }
            }
            .disabled(!model.signed || editingLocked)

            Section {
                Picker("出站模式", selection: Binding(get: { model.mode }, set: { value in Task { await model.changeMode(value) } })) {
                    Text("规则").tag(OutboundMode.rule)
                    Text("全局").tag(OutboundMode.global)
                    Text("直连").tag(OutboundMode.direct)
                }
                .pickerStyle(.segmented)
                .disabled(editingLocked)
                LabeledContent("当前节点", value: (library.selectedNode ?? library.nodes.first(where: model.nodeIsEnabled)?.name).map(model.policyLabel) ?? "尚未添加")
                LabeledContent("规则", value: "\(library.rules.count) 条自定义规则 · 其余流量 \(model.policyLabel(library.fallbackPolicy))")
            } header: {
                Text("出站策略")
            }

            Section("后台服务") {
                LabeledContent("Helper", value: !model.signed ? "未安装" : (model.helperConnected ? "已连接并验证签名" : "未连接"))
                LabeledContent("内核", value: model.status.coreRunning ? "mihomo " + (model.status.coreVersion ?? AppConstants.coreVersion) : "未运行")
                LabeledContent("恢复记录", value: !model.helperConnected ? "尚未确认" : (model.status.recoveryPending ? "有待恢复的修改" : "无"))
                HStack {
                    Button("刷新状态", systemImage: "arrow.clockwise") { Task { await model.refreshStatus() } }
                    Button("恢复网络并关闭代理", systemImage: "arrow.uturn.backward") { Task { _ = await model.stopAndRestore() } }
                        .disabled(model.busy)
                }
            }
            .disabled(!model.signed)

            Section {
                Button("开始 120 秒系统代理验收") { Task { await model.startLimitedSystemProxyTrial() } }
                Button("开始 120 秒 TUN 验收") { Task { await model.startLimitedTrial() } }
            } header: {
                Text("限时验收")
            }
            .disabled(!model.signed || editingLocked || model.status.coreRunning)
        }
        .formStyle(.grouped)
    }
}

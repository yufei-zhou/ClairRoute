import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel
    @State private var editor: ProxyNode?
    @State private var importing = false
    @State private var subscriptionSheet = false
    @State private var editingSubscription: SubscriptionMetadata?
    @State private var importText = ""
    @State private var importError: String?
    @State private var filter = ""
    @State private var subscriptionToDelete: SubscriptionMetadata?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("添加节点", systemImage: "plus") { editor = ProxyNode(name: "新节点", server: "", port: 443, cipher: "aes-256-gcm", password: "") }
                Button("导入 URI / YAML", systemImage: "square.and.arrow.down") { importError = nil; importing = true }
                Button("添加订阅", systemImage: "link.badge.plus") { subscriptionSheet = true }
                Spacer()
                TextField("搜索节点", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if !library.subscriptions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("订阅").font(.headline)
                    ForEach(library.subscriptions, id: \.id) { subscription in
                        HStack {
                            Toggle(subscription.name, isOn: Binding(get: { subscription.enabled }, set: { value in model.perform { try library.setSubscriptionEnabled(id: subscription.id, enabled: value) } }))
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading) {
                                Text(usage(subscription)).font(.caption)
                                Text(subscription.lastUpdated.map { "更新于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未刷新，点击「刷新」下载节点").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if library.refreshing.contains(subscription.id) { ProgressView().controlSize(.small) }
                            Button("刷新") { Task { await model.refreshSubscription(subscription.id) } }.disabled(library.refreshing.contains(subscription.id))
                            Button("设置") { editingSubscription = subscription }
                            Button(role: .destructive) { subscriptionToDelete = subscription } label: { Image(systemName: "trash") }.help("删除订阅及其节点")
                        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if library.nodes.isEmpty {
                // ContentUnavailableView is not greedy on macOS; without a flexible frame the
                // whole page collapsed and floated in the middle of the window.
                ContentUnavailableView {
                    Label("还没有节点", systemImage: "server.rack")
                } description: {
                    Text("添加订阅，或导入 ss://、vmess://、vless:// 链接和 Clash YAML。")
                } actions: {
                    Button("添加订阅") { subscriptionSheet = true }
                    Button("导入 URI / YAML") { importError = nil; importing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AutoSelectPanel(model: model, library: library)
                let candidates = Set(library.autoSelectCandidates)
                let automatic = !candidates.isEmpty
                List {
                    ForEach(library.nodes.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }, id: \.id) { node in
                        let inUse = automatic ? model.autoSelectedNode == node.name : library.selectedNode == node.name
                        HStack(spacing: 12) {
                            Image(systemName: inUse ? "checkmark.circle.fill" : "circle").foregroundStyle(inUse ? Color.accentColor : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(model.policyLabel(node.name)).font(.headline)
                                        .lineLimit(1).truncationMode(.middle).help(model.policyLabel(node.name))
                                    if candidates.contains(node.name) {
                                        Text("自动候选").font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text("\(node.type.rawValue.uppercased()) · \(node.server):\(node.port)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            Text(model.delays[node.name] ?? "—").monospacedDigit().font(.caption).frame(width: 70)
                                .accessibilityLabel("延迟：" + (model.delays[node.name] ?? "尚未测速"))
                            Button("测速") { Task { await model.measureDelay(node.name) } }.disabled(!model.status.coreRunning || !model.nodeIsEnabled(node))
                                .frame(width: 50)
                                .accessibilityLabel("测速 " + node.name)
                                .accessibilityIdentifier("node.delay." + node.id.uuidString)
                            // While automatic selection is on, any node can be chosen to switch back to manual.
                            let chosen = !automatic && library.selectedNode == node.name
                            Button(chosen ? "已选择" : "使用") { Task { await model.chooseNode(node.name) } }
                                .frame(width: 50)
                                .disabled(model.busy || chosen || !model.nodeIsEnabled(node))
                                .help(automatic ? "改为手动使用此节点，并关闭自动选择" : "")
                                .accessibilityLabel("选择 " + node.name)
                                .accessibilityValue(inUse ? "已选中" : "未选中")
                                .accessibilityIdentifier("node.select." + node.id.uuidString)
                            Button(node.sourceID == nil ? "编辑" : "复制") {
                                do {
                                    var value = try library.readNode(id: node.id)
                                    if value.sourceID != nil { value.id = UUID(); value.sourceID = nil; value.name += "（副本）" }
                                    editor = value
                                } catch { model.error = error.localizedDescription }
                            }.frame(width: 50).accessibilityLabel((node.sourceID == nil ? "编辑 " : "复制 ") + node.name)
                            Button(role: .destructive) { model.perform { try library.removeNode(id: node.id) } } label: { Image(systemName: "trash") }
                                .help("删除节点；订阅节点请通过订阅管理").disabled(node.sourceID != nil)
                                .accessibilityLabel("删除节点 " + node.name)
                        }.padding(.vertical, 6)
                            .buttonStyle(.borderless)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("节点 " + node.name)
                    }
                }.listStyle(.inset)
            }
        }.padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editor) { node in NodeEditorView(node: node) { value in
            try library.saveNode(value); model.error = nil
        } }
        .sheet(isPresented: $importing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("导入节点").font(.title2.bold())
                TextEditor(text: $importText).font(.system(.body, design: .monospaced)).frame(height: 250).border(.quaternary)
                if let importError { Text(importError).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("选择文件…") {
                        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            do {
                                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                guard size <= 4 * 1024 * 1024 else { throw ClientError.rejected("导入文件超过 4 MiB 大小限制。") }
                                importText = try String(contentsOf: url, encoding: .utf8)
                                importError = nil
                            } catch { importError = "无法读取导入文件或文件超过大小限制。" }
                        }
                    }
                    Spacer(); Button("取消") { importText = ""; importing = false }
                    Button("导入") { do { try library.importText(importText); model.error = nil; importText = ""; importing = false } catch { importError = error.localizedDescription } }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 630)
        }
        .confirmationDialog("删除订阅“\(subscriptionToDelete?.name ?? "")”？", isPresented: Binding(get: { subscriptionToDelete != nil }, set: { if !$0 { subscriptionToDelete = nil } }), presenting: subscriptionToDelete) { subscription in
            Button("删除订阅及其节点", role: .destructive) { model.perform { try library.removeSubscription(id: subscription.id) } }
        } message: { _ in Text("该订阅下的所有节点和订阅规则会一起删除，此操作无法撤销。") }
        .sheet(isPresented: $subscriptionSheet) { SubscriptionEditor(library: library, subscription: nil) }
        .sheet(item: $editingSubscription) { subscription in SubscriptionEditor(library: library, subscription: subscription) }
    }
    private func usage(_ subscription: SubscriptionMetadata) -> String {
        guard let info = subscription.userInfo else { return "每 \(max(1, Int(subscription.refreshInterval / 3600))) 小时自动刷新" }
        let totalUsage = (info.upload ?? 0).addingReportingOverflow(info.download ?? 0)
        let used = totalUsage.overflow ? UInt64.max : totalUsage.partialValue
        var result = ByteCountFormatter.string(fromByteCount: Int64(clamping: used), countStyle: .binary)
        if let total = info.total { result += " / " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .binary) }
        if let expiry = info.expire { result += " · 到期 " + expiry.formatted(date: .abbreviated, time: .omitted) }
        return result
    }
}

/// Automatic selection among the first nodes of the selected node's subscription.
private struct AutoSelectPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel

    var body: some View {
        let settings = library.autoSelect
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                Toggle("自动选择节点", isOn: binding(\.enabled)).toggleStyle(.switch)
                    .help("定期检测当前订阅的前几个节点；保留 50 ms 容差，减少频繁切换。不会自动开启代理。")
                Stepper("候选：前 \(settings.candidateCount) 个", value: binding(\.candidateCount), in: AutoSelectSettings.candidateRange)
                    .fixedSize()
                Picker("检测间隔", selection: binding(\.interval)) {
                    ForEach(AutoSelectSettings.intervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
                }.fixedSize()
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .disabled(model.busy)
            if settings.enabled {
                Text(detail(settings)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(library.autoSelectCandidates.joined(separator: "\n"))
            }
        }
        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AutoSelectSettings, Value>) -> Binding<Value> {
        Binding(get: { library.autoSelect[keyPath: keyPath] }, set: { value in
            var next = library.autoSelect
            next[keyPath: keyPath] = value
            Task { await model.setAutoSelect(next) }
        })
    }

    private func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 || !seconds.isMultiple(of: 60) ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
    }

    private func detail(_ settings: AutoSelectSettings) -> String {
        let candidates = library.autoSelectCandidates
        guard settings.enabled, let first = candidates.first else {
            return "暂无可用候选节点"
        }
        let source = library.nodes.first(where: { $0.name == first })?.sourceID
        let group = source.flatMap { id in library.subscriptions.first(where: { $0.id == id })?.name } ?? "本地节点"
        let current = model.status.coreRunning
            ? "当前使用：" + (model.autoSelectedNode ?? "检测中…")
            : "开启代理后生效"
        return "\(current) · \(group) · \(candidates.count) 个候选"
    }
}

struct SubscriptionEditor: View {
    @ObservedObject var library: AppLibraryModel
    let subscription: SubscriptionMetadata?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var hours = 24
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(subscription == nil ? "添加订阅" : "订阅设置").font(.title2.bold())
            Form {
                TextField("名称", text: $name, prompt: Text("例如：我的订阅"))
                if subscription == nil { SecureField("HTTPS 订阅 URL", text: $url, prompt: Text("https://")) }
                Stepper("刷新间隔：\(hours) 小时", value: $hours, in: 1...720)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        if let subscription { try library.updateSubscription(id: subscription.id, name: name, interval: Double(hours * 3600)) }
                        else { try library.addSubscription(name: name, url: url, interval: Double(hours * 3600)) }
                        url = ""; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 530)
        .onAppear { if let subscription { name = subscription.name; hours = max(1, Int(subscription.refreshInterval / 3600)) } }
    }
}

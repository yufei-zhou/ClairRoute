import SwiftUI
import UniformTypeIdentifiers

struct RulesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel
    @State private var editor: RoutingRule?
    @State private var dragged: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("添加规则", systemImage: "plus") { editor = RoutingRule(kind: .domainSuffix, value: "", policy: "PROXY") }
                Spacer()
                Text("从上到下依次匹配，第一条命中的规则生效。可拖动排序。").font(.callout).foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(library.rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text("\(index + 1)").monospacedDigit().frame(width: 24)
                        Toggle("启用规则", isOn: Binding(get: { rule.enabled }, set: { value in
                            var updated = library.rules; updated[index].enabled = value
                            model.perform { try library.persistRules(updated) }
                        })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.value).font(.system(.body, design: .monospaced)).lineLimit(1).help(rule.value)
                            Text(rule.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Text(model.policyLabel(rule.policy)).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        Button("编辑") { editor = rule }
                        Button { model.perform { try library.moveRules(from: IndexSet(integer: index), to: max(0, index - 1)) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("上移")
                        Button { model.perform { try library.moveRules(from: IndexSet(integer: index), to: min(library.rules.count, index + 2)) } } label: { Image(systemName: "arrow.down") }.disabled(index == library.rules.count - 1).help("下移")
                        Button(role: .destructive) { model.perform { try library.persistRules(library.rules.filter { $0.id != rule.id }) } } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 6)
                    .onDrag { dragged = rule.id; return NSItemProvider(object: rule.id.uuidString as NSString) }
                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                        guard let dragged, let source = library.rules.firstIndex(where: { $0.id == dragged }), source != index else { return false }
                        model.perform { try library.moveRules(from: IndexSet(integer: source), to: source < index ? index + 1 : index) }
                        self.dragged = nil; return true
                    }
                }
                if !library.subscriptionRules.isEmpty {
                    Section("订阅规则") {
                        ForEach(library.subscriptionRules, id: \.id) { rule in
                            HStack { Text(rule.kind.displayName).foregroundStyle(.secondary); Text(rule.value).lineLimit(1); Spacer(); Text(model.policyLabel(rule.policy)) }.font(.caption)
                        }
                    }
                }
            }.listStyle(.inset)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("其余流量（MATCH）").font(.body.weight(.semibold))
                    Text("没有命中任何规则的连接使用此策略。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("兜底策略", selection: Binding(get: { library.fallbackPolicy }, set: { value in model.perform { try library.setFallbackPolicy(value) } })) {
                    ForEach(model.policies, id: \.self) { Text(model.policyLabel($0)).tag($0) }
                }.frame(width: 240)
            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }.padding(22)
        .sheet(item: $editor) { rule in RuleEditorView(rule: rule, policies: model.policies, label: model.policyLabel) { value in
            var updated = library.rules
            if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value } else { updated.append(value) }
            try library.persistRules(updated)
        } }
    }
}

struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: RoutingRule
    let policies: [String]
    let label: @MainActor (String) -> String
    let save: (RoutingRule) throws -> Void
    @State private var apps: [RunningAppChoice] = []
    @State private var executablePaths: [String] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("规则配置").font(.title2.bold())
            Form {
                Picker("类型", selection: $rule.kind) {
                    ForEach(RuleKind.allCases, id: \.self) { Text($0.displayName + "（" + $0.rawValue + "）").tag($0) }
                }
                if rule.kind == .processPathRegex {
                    HStack {
                        Menu("从运行中的 App 选择") {
                            ForEach(apps) { app in Button(app.name) { choose(app.url) } }
                        }
                        Button("选择 .app…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { choose(url) }
                        }
                    }
                }
                TextField("匹配内容", text: $rule.value, prompt: Text(rule.kind.placeholder))
                Picker("策略", selection: $rule.policy) { ForEach(policies, id: \.self) { Text(label($0)).tag($0) } }
                Toggle("启用", isOn: $rule.enabled)
            }
            if !executablePaths.isEmpty {
                Text("bundle 内可执行文件（最多 200 个）").font(.headline)
                ScrollView { Text(executablePaths.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 150)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存规则") {
                    var value = rule
                    value.value = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    do { try save(value); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 650).onAppear { apps = ProcessCatalog.runningApps() }
    }
    private func choose(_ url: URL) { rule.value = ProcessCatalog.rulePath(url); executablePaths = ProcessCatalog.executables(in: url) }
}

extension RuleKind {
    var displayName: String {
        switch self {
        case .processPathRegex: "App / 进程路径"
        case .processName: "进程名"
        case .domain: "精确域名"
        case .domainSuffix: "域名后缀"
        case .domainKeyword: "域名关键词"
        case .geosite: "GEOSITE 分类"
        }
    }

    var placeholder: String {
        switch self {
        case .processPathRegex: "用上方按钮选择 App，或填写 ^/Applications/Example\\.app/"
        case .processName: "例如 ssh、git、curl"
        case .domain: "例如 api.openai.com"
        case .domainSuffix: "例如 openai.com"
        case .domainKeyword: "例如 google"
        case .geosite: "例如 telegram"
        }
    }
}

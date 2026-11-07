import SwiftUI
import AppKit

struct AdvancedView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: AppLibraryModel
    @State private var yaml = ""
    @State private var confirmUninstall = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        YAMLEditor(text: $yaml).frame(height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        HStack {
                            Button("恢复默认值") { yaml = AdvancedOptions.exampleYAML }
                            Spacer()
                            Button("校验并保存") { model.perform { try library.saveAdvancedYAML(yaml) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(library.migrationRequired)
                        }
                    }.padding(6)
                } label: { Label("高级 YAML", systemImage: "curlybraces") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("本机签名", value: model.signed ? "已配置固定签名身份" : "未配置（界面预览版本）")
                        LabeledContent("内核版本", value: "mihomo v" + AppConstants.coreVersion)
                        HStack {
                            Button("停止并恢复网络") { Task { _ = await model.stopAndRestore() } }.disabled(model.busy)
                            Button("打开使用说明") {
                                if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) }
                            }
                            Button("内核发布页") { NSWorkspace.shared.open(URL(string: "https://github.com/MetaCubeX/mihomo/releases/tag/v" + AppConstants.coreVersion)!) }
                            Spacer()
                            Button("退出 ClairRoute") { NSApp.terminate(nil) }.disabled(model.busy)
                        }
                        if library.pendingSecretCleanup > 0 {
                            HStack {
                                Text("还有 \(library.pendingSecretCleanup) 项旧钥匙串条目待清理，清理后才能卸载。")
                                Spacer()
                                Button("清理旧钥匙串") { model.perform { try library.retrySecretCleanup() } }
                                    .disabled(model.busy || library.migrationRequired)
                            }
                        }
                    }.padding(6)
                } label: { Label("维护", systemImage: "wrench.and.screwdriver") }

                GroupBox {
                    HStack {
                        Spacer()
                        Button("完全卸载…", role: .destructive) { confirmUninstall = true }
                            .disabled(model.busy || !model.signed || library.migrationRequired || library.pendingSecretCleanup > 0)
                    }.padding(6)
                } label: { Label("卸载", systemImage: "trash") }
            }.padding(24)
        }.onAppear { yaml = library.advancedYAML.isEmpty ? AdvancedOptions.exampleYAML : library.advancedYAML }
        .confirmationDialog("删除 ClairRoute 的本机配置并卸载？", isPresented: $confirmUninstall) {
            Button("恢复网络并开始卸载", role: .destructive) { Task { await uninstall() } }
        } message: { Text("此操作会删除所有本应用订阅和节点。终端将请求管理员授权后移除系统组件。") }
    }
    private func uninstall() async {
        guard library.pendingSecretCleanup == 0 else {
            model.error = "请先点击「清理旧钥匙串」，再卸载应用。"; return
        }
        guard let scripts = Bundle.main.resourceURL?.appendingPathComponent("Scripts"),
              FileManager.default.isExecutableFile(atPath: scripts.appendingPathComponent("Uninstall ClairRoute.command").path) else {
            model.error = "卸载工具缺失，请使用项目 Scripts/uninstall-local.sh。"; return
        }
        guard await model.stopAndRestore() else { return }
        do {
            try await model.removeStartupSettings()
            try library.removeAllData()
            if NSWorkspace.shared.open(scripts.appendingPathComponent("Uninstall ClairRoute.command")) { NSApp.terminate(nil) }
            else { model.error = "无法打开卸载终端；网络已恢复，请手动运行卸载脚本。" }
        } catch { model.error = "配置清理未完成，尚未卸载：\(error.localizedDescription)" }
    }
}

struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder; scroll.drawsBackground = true
        let view = NSTextView(); view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("高级 YAML")
        view.delegate = context.coordinator; scroll.documentView = view
        view.string = text; context.coordinator.highlight(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text; context.coordinator.highlight(view)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: YAMLEditor
        init(_ parent: YAMLEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string; highlight(view)
        }
        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let selection = view.selectedRanges
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)], range: range)
            if storage.length < 100_000 {
                let patterns: [(String, NSColor)] = [("(?m)^\\s*[a-zA-Z][a-zA-Z0-9-]*(?=:)", .systemBlue), ("\\b(true|false|[0-9]+)\\b", .systemOrange), ("\"[^\"\\n]*\"|'[^'\\n]*'", .systemGreen), ("(?m)#.*$", .secondaryLabelColor)]
                for (pattern, color) in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        for match in regex.matches(in: view.string, range: range) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
                    }
                }
            }
            storage.endEditing(); view.selectedRanges = selection
        }
    }
}

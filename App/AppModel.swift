import AppKit
import SwiftUI
import Combine

@MainActor final class AppModel: ObservableObject {
    let library = AppLibraryModel()
    private let client = HelperClient()
    private let sessionID = UUID()
    private var generation: UInt64 = 0
    private var polling: Task<Void, Never>?
    private var libraryObservation: AnyCancellable?
    private var libraryNoticeObservation: AnyCancellable?
    private var attemptedMutation = false
    private var unconfirmed = false
    private var activeTrialMode = false
    @Published var status: ServiceStatus = .idle
    @Published var mode: OutboundMode = OutboundMode(rawValue: UserDefaults.standard.string(forKey: "ClairRoute.outboundMode") ?? "rule") ?? .rule
    @Published var busy = false
    @Published var helperConnected = false
    @Published var error: String?
    @Published var notice = ""
    @Published var connections: [ConnectionSnapshot] = []
    @Published var connectionPanelVisible = false
    @Published var delays: [String: String] = [:]
    @Published var selectedPage: AppPage = .overview
    var signed: Bool { HelperClient.hasSigningIdentity }
    var phaseLabel: String {
        guard signed else { return "界面模式" }
        guard helperConnected else { return "状态未确认" }
        switch status.phase {
        case .idle: return "已关闭"
        case .preparing, .starting: return "正在启动"
        case .active: return "运行中"
        case .reconfiguring: return "正在应用"
        case .restoring: return "正在恢复"
        case .needsAttention: return "需要处理"
        }
    }
    var needsAttention: Bool { status.recoveryPending || status.phase == .needsAttention || unconfirmed }
    var statusSymbol: String {
        if !signed { return "eye" }
        if needsAttention || !helperConnected { return "exclamationmark.triangle.fill" }
        return status.coreRunning ? "checkmark.shield.fill" : "shield.slash"
    }
    var statusTint: Color {
        if !signed { return .secondary }
        if needsAttention || !helperConnected { return .orange }
        switch status.phase {
        case .active: return .green
        case .preparing, .starting, .reconfiguring, .restoring: return .blue
        case .idle, .needsAttention: return .secondary
        }
    }
    /// One-line explanation shown under the phase label on the overview page.
    var statusDetail: String {
        guard signed else { return "界面预览版本：可以编辑节点和规则，但不能开启代理。" }
        guard helperConnected else { return "暂时无法连接后台服务，网络状态未确认。" }
        if needsAttention { return status.message.isEmpty ? "有未完成的网络恢复，请点击「恢复网络并关闭代理」。" : status.message }
        guard status.coreRunning else { return "TUN 和系统代理都已关闭，网络未被接管。" }
        let takeover = [status.tunEnabled ? "增强模式" : nil, status.systemProxyEnabled ? "系统代理" : nil].compactMap { $0 }
        let modeName = switch mode { case .rule: "规则模式"; case .global: "全局模式"; case .direct: "直连模式" }
        return (takeover.isEmpty ? "内核运行中" : takeover.joined(separator: " + ")) + " · " + modeName + (activeTrialMode ? " · 限时验收中" : "")
    }
    /// Keep saved, disabled policies visible so editing never silently replaces them.
    var policies: [String] {
        let groups = library.subscriptions.filter { subscription in library.nodes.contains { $0.sourceID == subscription.id } }
        return ["PROXY", "DIRECT", "REJECT"] + groups.map { ConfigurationBuilder.sourcePolicy($0.id) } + library.nodes.map(\.name)
    }
    /// Human-readable name for a policy; subscription groups are shown by subscription name.
    func policyLabel(_ policy: String) -> String {
        if let subscription = library.subscriptions.first(where: { ConfigurationBuilder.sourcePolicy($0.id) == policy }) {
            return "订阅：" + subscription.name + (subscription.enabled ? "" : "（已停用）")
        }
        if let node = library.nodes.first(where: { $0.name == policy }), !nodeIsEnabled(node) { return policy + "（已停用）" }
        return policy
    }
    func nodeIsEnabled(_ node: NodeMetadata) -> Bool {
        guard let source = node.sourceID else { return true }
        return library.subscriptions.contains { $0.id == source && $0.enabled }
    }

    init() {
        libraryObservation = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Import, editor and automatic-refresh results all use the same visible channel.
        libraryNoticeObservation = library.$notice.sink { [weak self] message in
            guard let self, let message, !message.isEmpty else { return }
            self.notice = message
        }
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            self.helperConnected = false
            if self.status.coreRunning || self.status.recoveryPending || self.unconfirmed {
                self.unconfirmed = true
                self.error = "与 Helper 的连接中断，网络恢复状态尚未确认。"
            }
        }
    }
    func startObserving() {
        guard polling == nil, signed else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.busy {
                    do {
                        let next = self.status.coreRunning
                            ? try await self.client.heartbeat(sessionID: self.sessionID)
                            : try await self.client.status()
                        if !self.busy { self.accept(next) }
                        if self.connectionPanelVisible && self.status.coreRunning && !self.busy {
                            let rows = try await self.client.connections()
                            if !self.busy { self.connections = rows }
                        }
                    } catch {
                        if !self.busy {
                            if let actual = (error as? ClientError)?.reportedStatus { self.accept(actual) }
                            if let actual = try? await self.client.status() { self.accept(actual) }
                            else { self.helperConnected = false }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func accept(_ next: ServiceStatus) {
        status = next; generation = max(generation, next.generation)
        helperConnected = true; unconfirmed = false
        if !next.coreRunning { connections = []; activeTrialMode = false }
    }
    func refreshStatus() async {
        guard !busy else { return }
        do { accept(try await client.status()); error = nil }
        catch { self.error = error.localizedDescription; helperConnected = false }
    }
    func setTUN(_ value: Bool) async { _ = await apply(tun: value, proxy: status.systemProxyEnabled) }
    func setSystemProxy(_ value: Bool) async { _ = await apply(tun: status.tunEnabled, proxy: value) }
    func startLimitedTrial() async {
        guard !status.coreRunning else { error = "请先停止当前会话，再开始限时验收。"; return }
        _ = await apply(tun: true, proxy: false, trialMode: true)
    }
    func startLimitedSystemProxyTrial() async {
        guard !status.coreRunning else { error = "请先停止当前会话，再开始限时验收。"; return }
        _ = await apply(tun: false, proxy: true, trialMode: true)
    }
    func applySavedConfiguration() async {
        if status.coreRunning { _ = await apply(tun: status.tunEnabled, proxy: status.systemProxyEnabled) }
        else {
            do { _ = try library.runtimeProfile(mode: mode); notice = "配置校验通过；开启代理时生效。"; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult
    private func apply(tun: Bool, proxy: Bool, newMode: OutboundMode? = nil, trialMode: Bool? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        let requestedTrial = trialMode ?? activeTrialMode
        do {
            if !tun && !proxy { accept(try await client.stop()) }
            else {
                let profile = try library.runtimeProfile(mode: newMode ?? mode)
                guard !profile.nodes.isEmpty else { throw ClientError.rejected("请先添加节点或导入订阅。") }
                try ConfigurationBuilder.validate(profile)
                generation += 1; attemptedMutation = true; unconfirmed = true
                accept(try await client.apply(ApplyRequest(sessionID: sessionID, generation: generation,
                    tunEnabled: tun, systemProxyEnabled: proxy, profile: profile, trialMode: requestedTrial)))
                activeTrialMode = requestedTrial && status.coreRunning
            }
            error = nil; notice = "配置已应用。"; return true
        } catch {
            self.error = error.localizedDescription
            if let actual = (error as? ClientError)?.reportedStatus { accept(actual) }
            if let actual = try? await client.status() { accept(actual) }
            if status.coreRunning && status.generation == generation { activeTrialMode = requestedTrial }
            return false
        }
    }
    func changeMode(_ value: OutboundMode) async {
        guard value != mode, !busy else { return }
        if status.coreRunning {
            guard await apply(tun: status.tunEnabled, proxy: status.systemProxyEnabled, newMode: value) else { return }
        }
        mode = value; UserDefaults.standard.set(value.rawValue, forKey: "ClairRoute.outboundMode")
    }
    func chooseNode(_ name: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let previous = library.selectedNode ?? library.nodes.first?.name
        do {
            if status.coreRunning { accept(try await client.select(node: name)) }
            do { try library.selectNode(name) }
            catch {
                if status.coreRunning, let previous {
                    do { accept(try await client.select(node: previous)) }
                    catch {
                        do { accept(try await client.stop()) }
                        catch { unconfirmed = true; helperConnected = false }
                        throw ClientError.rejected("节点保存和恢复选择均未能确认，已请求停止代理。请检查网络恢复状态。")
                    }
                }
                throw error
            }
            error = nil; notice = "已选择节点：\(name)"
        } catch {
            self.error = error.localizedDescription
            if let actual = (error as? ClientError)?.reportedStatus { accept(actual) }
            else if status.coreRunning {
                if let actual = try? await client.status() { accept(actual) }
                else { unconfirmed = true; helperConnected = false }
            }
        }
    }
    func measureDelay(_ name: String) async {
        guard status.coreRunning else { error = "延迟测试需要先启用内核；不会为测试自动接管网络。"; return }
        delays[name] = "测量中"
        do { delays[name] = "\(try await client.delay(node: name)) ms" }
        catch { delays[name] = "不可用"; self.error = error.localizedDescription }
    }
    func addRule(_ rule: RoutingRule) {
        do { try library.persistRules(library.rules + [rule]); selectedPage = .rules; notice = "规则已保存；点击「应用配置」生效。"; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func ruleForProcess(_ row: ConnectionSnapshot) {
        let path = row.processPath
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.upperBound].dropLast())
            addRule(RoutingRule(kind: .processPathRegex, value: "^" + NSRegularExpression.escapedPattern(for: bundle) + "/"))
        } else if !row.process.isEmpty {
            addRule(RoutingRule(kind: .processName, value: row.process))
        } else if !path.isEmpty {
            addRule(RoutingRule(kind: .processPathRegex, value: "^" + NSRegularExpression.escapedPattern(for: path) + "$"))
        }
    }
    func stopAndRestore() async -> Bool {
        guard !busy else { error = "操作正在进行，请稍后再退出。"; return false }
        guard signed else { return true }
        busy = true; defer { busy = false }
        do {
            accept(try await client.stop())
            guard !status.recoveryPending && !status.coreRunning else { throw ClientError.rejected("恢复尚未完成，请保留恢复记录并重试。") }
            error = nil; return true
        } catch {
            if let actual = try? await client.status() {
                accept(actual)
                if !actual.recoveryPending && !actual.coreRunning && !actual.tunEnabled && !actual.systemProxyEnabled { return true }
            }
            if !attemptedMutation && !unconfirmed && !status.coreRunning && !status.recoveryPending { return true }
            self.error = "无法确认网络恢复已完成：\(error.localizedDescription)"; return false
        }
    }
    /// Runs a library edit and reports the outcome in the message bar.
    func perform(_ action: () throws -> Void) {
        library.clearMessages()
        do {
            try action(); error = nil
            notice = library.notice ?? (status.coreRunning ? "已保存；点击「应用配置」让运行中的会话生效。" : "已保存。")
        } catch { self.error = error.localizedDescription }
    }
    func refreshSubscription(_ id: UUID) async {
        dismissError()
        do { try await library.refreshSubscription(id: id) }
        catch { self.error = error.localizedDescription }
    }
    func dismissError() { error = nil; notice = ""; library.clearMessages() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var openMainWindow: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the interface must not end the active proxy session or heartbeat.
        false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openMainWindow else { return true }
        // Window scenes are single-instance: this also brings an existing window forward.
        openMainWindow()
        sender.activate()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            let restored = await model.stopAndRestore()
            if !restored {
                let alert = NSAlert(); alert.messageText = "尚未完成网络恢复"
                alert.informativeText = model.error ?? "请在设置窗口查看状态并重试。"
                alert.addButton(withTitle: "留在应用中"); alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }
}

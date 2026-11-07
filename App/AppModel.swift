import AppKit
import SwiftUI
import Combine
import ServiceManagement

protocol AppPreferenceStorage {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: AppPreferenceStorage {}

@MainActor final class AppModel: ObservableObject {
    let library: AppLibraryModel
    private let client: any HelperControlling
    private let preferences: any AppPreferenceStorage
    private let signingReady: Bool
    private let startupNetwork: (any StartupNetworkMonitoring)?
    private let launchChoiceAtStartup: LaunchConnection
    private var launchHandled = false
    private var launchCancelled = false
    private var automaticStart: Task<Void, Never>?
    private let sessionID = UUID()
    private var generation: UInt64 = 0
    private var polling: Task<Void, Never>?
    private var libraryObservation: AnyCancellable?
    private var libraryNoticeObservation: AnyCancellable?
    private var libraryWarningsObservation: AnyCancellable?
    private var attemptedMutation = false
    private var unconfirmed = false
    private var activeTrialMode = false
    @Published var status: ServiceStatus = .idle
    @Published var mode: OutboundMode = .rule
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var launchConnection: LaunchConnection
    @Published private(set) var startupTakeover: StartupTakeover
    @Published var busy = false
    @Published var helperConnected = false
    @Published var error: String?
    @Published var notice = "" {
        didSet { noticeID = UUID() }
    }
    @Published private(set) var noticeID = UUID()
    @Published private(set) var pendingWarnings: [String] = []
    @Published var connections: [ConnectionSnapshot] = []
    @Published var connectionPanelVisible = false
    @Published var delays: [String: String] = [:]
    /// The node the core's automatic group currently uses; nil when unknown or not in use.
    @Published private(set) var autoSelectedNode: String?
    private var pollCount = 0
    @Published var selectedPage: AppPage = .overview
    var signed: Bool { signingReady }
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
        if policy == ConfigurationBuilder.autoPolicy { return "自动选择" }
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

    convenience init() {
        self.init(library: AppLibraryModel(), client: HelperClient(), preferences: UserDefaults.standard,
                  signed: HelperClient.hasSigningIdentity, startupNetwork: StartupNetworkMonitor())
        refreshLoginStatus()
    }
    init(library: AppLibraryModel, client: any HelperControlling,
         preferences: any AppPreferenceStorage, signed: Bool,
         startupNetwork: (any StartupNetworkMonitoring)? = nil) {
        self.library = library; self.client = client; self.preferences = preferences; signingReady = signed
        self.startupNetwork = startupNetwork
        let choice = LaunchConnection(rawValue: preferences.string(forKey: LaunchConnection.preferenceKey) ?? "") ?? .manual
        launchConnection = choice; launchChoiceAtStartup = choice
        startupTakeover = StartupTakeover(rawValue: preferences.string(forKey: StartupTakeover.preferenceKey) ?? "") ?? .tun
        mode = OutboundMode(rawValue: preferences.string(forKey: "ClairRoute.outboundMode") ?? "rule") ?? .rule
        // Do not resurrect a historical opt-in when upgrading from manual-only builds.
        preferences.set(false, forKey: "ClairRoute.autoConnect")
        libraryObservation = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Successful import, editor and refresh results share the transient channel.
        libraryNoticeObservation = library.$notice.sink { [weak self] message in
            guard let self, let message, !message.isEmpty else { return }
            self.notice = message
        }
        libraryWarningsObservation = library.$warnings.sink { [weak self] warnings in
            guard let self else { return }
            // Keep warnings until explicit dismissal, including across refreshes
            // and later successes. A new occurrence after dismissal is shown again.
            for warning in warnings where !self.pendingWarnings.contains(warning) {
                self.pendingWarnings.append(warning)
            }
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
                        self.pollCount += 1
                        if self.library.autoSelect.enabled && self.status.coreRunning && !self.busy
                            && self.pollCount % 3 == 0 {
                            await self.refreshAutoSelection()
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
    func stopObserving() { polling?.cancel(); polling = nil }
    func setLaunchConnection(_ value: LaunchConnection) {
        preferences.set(value.rawValue, forKey: LaunchConnection.preferenceKey)
        launchConnection = value
        if value == .manual { cancelLaunchConnection() }
        // Selecting automatic only saves the next-launch preference.
    }
    private func cancelLaunchConnection() {
        launchCancelled = true
        automaticStart?.cancel()
        startupNetwork?.stop()
    }
    /// Called once by the application delegate, never by window or network callbacks.
    @discardableResult
    func startLaunchConnection(timeout: Duration = .seconds(60), retryDelay: Duration = .seconds(2)) -> Task<Void, Never>? {
        guard !launchHandled else { return nil }
        launchHandled = true
        guard signed, launchChoiceAtStartup == .automatic, launchConnection == .automatic,
              !launchCancelled, let startupNetwork else { return nil }
        startupNetwork.start()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { startupNetwork.stop(); self.automaticStart = nil }
            let deadline = ContinuousClock.now + timeout
            while !Task.isCancelled, !self.launchCancelled, self.launchConnection == .automatic,
                  ContinuousClock.now < deadline {
                if await self.attemptLaunchConnection(deadline: deadline) { return }
                if ContinuousClock.now >= deadline { break }
                do { try await Task.sleep(for: retryDelay) } catch { return }
            }
            if !Task.isCancelled, !self.launchCancelled, self.launchConnection == .automatic {
                self.error = "自动连接未开始：网络或后台服务尚未就绪。请稍后手动连接。"
            }
        }
        automaticStart = task
        return task
    }
    /// A failed Apply ends the launch attempt; only readiness checks may be retried.
    private func attemptLaunchConnection(deadline: ContinuousClock.Instant) async -> Bool {
        guard !busy else { return false }
        guard !library.migrationRequired else {
            error = "自动连接未开始：请先完成旧配置迁移。"; return true
        }
        guard startupNetwork?.isAvailable == true else { return false }
        busy = true; defer { busy = false }
        do {
            let next = try await client.status()
            guard !Task.isCancelled, !launchCancelled, launchConnection == .automatic else { return true }
            accept(next)
            if next.coreRunning { return true }
            guard next.phase == .idle, !next.recoveryPending, !next.tunEnabled, !next.systemProxyEnabled else { return false }
            guard ContinuousClock.now < deadline, startupNetwork?.isAvailable == true else { return false }
            let takeover = startupTakeover
            _ = await applyWhileBusy(tun: takeover.tunEnabled, proxy: takeover.systemProxyEnabled, trialMode: false)
            return true
        } catch {
            guard !Task.isCancelled, !launchCancelled else { return true }
            helperConnected = false
            return false
        }
    }
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }
    func setLaunchAtLogin(_ enabled: Bool) async {
        do { try await configureLoginItem(enabled); error = nil }
        catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
        refreshLoginStatus()
    }
    private func configureLoginItem(_ enabled: Bool) async throws {
        guard signed, Bundle.main.bundleURL.path == "/Applications/ClairRoute.app" else {
            throw ClientError.rejected("请从 Applications 中打开已安装的 ClairRoute 后设置登录启动。")
        }
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
        } else if service.status != .notRegistered && service.status != .notFound {
            try await service.unregister()
        }
        refreshLoginStatus()
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func removeStartupSettings() async throws {
        try await configureLoginItem(false)
        setLaunchConnection(.manual)
    }

    private func accept(_ next: ServiceStatus) {
        status = next; generation = max(generation, next.generation)
        helperConnected = true; unconfirmed = false
        if !next.coreRunning { connections = []; activeTrialMode = false; autoSelectedNode = nil }
    }
    /// Reads which candidate the core's url-test group picked. Failures only clear the display.
    private func refreshAutoSelection() async {
        guard let groups = try? await client.proxies() else { autoSelectedNode = nil; return }
        let proxy = groups.first(where: { $0.name == "PROXY" })?.selected
        autoSelectedNode = proxy == ConfigurationBuilder.autoPolicy
            ? groups.first(where: { $0.name == ConfigurationBuilder.autoPolicy })?.selected : nil
    }
    func refreshStatus() async {
        guard !busy else { return }
        do { accept(try await client.status()); error = nil }
        catch { self.error = error.localizedDescription; helperConnected = false }
    }
    func setTUN(_ value: Bool) async {
        cancelLaunchConnection()
        _ = await apply(tun: value, proxy: status.systemProxyEnabled)
    }
    func setSystemProxy(_ value: Bool) async {
        cancelLaunchConnection()
        _ = await apply(tun: status.tunEnabled, proxy: value)
    }
    func startLimitedTrial() async {
        cancelLaunchConnection()
        guard !status.coreRunning else { error = "请先停止当前会话，再开始限时验收。"; return }
        _ = await apply(tun: true, proxy: false, trialMode: true)
    }
    func startLimitedSystemProxyTrial() async {
        cancelLaunchConnection()
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
        return await applyWhileBusy(tun: tun, proxy: proxy, newMode: newMode, trialMode: trialMode)
    }
    /// Caller owns the busy flag throughout persistence, apply and rollback.
    private func applyWhileBusy(tun: Bool, proxy: Bool, newMode: OutboundMode? = nil, trialMode: Bool? = nil) async -> Bool {
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
                if !requestedTrial, status.phase == .active, status.coreRunning, !status.recoveryPending,
                   let takeover = StartupTakeover(tun: status.tunEnabled, systemProxy: status.systemProxyEnabled) {
                    preferences.set(takeover.rawValue, forKey: StartupTakeover.preferenceKey)
                    startupTakeover = takeover
                }
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
        mode = value; preferences.set(value.rawValue, forKey: "ClairRoute.outboundMode")
    }
    func chooseNode(_ name: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let previous = library.selectedNode
        let wasAutomatic = library.autoSelect.enabled
        let previousAuto = library.autoSelect
        // A disk error must leave the live session intact.
        do { try library.selectNode(name) }
        catch { self.error = error.localizedDescription; return }
        autoSelectedNode = nil
        // Rebuild dependent subscription groups and remove the old automatic probe group.
        if status.coreRunning, !(await applyWhileBusy(tun: status.tunEnabled, proxy: status.systemProxyEnabled)) {
            await restoreSavedSelection(node: previous, autoSelect: previousAuto)
            return
        }
        error = nil; notice = wasAutomatic ? "已改为手动选择节点：\(name)" : "已选择节点：\(name)"
    }
    /// Saves automatic selection and, while proxying, reloads the core so it takes effect now.
    func setAutoSelect(_ settings: AutoSelectSettings) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let previous = library.autoSelect
        let previousNode = library.selectedNode
        do { try library.setAutoSelect(settings) }
        catch { self.error = error.localizedDescription; return }
        autoSelectedNode = nil
        guard status.coreRunning else {
            error = nil
            notice = settings.enabled ? "已开启自动选择；开启代理时生效。" : "已关闭自动选择。"
            return
        }
        if await applyWhileBusy(tun: status.tunEnabled, proxy: status.systemProxyEnabled) {
            notice = settings.enabled ? "已开启自动选择，内核会每 \(settings.interval) 秒检测一次延迟。" : "已关闭自动选择，改用手动选择的节点。"
            if settings.enabled { await refreshAutoSelection() }
        } else {
            await restoreSavedSelection(node: previousNode, autoSelect: previous)
        }
    }
    private func restoreSavedSelection(node: String?, autoSelect: AutoSelectSettings) async {
        do { try library.restoreSelection(node: node, autoSelect: autoSelect) }
        catch {
            var restored = false
            do {
                accept(try await client.stop())
                restored = !status.coreRunning && !status.recoveryPending && !status.tunEnabled && !status.systemProxyEnabled
            } catch { unconfirmed = true; helperConnected = false }
            self.error = restored
                ? "配置应用失败，原节点设置也未能写回。代理已关闭，请检查保存的设置后再连接。"
                : "配置应用失败，原节点设置也未能写回，网络恢复状态未确认。请重试「恢复网络并关闭代理」。"
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
        cancelLaunchConnection()
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
        let previousNoticeID = noticeID
        do {
            try action(); error = nil
            if noticeID == previousNoticeID {
                notice = status.coreRunning ? "已保存；点击「应用配置」让运行中的会话生效。" : "已保存。"
            }
        } catch { self.error = error.localizedDescription }
    }
    func refreshSubscription(_ id: UUID) async {
        dismissError()
        do { try await library.refreshSubscription(id: id) }
        catch {
            // The library owns refresh errors and clears them after a successful retry,
            // including automatic retries. Do not retain a stale duplicate in AppModel.
            if library.error == nil { self.error = error.localizedDescription }
        }
    }
    func dismissError() { error = nil; notice = ""; library.clearMessages() }
    func dismissNotice() { notice = "" }
    func dismissWarnings() { pendingWarnings = [] }
    func expireNotice(id: UUID) {
        guard noticeID == id else { return }
        notice = ""
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var openMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startObserving()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
        if loginLaunch || ProcessInfo.processInfo.arguments.contains("--background") { NSApp.hide(nil) }
        model.startLaunchConnection()
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginStatus() }
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

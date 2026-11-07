import Foundation

private final class TestPreferences: AppPreferenceStorage {
    var values: [String: Any] = ["ClairRoute.autoConnect": true]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor private final class TestStartupNetwork: StartupNetworkMonitoring {
    var isAvailable = true
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

private final class ForbiddenVault: SecretVault {
    func read(_ id: UUID) throws -> Data { throw OfflineFailure("Unexpected Keychain read") }
    func write(_ data: Data, id: UUID) throws { throw OfflineFailure("Unexpected Keychain write") }
    func remove(_ id: UUID) throws { throw OfflineFailure("Unexpected Keychain removal") }
}

private struct ForbiddenSubscriptionFetcher: SubscriptionFetching {
    func fetch(_ url: URL) async throws -> SubscriptionDownload { throw OfflineFailure("Unexpected network request") }
}

private actor RefreshResults: SubscriptionFetching {
    private var calls = 0
    func fetch(_ url: URL) async throws -> SubscriptionDownload {
        calls += 1
        if calls == 1 { throw SubscriptionError.httpStatus(503) }
        let partialRule = calls == 3 ? "  - GEOIP,CN,DIRECT\n" : ""
        let yaml = """
        mixed-port: 7890
        mode: rule
        proxies:
          - {name: Example, type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: fixture-only}
        proxy-groups:
          - {name: Provider, type: select, proxies: [Example]}
        rules:
          - MATCH,Provider

        """ + partialRule
        return SubscriptionDownload(data: Data(yaml.utf8), userInfo: nil)
    }
}

@MainActor private final class RecordingHelper: HelperControlling {
    var onDisconnect: (() -> Void)?
    var current = ServiceStatus.idle
    var applied: [ApplyRequest] = []
    var statusReads = 0
    var stops = 0
    var heartbeats = 0
    var inspections = 0
    var failApply = false
    var failStop = false
    var failedStatusReads = 0
    var beforeApply: (() throws -> Void)?
    var beforeStatus: (() async -> Void)?
    func status() async throws -> ServiceStatus {
        statusReads += 1
        await beforeStatus?()
        if failedStatusReads > 0 { failedStatusReads -= 1; throw ClientError.unavailable }
        return current
    }
    func stop() async throws -> ServiceStatus {
        stops += 1
        if failStop { throw ClientError.rejected("Mock recovery failure") }
        current = .idle
        return current
    }
    func apply(_ request: ApplyRequest) async throws -> ServiceStatus {
        applied.append(request)
        try beforeApply?()
        if failApply { throw ClientError.rejectedWithStatus("Mock rejected configuration; previous session retained", current) }
        current = ServiceStatus(phase: .active, tunEnabled: request.tunEnabled,
                                systemProxyEnabled: request.systemProxyEnabled, coreRunning: true,
                                generation: request.generation)
        return current
    }
    func heartbeat(sessionID: UUID) async throws -> ServiceStatus { heartbeats += 1; return current }
    func connections() async throws -> [ConnectionSnapshot] { inspections += 1; return [] }
    func proxies() async throws -> [ProxySnapshot] { inspections += 1; return [] }
    func delay(node: String) async throws -> Int { inspections += 1; return 42 }
}

@MainActor private struct ModelFixture {
    let directory: URL
    let library: AppLibraryModel
    let helper: RecordingHelper
    let preferences: TestPreferences
    let network: TestStartupNetwork
    let model: AppModel

    init(directory: URL, automatic: Bool = false, preferences: TestPreferences = TestPreferences(), signed: Bool = true) throws {
        self.directory = directory
        library = AppLibraryModel(store: ProfileStore(directory: directory, vault: ForbiddenVault()),
                                  service: ForbiddenSubscriptionFetcher(), automaticRefresh: false)
        for name in ["Node A", "Node B"] {
            try library.saveNode(ProxyNode(name: name, server: "example.test", port: 443,
                                          cipher: "aes-256-gcm", password: "offline-fixture"))
        }
        try library.selectNode("Node A")
        try library.setAutoSelect(AutoSelectSettings(enabled: automatic))
        helper = RecordingHelper(); self.preferences = preferences; network = TestStartupNetwork()
        model = AppModel(library: library, client: helper, preferences: preferences, signed: signed, startupNetwork: network)
    }
    func markRunning() async {
        helper.current = ServiceStatus(phase: .active, tunEnabled: true, coreRunning: true, generation: 1)
        await model.refreshStatus()
    }
    func disk() throws -> LibrarySnapshot {
        try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("profile.json")))
    }
    func rejectWrites() throws {
        try FileManager.default.linkItem(at: directory.appendingPathComponent("profile.json"),
                                         to: directory.appendingPathComponent("write-failure-hardlink"))
    }
}

@MainActor func runAppModelTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clairroute-model-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let startup = try ModelFixture(directory: directory.appendingPathComponent("startup"), automatic: true)
    // Historical auto-connect values do not opt into the new launch choice.
    try check(startup.model.launchConnection == .manual && startup.model.startLaunchConnection() == nil,
              "upgrading defaults to manual and does not create a startup task")
    startup.model.startObserving()
    defer { startup.model.stopObserving() }
    for _ in 0..<100 where startup.helper.statusReads == 0 { await Task.yield() }
    try check(startup.helper.statusReads > 0, "startup reads Helper status")
    try check(startup.preferences.values["ClairRoute.autoConnect"] as? Bool == false, "legacy auto-connect preference is retired")
    try check(startup.helper.applied.isEmpty && startup.helper.stops == 0 && startup.helper.heartbeats == 0,
              "startup with automatic node selection never connects or mutates the idle Helper")
    startup.model.stopObserving()
    await startup.model.chooseNode("Node B")
    await startup.model.setAutoSelect(AutoSelectSettings(enabled: true))
    await startup.model.changeMode(.global)
    await startup.model.applySavedConfiguration()
    await startup.model.refreshStatus()
    await startup.model.measureDelay("Node B")
    try check(startup.helper.applied.isEmpty && startup.helper.stops == 0 && startup.helper.inspections == 0,
              "editing, applying saved settings, checking status and delay attempts do not connect while stopped")
    await startup.model.setTUN(true)
    try check(startup.helper.applied.count == 1 && startup.helper.applied[0].tunEnabled
              && !startup.helper.applied[0].systemProxyEnabled && startup.model.status.coreRunning,
              "only an explicit TUN action starts the selected proxy mode")

    let choice = try ModelFixture(directory: directory.appendingPathComponent("launch-choice"))
    choice.model.setLaunchConnection(.automatic)
    try check(choice.model.startLaunchConnection() == nil && choice.helper.applied.isEmpty && choice.network.starts == 0,
              "selecting automatic saves next-launch behavior without connecting now")
    let relaunched = try ModelFixture(directory: directory.appendingPathComponent("launch-persisted"), preferences: choice.preferences)
    await relaunched.model.startLaunchConnection(timeout: .seconds(1), retryDelay: .milliseconds(1))?.value
    try check(relaunched.model.launchConnection == .automatic && relaunched.helper.applied.count == 1
              && relaunched.helper.applied[0].tunEnabled && !relaunched.helper.applied[0].systemProxyEnabled,
              "new process honors automatic preference and first use defaults to TUN only")
    _ = await relaunched.model.stopAndRestore()
    try check(relaunched.model.startLaunchConnection() == nil && relaunched.helper.applied.count == 1,
              "stopping and reopening a window never schedules a second automatic connection")

    for takeover in StartupTakeover.allCases {
        let preferences = TestPreferences()
        preferences.set(LaunchConnection.automatic.rawValue, forKey: LaunchConnection.preferenceKey)
        preferences.set(takeover.rawValue, forKey: StartupTakeover.preferenceKey)
        let fixture = try ModelFixture(directory: directory.appendingPathComponent("launch-\(takeover.rawValue)"), preferences: preferences)
        fixture.helper.failedStatusReads = 1
        await fixture.model.startLaunchConnection(timeout: .seconds(1), retryDelay: .milliseconds(1))?.value
        try check(fixture.helper.statusReads >= 2 && fixture.helper.applied.count == 1
                  && fixture.helper.applied[0].tunEnabled == takeover.tunEnabled
                  && fixture.helper.applied[0].systemProxyEnabled == takeover.systemProxyEnabled
                  && fixture.helper.applied[0].trialMode == false,
                  "automatic launch waits for Helper readiness then restores the saved normal mode")
        try check(fixture.network.starts == 1 && fixture.network.stops == 1,
                  "startup network monitoring stops after the single attempt")
    }

    func autoPreferences() -> TestPreferences {
        let result = TestPreferences()
        result.set(LaunchConnection.automatic.rawValue, forKey: LaunchConnection.preferenceKey)
        return result
    }
    let blockedStates: [ServiceStatus] = [
        ServiceStatus(phase: .needsAttention, recoveryPending: true),
        ServiceStatus(phase: .restoring),
        ServiceStatus(phase: .idle, tunEnabled: true),
        ServiceStatus(phase: .idle, systemProxyEnabled: true),
        ServiceStatus(phase: .active, tunEnabled: true, coreRunning: true),
    ]
    for (index, state) in blockedStates.enumerated() {
        let fixture = try ModelFixture(directory: directory.appendingPathComponent("launch-blocked-\(index)"), preferences: autoPreferences())
        fixture.helper.current = state
        await fixture.model.startLaunchConnection(timeout: .milliseconds(10), retryDelay: .milliseconds(1))?.value
        try check(fixture.helper.applied.isEmpty && fixture.helper.stops == 0,
                  "automatic launch never replaces an active session or bypasses network recovery")
    }
    let offline = try ModelFixture(directory: directory.appendingPathComponent("launch-offline"), preferences: autoPreferences())
    offline.network.isAvailable = false
    await offline.model.startLaunchConnection(timeout: .milliseconds(10), retryDelay: .milliseconds(1))?.value
    try check(offline.helper.applied.isEmpty && offline.model.error != nil && offline.network.stops == 1,
              "offline launch stops waiting at the deadline and reports that no connection started")
    let unsigned = try ModelFixture(directory: directory.appendingPathComponent("launch-unsigned"), preferences: autoPreferences(), signed: false)
    try check(unsigned.model.startLaunchConnection() == nil && unsigned.network.starts == 0,
              "unsigned builds never schedule automatic network activation")

    let rejected = try ModelFixture(directory: directory.appendingPathComponent("launch-rejected"), preferences: autoPreferences())
    rejected.helper.failApply = true
    await rejected.model.startLaunchConnection(timeout: .seconds(1), retryDelay: .milliseconds(1))?.value
    try check(rejected.helper.applied.count == 1 && rejected.model.error != nil && rejected.model.startLaunchConnection() == nil,
              "a failed startup Apply is shown and never retried automatically")

    let cancelled = try ModelFixture(directory: directory.appendingPathComponent("launch-cancelled"), preferences: autoPreferences())
    var reply: CheckedContinuation<Void, Never>?
    cancelled.helper.beforeStatus = { await withCheckedContinuation { reply = $0 } }
    let pending = cancelled.model.startLaunchConnection(timeout: .seconds(1), retryDelay: .milliseconds(1))
    for _ in 0..<100 where reply == nil { await Task.yield() }
    try check(reply != nil, "cancellation fixture reached the suspended Helper status reply")
    cancelled.model.setLaunchConnection(.manual)
    reply?.resume()
    await pending?.value
    try check(cancelled.helper.applied.isEmpty && !cancelled.model.busy,
              "switching to manual cancels a pending startup even when the Helper replies later")

    let lostNetwork = try ModelFixture(directory: directory.appendingPathComponent("launch-lost-network"), preferences: autoPreferences())
    lostNetwork.helper.beforeStatus = { lostNetwork.network.isAvailable = false }
    await lostNetwork.model.startLaunchConnection(timeout: .milliseconds(10), retryDelay: .milliseconds(1))?.value
    lostNetwork.helper.beforeStatus = nil
    try check(lostNetwork.helper.applied.isEmpty, "network readiness is rechecked after an asynchronous Helper reply")
    let lateReply = try ModelFixture(directory: directory.appendingPathComponent("launch-late-reply"), preferences: autoPreferences())
    lateReply.helper.beforeStatus = { try? await Task.sleep(for: .milliseconds(15)) }
    await lateReply.model.startLaunchConnection(timeout: .milliseconds(5), retryDelay: .milliseconds(1))?.value
    try check(lateReply.helper.applied.isEmpty && lateReply.model.error != nil,
              "a Helper reply arriving after the startup deadline cannot activate the proxy")

    let modes = try ModelFixture(directory: directory.appendingPathComponent("remember-modes"))
    await modes.model.setSystemProxy(true)
    _ = await modes.model.stopAndRestore()
    try check(modes.model.startupTakeover == .systemProxy, "ordinary success is remembered across Stop")
    await modes.model.startLimitedTrial()
    _ = await modes.model.stopAndRestore()
    modes.helper.failApply = true
    await modes.model.setTUN(true)
    try check(modes.model.startupTakeover == .systemProxy
              && modes.preferences.string(forKey: StartupTakeover.preferenceKey) == StartupTakeover.systemProxy.rawValue,
              "trial sessions and failed requests never overwrite the last successful ordinary mode")

    let selection = try ModelFixture(directory: directory.appendingPathComponent("selection"), automatic: true)
    await selection.markRunning()
    await selection.model.chooseNode("Node B")
    try check(selection.helper.applied.count == 1 && selection.helper.applied[0].profile.selectedNode == "Node B"
              && !selection.helper.applied[0].profile.autoSelect.enabled,
              "manual selection from automatic mode applies the complete updated profile")
    try check(try selection.disk().selectedNode == "Node B" && !selection.disk().autoSelect.enabled,
              "manual selection and automatic setting persist together")

    let saveFailure = try ModelFixture(directory: directory.appendingPathComponent("save-failure"), automatic: true)
    await saveFailure.markRunning()
    try saveFailure.rejectWrites()
    await saveFailure.model.chooseNode("Node B")
    try check(saveFailure.helper.applied.isEmpty && saveFailure.helper.stops == 0
              && saveFailure.library.selectedNode == "Node A" && saveFailure.library.autoSelect.enabled
              && saveFailure.model.error != nil, "failed persistence never changes the live automatic session")

    let applyFailure = try ModelFixture(directory: directory.appendingPathComponent("apply-failure"), automatic: true)
    await applyFailure.markRunning(); applyFailure.helper.failApply = true
    await applyFailure.model.chooseNode("Node B")
    try check(try applyFailure.disk().selectedNode == "Node A" && applyFailure.disk().autoSelect.enabled
              && applyFailure.library.selectedNode == "Node A" && applyFailure.library.autoSelect.enabled,
              "rejected node change restores selection and automatic mode in memory and on disk")
    try check(applyFailure.model.error != nil && applyFailure.model.status.coreRunning && !applyFailure.model.busy,
              "rejected apply retains the previous session and exposes the failure")

    let autoFailure = try ModelFixture(directory: directory.appendingPathComponent("automatic-failure"))
    await autoFailure.markRunning(); autoFailure.helper.failApply = true
    await autoFailure.model.setAutoSelect(AutoSelectSettings(enabled: true))
    try check(try !autoFailure.disk().autoSelect.enabled && !autoFailure.library.autoSelect.enabled
              && autoFailure.helper.stops == 0 && autoFailure.model.error != nil,
              "rejected automatic-mode apply rolls back its durable preference")

    // Make the second disk write fail, after saving the new setting but before the rejected apply returns.
    for stopFails in [false, true] {
        let failure = try ModelFixture(directory: directory.appendingPathComponent("rollback-failure-\(stopFails)"))
        await failure.markRunning(); failure.helper.failApply = true; failure.helper.failStop = stopFails
        failure.helper.beforeApply = { try failure.rejectWrites() }
        await failure.model.setAutoSelect(AutoSelectSettings(enabled: true))
        failure.helper.beforeApply = nil
        try check(failure.helper.stops == 1 && !failure.model.busy, "failed durable rollback explicitly requests network restoration")
        try check(stopFails ? failure.model.needsAttention : !failure.model.status.coreRunning,
                  "rollback failure reports unconfirmed recovery or confirms the stopped session")
        try check(failure.model.error?.contains(stopFails ? "未确认" : "代理已关闭") == true,
                  "rollback failure is never silently discarded")
    }
    let refreshed = AppLibraryModel(store: ProfileStore(directory: directory.appendingPathComponent("refresh-messages"),
                                                        vault: ForbiddenVault()),
                                    service: RefreshResults(), automaticRefresh: false)
    try refreshed.addSubscription(name: "Example source", url: "https://example.test/sub", interval: 300)
    let helper = RecordingHelper()
    let refreshModel = AppModel(library: refreshed, client: helper, preferences: TestPreferences(), signed: true)
    let subscriptionID = refreshed.subscriptions[0].id
    await refreshModel.refreshSubscription(subscriptionID)
    try check(refreshed.error?.contains("503") == true && refreshModel.error == nil,
              "failed refresh has one actionable library error, not a stale duplicate")
    // An automatic retry calls the library directly, without the manual button clearing AppModel.
    try await refreshed.refreshSubscription(id: subscriptionID)
    try check(refreshed.error == nil && refreshModel.error == nil && !refreshModel.notice.isEmpty,
              "a successful background retry removes the previous refresh error")
    try check(refreshModel.pendingWarnings.isEmpty, "routine template normalization never shows as a persistent warning")
    await refreshModel.refreshSubscription(subscriptionID)
    try check(refreshModel.pendingWarnings.count == 1 && refreshModel.pendingWarnings[0].contains("不支持的规则"),
              "partially skipped rules still create a visible warning")
    await refreshModel.refreshSubscription(subscriptionID)
    refreshModel.expireNotice(id: refreshModel.noticeID)
    try check(refreshModel.notice.isEmpty && refreshModel.pendingWarnings.count == 1,
              "success and its expiry do not silently dismiss partial-import warnings")
    refreshModel.dismissWarnings()
    try check(refreshModel.pendingWarnings.isEmpty && helper.applied.isEmpty,
              "warnings can be dismissed manually and all refresh scenarios leave proxying stopped")
    print("App lifecycle: manual-default/opt-in automatic launch, cancellation, readiness, remembered modes and failure recovery passed with a mock Helper")
    print("Refresh messages: failure, automatic recovery, routine template notes and persistent partial-import warnings passed")
}

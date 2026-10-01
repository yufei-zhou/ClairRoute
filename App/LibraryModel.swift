import Foundation
import Combine

@MainActor
final class AppLibraryModel: ObservableObject {
    @Published private(set) var nodes: [NodeMetadata] = []
    @Published private(set) var subscriptions: [SubscriptionMetadata] = []
    @Published private(set) var rules: [RoutingRule] = []
    @Published private(set) var subscriptionRules: [RoutingRule] = []
    @Published private(set) var fallbackPolicy = "DIRECT"
    @Published private(set) var selectedNode: String?
    @Published private(set) var advancedYAML = ""
    @Published private(set) var notice: String?
    @Published private(set) var error: String?
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var pendingSecretCleanup = 0
    @Published private(set) var migrationRequired = false

    private let store: ProfileStore
    private let service: any SubscriptionFetching
    private var timer: Task<Void, Never>?
    private var lastAttempt: [UUID: Date] = [:]

    init(store: ProfileStore = ProfileStore(), service: any SubscriptionFetching = SubscriptionService(),
         automaticRefresh: Bool = true) {
        self.store = store; self.service = service
        do { try store.load() }
        catch { self.error = safeError(error) }
        publish()
        if automaticRefresh {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self else { return }
                    await self.refreshDueSubscriptions()
                }
            }
        }
    }
    deinit { timer?.cancel() }

    func clearMessages() { error = nil; notice = nil }

    func readNode(id: UUID) throws -> ProxyNode {
        guard let metadata = store.snapshot.nodes.first(where: { $0.id == id }) else { throw StoreError.missingNode }
        return try store.readNode(metadata)
    }

    func saveNode(_ node: ProxyNode) throws {
        guard node.sourceID == nil else { throw StoreError.subscriptionNode }
        if let previous = nodes.first(where: { $0.id == node.id }), previous.sourceID != nil { throw StoreError.subscriptionNode }
        var next = store.snapshot
        let previous = next.nodes.first { $0.id == node.id }
        guard !next.nodes.contains(where: { $0.id != node.id && $0.name == node.name }) else { throw StoreError.duplicateName }
        let reference = UUID()
        let metadata = NodeMetadata(node: node, secretID: reference)
        if let index = next.nodes.firstIndex(where: { $0.id == node.id }) { next.nodes[index] = metadata }
        else { next.nodes.append(metadata) }
        if let oldName = previous?.name, oldName != node.name {
            for index in next.rules.indices where next.rules[index].policy == oldName { next.rules[index].policy = node.name }
            for index in next.subscriptionRules.indices where next.subscriptionRules[index].policy == oldName { next.subscriptionRules[index].policy = node.name }
            if next.selectedNode == oldName { next.selectedNode = node.name }
            if next.fallbackPolicy == oldName { next.fallbackPolicy = node.name }
        }
        try validate(next, overrides: [reference: node])
        try commit(next, additions: [reference: try JSONEncoder().encode(node)], removing: Set([previous?.secretID].compactMap { $0 }))
        notice = "节点已保存。"
    }

    func removeNode(id: UUID) throws {
        guard let node = store.snapshot.nodes.first(where: { $0.id == id }) else { throw StoreError.missingNode }
        guard node.sourceID == nil else { throw StoreError.subscriptionNode }
        var next = store.snapshot
        next.nodes.removeAll { $0.id == id }
        if next.selectedNode == node.name { next.selectedNode = nil }
        try validate(next)
        try commit(next, removing: [node.secretID])
    }

    func importText(_ text: String) throws {
        guard text.utf8.count <= SubscriptionService.maximumBytes else { throw SubscriptionError.responseTooLarge }
        let parsed = try SubscriptionParser.parse(Data(text.utf8))
        guard !parsed.nodes.isEmpty else { throw StoreError.invalidData }
        var next = store.snapshot
        var additions: [UUID: Data] = [:]
        var overrides: [UUID: ProxyNode] = [:]
        var removed: Set<UUID> = []
        for var node in parsed.nodes {
            node.sourceID = nil
            let reference = UUID()
            if let previous = next.nodes.first(where: { $0.name == node.name }) {
                guard previous.sourceID == nil, previous.server == node.server, previous.type == node.type else { throw StoreError.duplicateName }
                node.id = previous.id
                next.nodes.removeAll { $0.id == previous.id }
                removed.insert(previous.secretID)
            }
            next.nodes.append(NodeMetadata(node: node, secretID: reference))
            additions[reference] = try JSONEncoder().encode(node)
            overrides[reference] = node
        }
        next.rules.append(contentsOf: parsed.rules.map { var rule = $0; rule.sourceID = nil; return rule })
        try validate(next, overrides: overrides)
        try commit(next, additions: additions, removing: removed)
        notice = "已在本机导入 \(parsed.nodes.count) 个节点。" + (parsed.warnings.isEmpty ? "" : " " + parsed.warnings.joined(separator: " "))
    }

    func addSubscription(name: String, url: String, interval: TimeInterval) throws {
        try checkInterval(interval)
        let checked = try SubscriptionService.validatedURL(url)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 120, !name.contains("://") else { throw StoreError.invalidData }
        var next = store.snapshot
        let reference = UUID()
        next.subscriptions.append(SubscriptionMetadata(name: name, refreshInterval: interval, secretID: reference))
        try commit(next, additions: [reference: try JSONEncoder().encode(SubscriptionSecret(url: checked.absoluteString))])
        notice = "订阅已保存，可点击刷新下载。"
    }

    func updateSubscription(id: UUID, name: String, interval: TimeInterval) throws {
        try checkInterval(interval)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 120, !clean.contains("://") else { throw StoreError.invalidData }
        var next = store.snapshot
        guard let index = next.subscriptions.firstIndex(where: { $0.id == id }) else { throw StoreError.missingNode }
        next.subscriptions[index].name = clean; next.subscriptions[index].refreshInterval = interval
        try commit(next)
    }

    func refreshSubscription(id: UUID) async throws {
        guard !refreshing.contains(id) else { return }
        guard let metadata = store.snapshot.subscriptions.first(where: { $0.id == id }) else { throw StoreError.missingNode }
        refreshing.insert(id); lastAttempt[id] = Date()
        defer { refreshing.remove(id) }
        do {
            let secret = try store.readSubscription(metadata)
            let url = try SubscriptionService.validatedURL(secret.url)
            let download = try await service.fetch(url)
            guard download.data.count <= SubscriptionService.maximumBytes else { throw SubscriptionError.responseTooLarge }
            let parsed = try SubscriptionParser.parse(download.data, sourceID: id)
            guard !parsed.nodes.isEmpty else { throw StoreError.invalidData }
            guard let currentIndex = store.snapshot.subscriptions.firstIndex(where: { $0.id == id }),
                  store.snapshot.subscriptions[currentIndex].secretID == metadata.secretID else { throw SubscriptionError.staleRequest }
            var next = store.snapshot
            let previous = next.nodes.filter { $0.sourceID == id }
            var removed = Set(previous.map(\.secretID)); removed.insert(metadata.secretID)
            next.nodes.removeAll { $0.sourceID == id }
            next.subscriptionRules.removeAll { $0.sourceID == id }
            var additions: [UUID: Data] = [:]
            var overrides: [UUID: ProxyNode] = [:]
            for var node in parsed.nodes {
                if next.nodes.contains(where: { $0.name == node.name }) {
                    // Another subscription or a manual node already uses this name; disambiguate.
                    let suffix = Self.truncated(" · " + metadata.name.replacingOccurrences(of: ",", with: " "), bytes: 48)
                    let renamed = (Self.truncated(node.name, bytes: 128 - suffix.utf8.count) + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !next.nodes.contains(where: { $0.name == renamed }) else { throw StoreError.duplicateName }
                    node.name = renamed
                }
                node.sourceID = id
                if let existing = previous.first(where: { $0.name == node.name }) { node.id = existing.id }
                let reference = UUID()
                next.nodes.append(NodeMetadata(node: node, secretID: reference))
                additions[reference] = try JSONEncoder().encode(node); overrides[reference] = node
            }
            next.subscriptionRules.append(contentsOf: parsed.rules.map { var rule = $0; rule.sourceID = id; return rule })
            let subscriptionReference = UUID()
            next.subscriptions[currentIndex].secretID = subscriptionReference
            next.subscriptions[currentIndex].lastUpdated = Date()
            // Many panels only send subscription-userinfo to some clients; keep the last known value.
            if let info = download.userInfo { next.subscriptions[currentIndex].userInfo = info }
            additions[subscriptionReference] = try JSONEncoder().encode(SubscriptionSecret(url: secret.url, payload: download.data))
            if let selected = next.selectedNode, !next.nodes.contains(where: { $0.name == selected }) { next.selectedNode = nil }
            // Rules pointing at a node the provider renamed or removed fall back to this subscription's group.
            Self.repoint(&next, from: Set(previous.map(\.name)).subtracting(next.nodes.map(\.name)), to: ConfigurationBuilder.sourcePolicy(id))
            try validate(next, overrides: overrides)
            try commit(next, additions: additions, removing: removed)
            notice = "订阅已更新：\(parsed.nodes.count) 个节点。点击「应用配置」后用于当前会话。" + (parsed.warnings.isEmpty ? "" : " " + parsed.warnings.joined(separator: " "))
        } catch {
            self.error = safeError(error)
            throw error
        }
    }

    func removeSubscription(id: UUID) throws {
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { throw StoreError.missingNode }
        var next = store.snapshot
        let removedNodes = next.nodes.filter { $0.sourceID == id }
        next.nodes.removeAll { $0.sourceID == id }
        next.subscriptions.removeAll { $0.id == id }
        next.subscriptionRules.removeAll { $0.sourceID == id }
        if let selected = next.selectedNode, removedNodes.contains(where: { $0.name == selected }) { next.selectedNode = nil }
        Self.repoint(&next, from: Set(removedNodes.map(\.name) + [ConfigurationBuilder.sourcePolicy(id)]), to: "PROXY")
        try validate(next)
        try commit(next, removing: Set(removedNodes.map(\.secretID) + [subscription.secretID]))
    }

    func setSubscriptionEnabled(id: UUID, enabled: Bool) throws {
        var next = store.snapshot
        guard let index = next.subscriptions.firstIndex(where: { $0.id == id }) else { throw StoreError.missingNode }
        next.subscriptions[index].enabled = enabled
        if !enabled, let selected = next.selectedNode, next.nodes.contains(where: { $0.sourceID == id && $0.name == selected }) { next.selectedNode = nil }
        if !enabled {
            Self.repoint(&next, from: Set(next.nodes.filter { $0.sourceID == id }.map(\.name) + [ConfigurationBuilder.sourcePolicy(id)]), to: "PROXY")
        }
        try validate(next)
        try commit(next)
    }

    func persistRules(_ rules: [RoutingRule]) throws {
        guard rules.allSatisfy({ $0.sourceID == nil }), Set(rules.map(\.id)).count == rules.count else { throw StoreError.invalidRules }
        var next = store.snapshot; next.rules = rules
        try validate(next); try commit(next)
    }

    func moveRules(from indices: IndexSet, to destination: Int) throws {
        guard destination >= 0, destination <= rules.count,
              indices.allSatisfy({ rules.indices.contains($0) }) else { throw StoreError.invalidRules }
        let moving = indices.sorted().map { rules[$0] }
        var reordered = rules.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        let insertion = destination - indices.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        try persistRules(reordered)
    }

    func setFallbackPolicy(_ policy: String) throws {
        var next = store.snapshot; next.fallbackPolicy = policy
        try validate(next); try commit(next)
    }
    func selectNode(_ name: String?) throws {
        var next = store.snapshot; next.selectedNode = name
        try validate(next); try commit(next)
    }
    func saveAdvancedYAML(_ text: String) throws {
        var next = store.snapshot
        next.advanced = try AdvancedOptions.parse(yaml: text)
        try validate(next); try commit(next)
        // Only the parsed allowlisted model is stored. Comments and pasted secrets are discarded.
    }
    func runtimeProfile(mode: OutboundMode) throws -> RuntimeProfile {
        guard store.loaded else { throw StoreError.notLoaded }
        let profile = try runtime(store.snapshot, mode: mode)
        try ConfigurationBuilder.validate(profile)
        return profile
    }
    func migrateLegacyCredentials() throws {
        defer { publish() }
        do {
            try store.migrateLegacyCredentials()
            error = nil
            notice = "旧配置已迁移到本机配置文件。"
        } catch {
            self.error = safeError(error)
            throw error
        }
    }
    func retrySecretCleanup() throws {
        guard store.loaded else { throw StoreError.notLoaded }
        store.cleanupPending(); publish()
        if pendingSecretCleanup > 0 { throw StoreError.missingSecret }
    }
    func removeAllData() throws {
        var next = LibrarySnapshot()
        next.rules = [.chatGPT]
        try commit(next, removing: store.snapshot.activeSecretIDs)
        notice = pendingSecretCleanup == 0 ? "配置已清理，可退出后卸载。" : "配置已清理；旧钥匙串条目可单独清理。"
    }

    /// Cuts `text` at a character boundary so that it fits in `bytes` UTF-8 bytes.
    private static func truncated(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
    /// Points user rules and the fallback at `replacement` when they name a policy that is going away.
    private static func repoint(_ snapshot: inout LibrarySnapshot, from removed: Set<String>, to replacement: String) {
        guard !removed.isEmpty else { return }
        for index in snapshot.rules.indices where removed.contains(snapshot.rules[index].policy) { snapshot.rules[index].policy = replacement }
        if removed.contains(snapshot.fallbackPolicy) { snapshot.fallbackPolicy = replacement }
    }
    private func checkInterval(_ interval: TimeInterval) throws {
        guard interval.isFinite, (300...2_592_000).contains(interval) else { throw StoreError.invalidInterval }
    }
    private func refreshDueSubscriptions() async {
        guard store.loaded else { return }
        let now = Date()
        let due = subscriptions.filter { subscription in
            guard subscription.enabled else { return false }
            let last = max(subscription.lastUpdated ?? .distantPast, lastAttempt[subscription.id] ?? .distantPast)
            return now.timeIntervalSince(last) >= subscription.refreshInterval
        }.map(\.id)
        for id in due {
            if Task.isCancelled { return }
            do { try await refreshSubscription(id: id) } catch { self.error = safeError(error) }
        }
    }
    private func runtime(_ snapshot: LibrarySnapshot, mode: OutboundMode = .rule,
                         overrides: [UUID: ProxyNode] = [:]) throws -> RuntimeProfile {
        let enabled = Set(snapshot.subscriptions.filter(\.enabled).map(\.id))
        let nodes = try snapshot.nodes.filter { $0.sourceID == nil || enabled.contains($0.sourceID!) }.map {
            if let node = overrides[$0.secretID] { return node }
            return try store.readNode($0)
        }
        let subscriptionRules = snapshot.subscriptionRules.filter { $0.sourceID.map(enabled.contains) ?? false }
        return RuntimeProfile(nodes: nodes, mode: mode, rules: snapshot.rules + subscriptionRules,
                              fallbackPolicy: snapshot.fallbackPolicy, selectedNode: snapshot.selectedNode, advanced: snapshot.advanced)
    }
    private func validate(_ snapshot: LibrarySnapshot, overrides: [UUID: ProxyNode] = [:]) throws {
        try ConfigurationBuilder.validate(runtime(snapshot, overrides: overrides))
    }
    private func commit(_ next: LibrarySnapshot, additions: [UUID: Data] = [:], removing: Set<UUID> = []) throws {
        defer { publish() }
        do { try store.commit(next, additions: additions, removing: removing); error = nil }
        catch { self.error = safeError(error); throw error }
    }
    private func publish() {
        let snapshot = store.snapshot
        nodes = snapshot.nodes; subscriptions = snapshot.subscriptions
        rules = snapshot.rules; subscriptionRules = snapshot.subscriptionRules
        fallbackPolicy = snapshot.fallbackPolicy; selectedNode = snapshot.selectedNode
        pendingSecretCleanup = snapshot.pendingSecretIDs.count
        migrationRequired = store.migrationRequired
        advancedYAML = canonicalAdvanced(snapshot.advanced)
        if let warning = store.warning { notice = warning }
    }
    private func canonicalAdvanced(_ value: AdvancedOptions) -> String { value.yamlString }
    private func safeError(_ error: any Error) -> String {
        // These error types are built never to echo URLs, credentials or raw input.
        if error is StoreError || error is SubscriptionError || error is ConfigurationError
            || error is SubscriptionFieldDiagnostic || error is YAMLParseError { return error.localizedDescription }
        if error is CancellationError { return "操作已取消。" }
        return "资料操作失败，原配置已保留；地址、凭据与原始响应不会写入日志。"
    }
}

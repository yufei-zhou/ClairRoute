import Foundation

private struct LibraryTestFailure: Error { var message: String }
private func libraryExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LibraryTestFailure(message: message) }
}
private func libraryRejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw LibraryTestFailure(message: "Unexpected acceptance: " + message)
}

/// A trap for all ordinary v3 operations, and an explicit legacy fixture for migration tests.
private final class MemorySecretVault: SecretVault {
    var values: [UUID: Data] = [:]
    var reads: [UUID] = []
    var writes: [UUID] = []
    var removals: [UUID] = []
    var rejectAllAccess = false
    var failDeletes = false
    var beforeRemove: (() throws -> Void)?

    func read(_ id: UUID) throws -> Data {
        reads.append(id)
        guard !rejectAllAccess else { throw LibraryTestFailure(message: "Unexpected Keychain read") }
        guard let data = values[id] else { throw StoreError.missingSecret }
        return data
    }
    func write(_ data: Data, id: UUID) throws {
        writes.append(id)
        throw LibraryTestFailure(message: "Plaintext persistence must never write to Keychain")
    }
    func remove(_ id: UUID) throws {
        removals.append(id)
        guard !rejectAllAccess else { throw LibraryTestFailure(message: "Unexpected Keychain deletion") }
        try beforeRemove?()
        if failDeletes { throw StoreError.keychain(-1) }
        values.removeValue(forKey: id)
    }
    func expectUnused() throws {
        try libraryExpect(reads.isEmpty && writes.isEmpty && removals.isEmpty,
                          "ordinary plaintext operations never access Keychain")
    }
}

private struct NoNetworkSubscriptionFetcher: SubscriptionFetching {
    func fetch(_ url: URL) async throws -> SubscriptionDownload {
        throw LibraryTestFailure(message: "A test tried to access a subscription")
    }
}
private actor ScriptedSubscriptionFetcher: SubscriptionFetching {
    private let expectedURL: URL
    private var downloads: [SubscriptionDownload]
    private(set) var calls = 0
    init(url: URL, downloads: [SubscriptionDownload]) { expectedURL = url; self.downloads = downloads }
    func fetch(_ url: URL) async throws -> SubscriptionDownload {
        try libraryExpect(url == expectedURL && !downloads.isEmpty, "only the expected mocked subscription is fetched")
        calls += 1
        return downloads.removeFirst()
    }
}

private func profileFile(_ directory: URL) -> URL { directory.appendingPathComponent("profile.json") }
private func diskSnapshot(_ directory: URL) throws -> LibrarySnapshot {
    try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: profileFile(directory)))
}
private func writeFixture(_ snapshot: LibrarySnapshot, directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(snapshot).write(to: profileFile(directory))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile(directory).path)
}
private func checkPrivatePermissions(_ directory: URL) throws {
    let file = try FileManager.default.attributesOfItem(atPath: profileFile(directory).path)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    try libraryExpect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600, "profile permissions are 0600")
    try libraryExpect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "profile directory permissions are 0700")
}

@MainActor private func runPlaintextPersistenceTests(directory: URL) throws {
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: vault)
    let library = AppLibraryModel(store: store, service: NoNetworkSubscriptionFetcher(), automaticRefresh: false)
    try libraryExpect(library.error == nil && store.loaded && !store.migrationRequired, "new plaintext library loads without migration")
    let password = "plaintext-fixture-password"
    var node = ProxyNode(name: "Offline SS", server: "example.test", port: 443, cipher: "aes-256-gcm", password: password)
    try library.saveNode(node)
    let authenticationUUID = "a79073a5-6872-4273-9bc5-eedbfbd4a441"
    let vmess = ProxyNode(name: "Offline VMess", server: "example.test", port: 443, type: .vmess, uuid: authenticationUUID)
    try library.saveNode(vmess)
    try library.addSubscription(name: "Offline subscription", url: "https://example.test/sub?token=plaintext-fixture-token", interval: 300)
    let disk = try String(contentsOf: profileFile(directory), encoding: .utf8)
    try libraryExpect(disk.contains(password) && disk.contains(authenticationUUID) && disk.contains("plaintext-fixture-token"),
                      "password, authentication UUID and subscription URL are stored in the plaintext profile")
    try libraryExpect(try diskSnapshot(directory).version == 3, "plaintext schema version is 3")
    try checkPrivatePermissions(directory)

    let a = RoutingRule(kind: .domainSuffix, value: "first.test")
    let b = RoutingRule(kind: .domain, value: "second.test", policy: "DIRECT")
    try library.persistRules([a, b]); try library.moveRules(from: IndexSet(integer: 1), to: 0)
    try libraryExpect(library.rules.map(\.id) == [b.id, a.id], "rule move preserves identity and order")
    try library.selectNode(node.name)
    for _ in 0..<3 { _ = try library.runtimeProfile(mode: .rule); _ = try library.readNode(id: node.id) }
    let reloadedStore = ProfileStore(directory: directory, vault: vault)
    let reloaded = AppLibraryModel(store: reloadedStore, service: NoNetworkSubscriptionFetcher(), automaticRefresh: false)
    try libraryExpect(reloaded.error == nil && reloaded.selectedNode == node.name, "restart restores selected node without Keychain")
    try libraryExpect(try reloaded.readNode(id: node.id).password == password, "restart restores plaintext credentials")
    try reloadedStore.load()
    try libraryExpect(try reloaded.runtimeProfile(mode: .global).nodes.count == 2, "reload and runtime generation use the file")
    node.password = "plaintext-fixture-replacement"
    try reloaded.saveNode(node)
    let changedDisk = try String(contentsOf: profileFile(directory), encoding: .utf8)
    try libraryExpect(changedDisk.contains(node.password) && !changedDisk.contains(password), "editing replaces the old plaintext password")
    try libraryExpect(reloadedStore.snapshot.nodeSecrets?.count == 2 && reloaded.pendingSecretCleanup == 0,
                      "node replacement drops obsolete plaintext records without scheduling Keychain cleanup")
    try reloaded.removeNode(id: node.id)
    try libraryExpect(try reloaded.runtimeProfile(mode: .rule).nodes.count == 1, "node removal updates runtime configuration")
    try reloaded.removeAllData()
    let cleared = try diskSnapshot(directory)
    try libraryExpect(cleared.nodes.isEmpty && cleared.subscriptions.isEmpty && cleared.nodeSecrets?.isEmpty == true && cleared.subscriptionSecrets?.isEmpty == true,
                      "remove all clears plaintext credentials and subscriptions")
    try libraryExpect(reloaded.pendingSecretCleanup == 0, "ordinary deletion creates no legacy cleanup work")
    try vault.expectUnused()
}

@MainActor private func runSubscriptionPersistenceTests(directory: URL) async throws {
    let url = URL(string: "https://example.test/sub?token=mock-subscription-token")!
    func payload(_ password: String) -> Data {
        Data("""
        proxies:
          - name: Subscription SS
            type: ss
            server: example.test
            port: 443
            cipher: aes-256-gcm
            password: \(password)
        rules:
          - DOMAIN-SUFFIX,subscription.test,PROXY
        """.utf8)
    }
    let firstPayload = payload("mock-subscription-first")
    let secondPayload = payload("mock-subscription-second")
    let accounting = SubscriptionUserInfo.parse("upload=123; download=456; total=1000; expire=1900000000")
    let fetcher = ScriptedSubscriptionFetcher(url: url, downloads: [SubscriptionDownload(data: firstPayload, userInfo: nil), SubscriptionDownload(data: secondPayload, userInfo: accounting)])
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: vault)
    let library = AppLibraryModel(store: store, service: fetcher, automaticRefresh: false)
    try library.addSubscription(name: "Mock source", url: url.absoluteString, interval: 300)
    let id = library.subscriptions[0].id
    try await library.refreshSubscription(id: id)
    let nodeID = library.nodes[0].id
    try library.selectNode("Subscription SS")
    try library.updateSubscription(id: id, name: "Renamed source", interval: 600)
    try await library.refreshSubscription(id: id)
    try libraryExpect(library.nodes[0].id == nodeID && library.selectedNode == "Subscription SS", "refresh preserves stable node identity and selection")
    let disk = try String(contentsOf: profileFile(directory), encoding: .utf8)
    try libraryExpect(disk.contains("mock-subscription-second") && !disk.contains("mock-subscription-first"), "subscription refresh replaces plaintext node credentials")
    let saved = try diskSnapshot(directory)
    try libraryExpect(saved.nodes.count == 1 && saved.nodeSecrets?.count == 1 && saved.subscriptionSecrets?.count == 1,
                      "refresh retains only current node and subscription records")
    let secret = try store.readSubscription(saved.subscriptions[0])
    try libraryExpect(secret.url == url.absoluteString && secret.payload == secondPayload, "subscription URL and updated source payload roundtrip")
    try libraryExpect(saved.subscriptions[0].userInfo == accounting && saved.subscriptions[0].refreshInterval == 600,
                      "subscription metadata persists alongside credentials")
    let reloadedStore = ProfileStore(directory: directory, vault: vault)
    let reloaded = AppLibraryModel(store: reloadedStore, service: NoNetworkSubscriptionFetcher(), automaticRefresh: false)
    try libraryExpect(try reloaded.runtimeProfile(mode: .rule).nodes[0].password == "mock-subscription-second", "restart uses refreshed credentials without Keychain")
    try reloaded.removeSubscription(id: id)
    let removedDisk = try String(contentsOf: profileFile(directory), encoding: .utf8)
    try libraryExpect(!removedDisk.contains("mock-subscription-second") && !removedDisk.contains("mock-subscription-token"), "removing a subscription removes its plaintext credentials")
    let calls = await fetcher.calls
    try libraryExpect(calls == 2, "both refreshes used only the mock fetcher")
    try vault.expectUnused()
}

/// Provider-side renames and name clashes must not make every later refresh fail.
@MainActor private func runSubscriptionChurnTests(directory: URL) async throws {
    let url = URL(string: "https://example.test/churn")!
    func payload(_ name: String) -> Data {
        Data("""
        proxies:
          - {name: \(name), type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: mock-churn}
        """.utf8)
    }
    let fetcher = ScriptedSubscriptionFetcher(url: url, downloads: [
        SubscriptionDownload(data: payload("HK 01"), userInfo: SubscriptionUserInfo.parse("upload=1; download=2; total=3")),
        SubscriptionDownload(data: payload("HK 01 New"), userInfo: nil),
        SubscriptionDownload(data: payload("Manual"), userInfo: nil)])
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let library = AppLibraryModel(store: ProfileStore(directory: directory, vault: vault), service: fetcher, automaticRefresh: false)
    try library.saveNode(ProxyNode(name: "Manual", server: "example.test", port: 8443, cipher: "aes-256-gcm", password: "mock-manual"))
    try library.addSubscription(name: "Churn", url: url.absoluteString, interval: 300)
    let id = library.subscriptions[0].id
    try await library.refreshSubscription(id: id)
    try library.persistRules(library.rules + [RoutingRule(kind: .domainSuffix, value: "churn.test", policy: "HK 01")])
    try library.setFallbackPolicy("HK 01")
    try await library.refreshSubscription(id: id)
    let group = ConfigurationBuilder.sourcePolicy(id)
    try libraryExpect(library.rules.last?.policy == group && library.fallbackPolicy == group, "rules and fallback for a renamed node move to the subscription group")
    try libraryExpect(library.subscriptions[0].userInfo != nil, "a refresh without usage headers keeps the last known usage")
    try await library.refreshSubscription(id: id)
    try libraryExpect(library.nodes.contains { $0.name == "Manual" && $0.sourceID == nil } && library.nodes.contains { $0.name == "Manual · Churn" && $0.sourceID == id },
                      "a subscription node that clashes with a manual node is renamed instead of failing")
    try library.setSubscriptionEnabled(id: id, enabled: false)
    try libraryExpect(library.fallbackPolicy == group && library.rules.last?.policy == group,
                      "disabling a subscription preserves saved targets")
    try libraryExpect(try library.runtimeProfile(mode: .rule).fallbackPolicy == "REJECT",
                      "disabled subscription targets reject in the transient runtime profile")
    try library.setSubscriptionEnabled(id: id, enabled: true)
    try libraryExpect(try library.runtimeProfile(mode: .rule).fallbackPolicy == group,
                      "reenabling restores the saved targets")
    try vault.expectUnused()
}

/// Aliases remain bound to their source through collisions, source renames and refresh reordering.
@MainActor private func runSubscriptionAliasTests(directory: URL) async throws {
    let url = URL(string: "https://example.test/aliases")!
    func payload(_ server: String, domain: String) -> Data {
        Data("""
        proxies:
          - {name: Shared, type: ss, server: \(server), port: 443, cipher: aes-256-gcm, password: mock-alias}
        rules:
          - DOMAIN,\(domain),Shared
        """.utf8)
    }
    let first = payload("one.example.test", domain: "one.test")
    let second = payload("two.example.test", domain: "two.test")
    let fetcher = ScriptedSubscriptionFetcher(url: url, downloads: [first, second, second, first].map {
        SubscriptionDownload(data: $0, userInfo: nil)
    })
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: vault)
    let library = AppLibraryModel(store: store, service: fetcher, automaticRefresh: false)
    let manual = ProxyNode(name: "Shared", server: "manual.example.test", port: 443, cipher: "aes-256-gcm", password: "mock-manual")
    try library.saveNode(manual)
    try library.addSubscription(name: "Same source", url: url.absoluteString, interval: 300)
    try library.addSubscription(name: "Same source", url: url.absoluteString, interval: 300)
    let a = library.subscriptions[0].id, b = library.subscriptions[1].id
    try await library.refreshSubscription(id: a)
    try await library.refreshSubscription(id: b)
    let savedA = library.nodes.first { $0.sourceID == a }!
    let savedB = library.nodes.first { $0.sourceID == b }!
    try libraryExpect(savedA.name == "Shared · Same source" && savedB.name == "Shared · Same source 2",
                      "colliding source names receive unique aliases")
    try libraryExpect(library.subscriptionRules.first { $0.sourceID == a }?.policy == savedA.name &&
                      library.subscriptionRules.first { $0.sourceID == b }?.policy == savedB.name,
                      "each provider rule is remapped to its own aliased node")
    try library.persistRules([RoutingRule(kind: .domain, value: "chosen.test", policy: savedA.name)])
    try library.setFallbackPolicy(savedB.name)
    try library.selectNode(savedA.name)
    try library.removeNode(id: manual.id)
    try library.updateSubscription(id: a, name: "Renamed source", interval: 300)
    try await library.refreshSubscription(id: b)
    try await library.refreshSubscription(id: a)
    let refreshedA = library.nodes.first { $0.sourceID == a }!
    let refreshedB = library.nodes.first { $0.sourceID == b }!
    try libraryExpect(refreshedA.name == savedA.name && refreshedA.id == savedA.id &&
                      refreshedB.name == savedB.name && refreshedB.id == savedB.id,
                      "aliases and identities survive source rename, disappearing collisions and refresh order changes")
    try libraryExpect(library.rules[0].policy == savedA.name && library.fallbackPolicy == savedB.name && library.selectedNode == savedA.name,
                      "refresh preserves user rules, fallback and selected node")
    try libraryExpect(library.subscriptionRules.first { $0.sourceID == a }?.policy == savedA.name &&
                      library.subscriptionRules.first { $0.sourceID == b }?.policy == savedB.name,
                      "refreshed provider rules retain their source-specific aliases")
    try vault.expectUnused()
}

@MainActor private func runSubscriptionDisableTests(directory: URL) async throws {
    let url = URL(string: "https://example.test/disable")!
    let data = Data("""
    proxies:
      - {name: Disabled SS, type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: mock-disable}
    rules:
      - DOMAIN,provider.test,Disabled SS
    """.utf8)
    let fetcher = ScriptedSubscriptionFetcher(url: url, downloads: [SubscriptionDownload(data: data, userInfo: nil)])
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: vault)
    let library = AppLibraryModel(store: store, service: fetcher, automaticRefresh: false)
    let manual = ProxyNode(name: "Available SS", server: "manual.example.test", port: 443, cipher: "aes-256-gcm", password: "mock-available")
    try library.saveNode(manual)
    try library.addSubscription(name: "Toggle source", url: url.absoluteString, interval: 300)
    let id = library.subscriptions[0].id, group = ConfigurationBuilder.sourcePolicy(id)
    try await library.refreshSubscription(id: id)
    let nodeName = library.nodes.first { $0.sourceID == id }!.name
    let rules = [RoutingRule(kind: .domain, value: "node.test", policy: nodeName),
                 RoutingRule(kind: .domain, value: "group.test", policy: group)]
    try library.persistRules(rules)
    try library.setFallbackPolicy(group)
    try library.selectNode(nodeName)
    try library.setSubscriptionEnabled(id: id, enabled: false)
    let disk = try diskSnapshot(directory)
    try libraryExpect(disk.rules == rules && disk.fallbackPolicy == group && disk.selectedNode == nodeName,
                      "disabling retains rules, fallback and selection in the committed file")
    try libraryRejects("applying an unavailable selection must require a deliberate replacement") {
        _ = try library.runtimeProfile(mode: .global)
    }
    let reloaded = AppLibraryModel(store: ProfileStore(directory: directory, vault: vault), service: NoNetworkSubscriptionFetcher(), automaticRefresh: false)
    try libraryExpect(reloaded.error == nil && reloaded.rules == rules && reloaded.selectedNode == nodeName,
                      "disabled references survive restarting the library")
    try reloaded.setSubscriptionEnabled(id: id, enabled: true)
    let restored = try reloaded.runtimeProfile(mode: .rule)
    try libraryExpect(restored.selectedNode == nodeName && restored.fallbackPolicy == group && Array(restored.rules.prefix(rules.count)) == rules,
                      "reenabling restores exact selection, rule targets and fallback")
    try reloaded.setSubscriptionEnabled(id: id, enabled: false)
    try reloaded.selectNode(manual.name)
    let disabled = try reloaded.runtimeProfile(mode: .rule)
    try libraryExpect(disabled.nodes.map(\.name) == [manual.name] && disabled.rules.map(\.policy) == ["REJECT", "REJECT"] && disabled.fallbackPolicy == "REJECT",
                      "unavailable rule and fallback targets reject instead of switching to another node")
    try libraryExpect(reloaded.rules == rules && reloaded.fallbackPolicy == group,
                      "runtime projection does not mutate saved preferences")
    try vault.expectUnused()
}

@MainActor private func runDisabledLibraryValidationTests(directory: URL) async throws {
    let url = URL(string: "https://example.test/disabled-validation")!
    let data = Data("""
    proxies:
      - {name: Node, type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: mock-disabled}
    rules:
      - DOMAIN,provider.test,Node
    """.utf8)
    let fetcher = ScriptedSubscriptionFetcher(url: url, downloads: [SubscriptionDownload(data: data, userInfo: nil)])
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: vault)
    let library = AppLibraryModel(store: store, service: fetcher, automaticRefresh: false)
    try library.addSubscription(name: "Disabled validation", url: url.absoluteString, interval: 300)
    let id = library.subscriptions[0].id
    try await library.refreshSubscription(id: id)
    try library.selectNode("Node")
    try library.setSubscriptionEnabled(id: id, enabled: false)
    let original = try Data(contentsOf: profileFile(directory))
    try libraryRejects("manual node case-folding collision with a disabled subscription node") {
        try library.saveNode(ProxyNode(name: "node", server: "manual.example.test", port: 443, cipher: "aes-256-gcm", password: "mock-manual"))
    }
    try libraryExpect(try Data(contentsOf: profileFile(directory)) == original,
                      "invalid edits preserve the committed disabled profile")
    let valid = try diskSnapshot(directory)
    func rejectsFixture(_ name: String, _ mutate: (inout LibrarySnapshot) -> Void) throws {
        var fixture = valid; mutate(&fixture)
        let target = directory.appendingPathComponent(name)
        try writeFixture(fixture, directory: target)
        let reloaded = ProfileStore(directory: target, vault: vault)
        try libraryRejects(name) { try reloaded.load() }
        try libraryExpect(!reloaded.loaded, "invalid saved entries are rejected even while disabled")
    }
    try rejectsFixture("dangling-disabled-rule") { $0.subscriptionRules[0].policy = "Missing node" }
    try rejectsFixture("invalid-disabled-rule") { $0.subscriptionRules[0].value = "" }
    try rejectsFixture("unknown-rule-source") { $0.subscriptionRules[0].sourceID = UUID() }
    try rejectsFixture("dangling-selection") { $0.selectedNode = "Missing node" }
    try rejectsFixture("dangling-fallback") { $0.fallbackPolicy = "Missing node" }
    try vault.expectUnused()
}

@MainActor private func runAtomicFailureTests(directory: URL) throws {
    let vault = MemorySecretVault(); vault.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: vault)
    let library = AppLibraryModel(store: store, service: NoNetworkSubscriptionFetcher(), automaticRefresh: false)
    var node = ProxyNode(name: "Atomic SS", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "atomic-original")
    try library.saveNode(node)
    let original = try Data(contentsOf: profileFile(directory))
    let originalReference = store.snapshot.nodes[0].secretID
    // An unsafe destination is rejected before rename; neither memory nor file may commit.
    let hardlink = directory.appendingPathComponent("test-hardlink")
    try FileManager.default.linkItem(at: profileFile(directory), to: hardlink)
    node.password = "atomic-uncommitted"
    try libraryRejects("profile destination with extra hard link") { try library.saveNode(node) }
    try FileManager.default.removeItem(at: hardlink)
    try libraryExpect(try Data(contentsOf: profileFile(directory)) == original, "failed pre-rename save preserves the exact original file")
    try libraryExpect(store.snapshot.nodes[0].secretID == originalReference && (try library.readNode(id: node.id)).password == "atomic-original",
                      "failed pre-rename save preserves committed in-memory credentials")
    try library.saveNode(node)
    try libraryExpect(try library.readNode(id: node.id).password == "atomic-uncommitted", "save can be retried after filesystem failure")
    try checkPrivatePermissions(directory)
    try vault.expectUnused()
}

private func legacyFixture(node: ProxyNode, nodeReference: UUID, subscriptionReference: UUID) -> LibrarySnapshot {
    var legacy = LibrarySnapshot(); legacy.version = 2
    legacy.nodeSecrets = nil; legacy.subscriptionSecrets = nil
    legacy.nodes = [NodeMetadata(node: node, secretID: nodeReference)]
    legacy.subscriptions = [SubscriptionMetadata(name: "Legacy source", refreshInterval: 600, secretID: subscriptionReference)]
    legacy.rules = [RoutingRule(kind: .domain, value: "legacy.test", policy: node.name)]
    legacy.selectedNode = node.name
    return legacy
}

private func runMigrationTests(directory: URL) throws {
    let node = ProxyNode(name: "Legacy SS", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "legacy-fixture-password")
    let nodeReference = UUID(), subscriptionReference = UUID(), retiredReference = UUID()
    let subscription = SubscriptionSecret(url: "https://example.test/sub?token=legacy-fixture-token", payload: Data("original-subscription-payload".utf8))
    var legacy = legacyFixture(node: node, nodeReference: nodeReference, subscriptionReference: subscriptionReference)
    legacy.pendingSecretIDs = [retiredReference]
    try writeFixture(legacy, directory: directory)
    let original = try Data(contentsOf: profileFile(directory))
    let vault = MemorySecretVault()
    vault.values[nodeReference] = try JSONEncoder().encode(node)
    vault.values[retiredReference] = Data("obsolete-fixture".utf8)
    let store = ProfileStore(directory: directory, vault: vault)
    try store.load()
    try libraryExpect(store.migrationRequired && !store.loaded, "legacy load exposes explicit migration without enabling runtime")
    try vault.expectUnused()
    try libraryRejects("missing legacy subscription credential") { try store.migrateLegacyCredentials() }
    try libraryExpect(!vault.reads.isEmpty && vault.removals.isEmpty && vault.writes.isEmpty,
                      "migration failure never deletes or replaces source Keychain records")
    try libraryExpect(try Data(contentsOf: profileFile(directory)) == original, "failed migration preserves the original file byte for byte")
    try libraryExpect(store.migrationRequired && !store.loaded && vault.values[nodeReference] != nil, "failed migration remains retryable")
    vault.values[subscriptionReference] = try JSONEncoder().encode(subscription)
    var deletesAfterCommit = 0
    vault.beforeRemove = {
        let disk = try diskSnapshot(directory)
        try libraryExpect(disk.version == 3 && disk.nodes.count == 1 && disk.subscriptions.count == 1,
                          "Keychain cleanup begins only after complete v3 metadata is committed")
        try libraryExpect(disk.nodeSecrets?[nodeReference.uuidString]?.password == node.password && disk.subscriptionSecrets?[subscriptionReference.uuidString]?.url == subscription.url,
                          "Keychain cleanup begins only after all plaintext credentials are committed")
        deletesAfterCommit += 1
    }
    try store.migrateLegacyCredentials()
    try libraryExpect(store.loaded && !store.migrationRequired && store.snapshot.version == 3, "explicit migration commits v3")
    try libraryExpect(try store.readNode(store.snapshot.nodes[0]).password == node.password, "migrated node credentials match source")
    try libraryExpect(try store.readSubscription(store.snapshot.subscriptions[0]).payload == subscription.payload, "migration preserves source payload")
    try libraryExpect(store.snapshot.rules.map(\.id) == legacy.rules.map(\.id) && store.snapshot.selectedNode == legacy.selectedNode,
                      "migration preserves rule order, identities and selected node")
    try libraryExpect(deletesAfterCommit == 3 && vault.values.isEmpty && store.snapshot.pendingSecretIDs.isEmpty,
                      "successful migration retires active and pending legacy Keychain records")
    try checkPrivatePermissions(directory)
    let trap = MemorySecretVault(); trap.rejectAllAccess = true
    let reopened = ProfileStore(directory: directory, vault: trap)
    try reopened.load()
    _ = try reopened.readNode(reopened.snapshot.nodes[0]); _ = try reopened.readSubscription(reopened.snapshot.subscriptions[0])
    try reopened.commit(reopened.snapshot)
    try trap.expectUnused()
}

private func runMigrationCleanupFailureTests(directory: URL) throws {
    let node = ProxyNode(name: "Retained legacy", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "cleanup-fixture")
    let nodeReference = UUID(), subscriptionReference = UUID()
    let legacy = legacyFixture(node: node, nodeReference: nodeReference, subscriptionReference: subscriptionReference)
    try writeFixture(legacy, directory: directory)
    let vault = MemorySecretVault()
    vault.values[nodeReference] = try JSONEncoder().encode(node)
    vault.values[subscriptionReference] = try JSONEncoder().encode(SubscriptionSecret(url: "https://example.test/sub"))
    vault.failDeletes = true
    let store = ProfileStore(directory: directory, vault: vault)
    try store.load(); try store.migrateLegacyCredentials()
    try libraryExpect(store.loaded && Set(store.snapshot.pendingSecretIDs) == [nodeReference, subscriptionReference],
                      "failed legacy deletion is queued after successful plaintext migration")
    let attempts = vault.removals.count, readCount = vault.reads.count
    let reloaded = ProfileStore(directory: directory, vault: vault)
    try reloaded.load()
    var next = reloaded.snapshot; next.fallbackPolicy = "PROXY"
    try reloaded.commit(next)
    _ = try reloaded.readNode(reloaded.snapshot.nodes[0])
    try libraryExpect(vault.removals.count == attempts && vault.reads.count == readCount,
                      "normal launches, reads and edits do not automatically retry legacy cleanup")
    try libraryExpect(Set(reloaded.snapshot.pendingSecretIDs) == [nodeReference, subscriptionReference], "ordinary commits preserve pending legacy cleanup")
    vault.failDeletes = false
    reloaded.cleanupPending()
    try libraryExpect(reloaded.snapshot.pendingSecretIDs.isEmpty && vault.values.isEmpty, "explicit cleanup retry removes legacy leftovers")
}

private func runPasswordOnlyMigrationTests(directory: URL) throws {
    let id = UUID()
    let fixture: [String: Any] = [
        "node": ["id": id.uuidString, "name": "M1 legacy", "server": "example.test", "port": 443, "cipher": "aes-256-gcm"],
        "chatGPTOnly": false, "mode": "rule", "pendingSecretIDs": []
    ]
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONSerialization.data(withJSONObject: fixture).write(to: profileFile(directory))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile(directory).path)
    let original = try Data(contentsOf: profileFile(directory))
    let vault = MemorySecretVault(); vault.values[id] = Data("m1-legacy-password".utf8)
    let store = ProfileStore(directory: directory, vault: vault)
    try store.load()
    try libraryExpect(store.migrationRequired && !store.loaded, "password-only legacy profiles require explicit migration")
    try libraryExpect(try Data(contentsOf: profileFile(directory)) == original, "loading a password-only legacy profile does not rewrite it")
    try vault.expectUnused()
    vault.beforeRemove = {
        let disk = try diskSnapshot(directory)
        try libraryExpect(disk.version == 3 && disk.nodeSecrets?[id.uuidString]?.password == "m1-legacy-password",
                          "password-only legacy deletion follows the plaintext commit")
    }
    try store.migrateLegacyCredentials()
    try libraryExpect(store.snapshot.legacyProfile == nil && store.snapshot.nodes.first?.id == id,
                      "password-only migration preserves identity and clears legacy metadata")
    try libraryExpect(store.snapshot.rules.isEmpty && store.snapshot.fallbackPolicy == "PROXY",
                      "password-only migration preserves the old non-ChatGPT-only routing choice")
    try libraryExpect(try store.readNode(store.snapshot.nodes[0]).password == "m1-legacy-password", "password-only migration restores the original credential")
    try libraryExpect(vault.values.isEmpty && vault.reads == [id] && vault.removals == [id] && vault.writes.isEmpty,
                      "password-only migration performs one legacy read and post-commit cleanup only")
}

private func runFullLegacyCleanupQueueMigrationTests(directory: URL) throws {
    let node = ProxyNode(name: "Full legacy queue", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "full-queue-fixture")
    let nodeReference = UUID(), subscriptionReference = UUID()
    var legacy = legacyFixture(node: node, nodeReference: nodeReference, subscriptionReference: subscriptionReference)
    legacy.pendingSecretIDs = (1...8_192).map {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", $0))!
    }
    let expected = Set(legacy.pendingSecretIDs).union([nodeReference, subscriptionReference])
    try libraryExpect(expected.count == 8_194, "fixture fills the v2 cleanup limit plus active credentials")
    try writeFixture(legacy, directory: directory)
    let vault = MemorySecretVault()
    vault.values[nodeReference] = try JSONEncoder().encode(node)
    vault.values[subscriptionReference] = try JSONEncoder().encode(SubscriptionSecret(url: "https://example.test/full-queue"))
    vault.failDeletes = true
    let originalCredentials = vault.values
    let store = ProfileStore(directory: directory, vault: vault)
    try store.load()
    try vault.expectUnused()
    try store.migrateLegacyCredentials()
    try libraryExpect(store.loaded && !store.migrationRequired && store.snapshot.version == 3,
                      "a full valid v2 cleanup queue can migrate to v3")
    try libraryExpect(Set(store.snapshot.pendingSecretIDs) == expected && store.snapshot.pendingSecretIDs.count == expected.count,
                      "migration preserves every previous and newly retired credential reference without duplication")
    try libraryExpect(Set(vault.removals) == expected && vault.values == originalCredentials,
                      "failed cleanup retains all source credentials and queues every attempted deletion")
    try libraryExpect(try store.readNode(store.snapshot.nodes[0]).password == node.password,
                      "full-queue migration preserves the plaintext node credential")
    let reloaded = ProfileStore(directory: directory, vault: vault)
    let attempts = vault.removals.count
    try reloaded.load()
    try libraryExpect(reloaded.loaded && reloaded.snapshot.version == 3 && Set(reloaded.snapshot.pendingSecretIDs) == expected,
                      "the expanded v3 cleanup queue remains valid and complete after reload")
    try libraryExpect(vault.removals.count == attempts, "reloading the expanded queue does not retry Keychain deletion")
}

private func runInvalidPlaintextTests(directory: URL) throws {
    let node = ProxyNode(name: "Invalid missing secret", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "fixture")
    var snapshot = LibrarySnapshot()
    snapshot.nodes = [NodeMetadata(node: node, secretID: UUID())]
    try writeFixture(snapshot, directory: directory)
    let original = try Data(contentsOf: profileFile(directory))
    let trap = MemorySecretVault(); trap.rejectAllAccess = true
    let store = ProfileStore(directory: directory, vault: trap)
    try libraryRejects("v3 missing plaintext node credentials") { try store.load() }
    try libraryExpect(!store.loaded, "corrupt plaintext profile is not considered loaded")
    try libraryExpect(try Data(contentsOf: profileFile(directory)) == original, "corrupt plaintext input is preserved")
    try trap.expectUnused()
}

/// Pure temporary filesystem and mock vault/fetcher checks: no real Keychain, sockets or Helper.
@MainActor func runLibraryTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClairRoute-library-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runPlaintextPersistenceTests(directory: directory.appendingPathComponent("plaintext"))
    try await runSubscriptionPersistenceTests(directory: directory.appendingPathComponent("subscriptions"))
    try await runSubscriptionChurnTests(directory: directory.appendingPathComponent("churn"))
    try await runSubscriptionAliasTests(directory: directory.appendingPathComponent("aliases"))
    try await runSubscriptionDisableTests(directory: directory.appendingPathComponent("disable"))
    try await runDisabledLibraryValidationTests(directory: directory.appendingPathComponent("disabled-validation"))
    try runAtomicFailureTests(directory: directory.appendingPathComponent("atomic"))
    try runMigrationTests(directory: directory.appendingPathComponent("migration"))
    try runMigrationCleanupFailureTests(directory: directory.appendingPathComponent("cleanup"))
    try runPasswordOnlyMigrationTests(directory: directory.appendingPathComponent("password-only"))
    try runFullLegacyCleanupQueueMigrationTests(directory: directory.appendingPathComponent("full-cleanup-queue"))
    try runInvalidPlaintextTests(directory: directory.appendingPathComponent("invalid"))
    let info = SubscriptionUserInfo.parse("upload=123; download=456; total=1000; expire=1900000000")
    try libraryExpect(info?.upload == 123 && info?.download == 456 && info?.total == 1000 && info?.expire != nil, "subscription accounting and expiry header")
    try libraryExpect(SubscriptionUserInfo.parse("upload=-1; download=abc; total=18446744073709551616") == nil, "malformed and overflowing counters are ignored")
    try libraryRejects("HTTP subscription URL") { _ = try SubscriptionService.validatedURL("http://example.test") }
    try libraryRejects("embedded URL credentials") { _ = try SubscriptionService.validatedURL("https://user:pass@example.test") }
    print("Library: plaintext persistence, no-Keychain daily operations, mocked subscription updates, atomic failure, explicit legacy migration and cleanup tests passed")
}

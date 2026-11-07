import Foundation
import Security
import Darwin

struct NodeMetadata: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var server: String
    var port: Int
    var type: ProxyProtocol
    var cipher: String
    var sourceID: UUID?
    /// A local credential index, never the server's authentication UUID.
    var secretID: UUID

    init(node: ProxyNode, secretID: UUID) {
        id = node.id; name = node.name; server = node.server; port = node.port
        type = node.type; cipher = node.cipher; sourceID = node.sourceID; self.secretID = secretID
    }
}

struct SubscriptionMetadata: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var refreshInterval: TimeInterval
    var lastUpdated: Date?
    var userInfo: SubscriptionUserInfo?
    var enabled = true
    var secretID: UUID
}

struct SubscriptionSecret: Codable, Sendable {
    var url: String
    var payload: Data?
}

struct LegacyNodeMetadata: Codable, Sendable {
    var id: UUID
    var name: String
    var server: String
    var port: Int
    var cipher: String
}

struct LegacySavedProfile: Codable, Sendable {
    var node: LegacyNodeMetadata?
    var mode: OutboundMode = .rule
    var chatGPTOnly = true
    var pendingSecretIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey { case node, mode, chatGPTOnly, pendingSecretIDs }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = try c.decodeIfPresent(LegacyNodeMetadata.self, forKey: .node)
        mode = try c.decodeIfPresent(OutboundMode.self, forKey: .mode) ?? .rule
        chatGPTOnly = try c.decodeIfPresent(Bool.self, forKey: .chatGPTOnly) ?? true
        pendingSecretIDs = try c.decodeIfPresent([UUID].self, forKey: .pendingSecretIDs) ?? []
    }
}

struct LibrarySnapshot: Codable, Sendable {
    var version = 3
    var nodes: [NodeMetadata] = []
    var subscriptions: [SubscriptionMetadata] = []
    var rules: [RoutingRule] = RoutingRule.defaults
    /// Which default-rule additions this profile has already received (see RoutingRule.defaultsRevision).
    var defaultRulesRevision = RoutingRule.defaultsRevision
    var subscriptionRules: [RoutingRule] = []
    var fallbackPolicy = "DIRECT"
    var selectedNode: String?
    var advanced = AdvancedOptions()
    var autoSelect = AutoSelectSettings()
    var pendingSecretIDs: [UUID] = []
    // Optional only for decoding v2; v3 requires complete, typed plaintext dictionaries.
    var nodeSecrets: [String: ProxyNode]? = [:]
    var subscriptionSecrets: [String: SubscriptionSecret]? = [:]
    /// Only legacy Keychain cleanup references remain in pendingSecretIDs.
    /// A crash during migration preserves the complete old nonsecret metadata here.
    var legacyProfile: LegacySavedProfile?

    var activeSecretIDs: Set<UUID> {
        Set(nodes.map(\.secretID) + subscriptions.map(\.secretID) + [legacyProfile?.node?.id].compactMap { $0 })
    }

    private enum CodingKeys: String, CodingKey {
        case version, nodes, subscriptions, rules, defaultRulesRevision, subscriptionRules, fallbackPolicy, selectedNode
        case advanced, autoSelect, pendingSecretIDs, nodeSecrets, subscriptionSecrets, legacyProfile
    }
}

extension LibrarySnapshot {
    var hasDisabledSelection: Bool {
        guard let selectedNode, let sourceID = nodes.first(where: { $0.name == selectedNode })?.sourceID else { return false }
        return subscriptions.contains { $0.id == sourceID && !$0.enabled }
    }

    /// Disabled entries are still durable configuration and must remain valid when reenabled.
    func validate(nodes allNodes: [ProxyNode]) throws {
        let sourceIDs = Set(subscriptions.map(\.id))
        guard rules.allSatisfy({ $0.sourceID == nil }),
              subscriptionRules.allSatisfy({ $0.sourceID.map(sourceIDs.contains) ?? false }) else { throw StoreError.invalidRules }
        try ConfigurationBuilder.validate(RuntimeProfile(nodes: allNodes, rules: rules + subscriptionRules,
            fallbackPolicy: fallbackPolicy, selectedNode: selectedNode, advanced: advanced))
        try ConfigurationBuilder.validate(runtimeProfile(nodes: allNodes))
    }

    /// Build a transient configuration; never replace saved targets just because a source is disabled.
    func runtimeProfile(nodes allNodes: [ProxyNode], mode: OutboundMode = .rule) -> RuntimeProfile {
        let enabled = Set(subscriptions.filter(\.enabled).map(\.id))
        let disabled = Set(subscriptions.filter { !$0.enabled }.map(\.id))
        let unavailable = Set(allNodes.filter { $0.sourceID.map(disabled.contains) ?? false }.map(\.name))
            .union(disabled.map(ConfigurationBuilder.sourcePolicy))
        let activeNodes = allNodes.filter { $0.sourceID.map(enabled.contains) ?? true }
        let activeRules = (rules + subscriptionRules.filter { $0.sourceID.map(enabled.contains) ?? false }).map {
            var rule = $0
            if unavailable.contains(rule.policy) { rule.policy = "DIRECT" }
            return rule
        }
        return RuntimeProfile(nodes: activeNodes, mode: mode, rules: activeRules,
                              fallbackPolicy: unavailable.contains(fallbackPolicy) ? "DIRECT" : fallbackPolicy,
                              selectedNode: hasDisabledSelection ? nil : selectedNode, advanced: advanced,
                              autoSelect: autoSelect)
    }

    /// Missing keys fall back to defaults so that adding a field never makes an existing profile unreadable.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        version = try c.decode(Int.self, forKey: .version)
        nodes = try c.decodeIfPresent([NodeMetadata].self, forKey: .nodes) ?? []
        subscriptions = try c.decodeIfPresent([SubscriptionMetadata].self, forKey: .subscriptions) ?? []
        // Profiles saved before a default rule existed receive it once; a later deletion sticks.
        let revision = try c.decodeIfPresent(Int.self, forKey: .defaultRulesRevision) ?? 0
        if let saved = try c.decodeIfPresent([RoutingRule].self, forKey: .rules) {
            rules = RoutingRule.addingNewDefaults(to: saved, since: revision)
        } else { rules = RoutingRule.defaults }
        defaultRulesRevision = RoutingRule.defaultsRevision
        subscriptionRules = try c.decodeIfPresent([RoutingRule].self, forKey: .subscriptionRules) ?? []
        fallbackPolicy = try c.decodeIfPresent(String.self, forKey: .fallbackPolicy) ?? "DIRECT"
        selectedNode = try c.decodeIfPresent(String.self, forKey: .selectedNode)
        advanced = try c.decodeIfPresent(AdvancedOptions.self, forKey: .advanced) ?? AdvancedOptions()
        autoSelect = try c.decodeIfPresent(AutoSelectSettings.self, forKey: .autoSelect) ?? AutoSelectSettings()
        pendingSecretIDs = try c.decodeIfPresent([UUID].self, forKey: .pendingSecretIDs) ?? []
        nodeSecrets = try c.decodeIfPresent([String: ProxyNode].self, forKey: .nodeSecrets)
        subscriptionSecrets = try c.decodeIfPresent([String: SubscriptionSecret].self, forKey: .subscriptionSecrets)
        legacyProfile = try c.decodeIfPresent(LegacySavedProfile.self, forKey: .legacyProfile)
    }
}

enum StoreError: LocalizedError {
    case keychain(OSStatus), missingSecret, invalidData, notLoaded, unsafePath, missingNode
    case subscriptionNode, invalidRules, invalidInterval, duplicateName
    var errorDescription: String? {
        switch self {
        case .keychain(let code): "无法访问 Keychain（状态 \(code)）。"
        case .missingSecret: "缺少节点或订阅凭据；原有配置已保留。"
        case .invalidData: "本机资料格式不正确或超过大小限制；原文件已保留。"
        case .notLoaded: "资料库尚未成功载入，请先解决读取错误。"
        case .unsafePath: "资料目录或文件的类型、权限不安全，操作已停止。"
        case .missingNode: "找不到所选节点或订阅。"
        case .subscriptionNode: "订阅节点由订阅管理；请复制为手动节点后编辑。"
        case .invalidRules: "用户规则不能携带订阅来源，或存在重复标识。"
        case .invalidInterval: "刷新间隔应在 5 分钟到 30 天之间。"
        case .duplicateName: "节点名称已存在，请使用不同名称。"
        }
    }
}

/// Injection point used by offline tests. No test needs the real user's Keychain.
protocol SecretVault: AnyObject {
    func read(_ id: UUID) throws -> Data
    func write(_ data: Data, id: UUID) throws
    func remove(_ id: UUID) throws
}

final class KeychainSecretVault: SecretVault {
    // Preserve the M1 service name so old password-only items can migrate safely.
    private let service = AppConstants.appIdentifier + ".NodeSecrets"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    func read(_ id: UUID) throws -> Data {
        var q = query(id)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw StoreError.missingSecret }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data, data.count <= 4 * AppConstants.maximumMessageBytes else { throw StoreError.invalidData }
        return data
    }
    // Legacy migration is read/delete only. New credentials must never reach Keychain.
    func write(_ data: Data, id: UUID) throws { throw StoreError.invalidData }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}

/// Serial access only (AppLibraryModel is MainActor). All v3 credentials live in profile.json.
final class ProfileStore {
    static let maximumFileBytes = 32 * 1024 * 1024
    let directory: URL
    private let legacyVault: any SecretVault
    private var migrationCache: [UUID: Data] = [:]
    private(set) var snapshot = LibrarySnapshot()
    private(set) var loaded = false
    private(set) var migrationRequired = false
    private(set) var warning: String?

    init(directory: URL? = nil, vault: any SecretVault = KeychainSecretVault()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClairRoute", isDirectory: true)
        self.legacyVault = vault
    }

    func load() throws {
        loaded = false; migrationRequired = false; warning = nil
        migrationCache.removeAll()
        let url = directory.appendingPathComponent("profile.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            if isSymlink(url) || isSymlink(directory) { throw StoreError.unsafePath }
            snapshot = LibrarySnapshot(); loaded = true; return
        }
        try verifyFile(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= Self.maximumFileBytes else { throw StoreError.unsafePath }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        try handle.close()
        guard data.count <= Self.maximumFileBytes else { throw StoreError.invalidData }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoreError.invalidData }
        var decoded: LibrarySnapshot
        if object["version"] != nil {
            decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
            guard decoded.version == 2 || decoded.version == 3 else { throw StoreError.invalidData }
        } else {
            let legacy = try JSONDecoder().decode(LegacySavedProfile.self, from: data)
            decoded = LibrarySnapshot(); decoded.version = 2
            decoded.legacyProfile = legacy
            decoded.pendingSecretIDs = legacy.pendingSecretIDs
            if !legacy.chatGPTOnly { decoded.rules = []; decoded.fallbackPolicy = "PROXY" }
        }
        try validate(decoded)
        snapshot = decoded
        migrationRequired = decoded.version == 2
        loaded = !migrationRequired
        // No startup migration, cleanup, or Keychain access. Migration requires an explicit action.
    }

    func readNode(_ metadata: NodeMetadata) throws -> ProxyNode {
        guard loaded else { throw StoreError.notLoaded }
        guard let node = snapshot.nodeSecrets?[metadata.secretID.uuidString] else { throw StoreError.missingSecret }
        guard NodeMetadata(node: node, secretID: metadata.secretID) == metadata else { throw StoreError.invalidData }
        return node
    }

    func readSubscription(_ metadata: SubscriptionMetadata) throws -> SubscriptionSecret {
        guard loaded else { throw StoreError.notLoaded }
        guard let value = snapshot.subscriptionSecrets?[metadata.secretID.uuidString] else { throw StoreError.missingSecret }
        return value
    }

    /// Stage all changes in memory; one atomic replacement commits metadata and plaintext together.
    func commit(_ next: LibrarySnapshot, additions: [UUID: Data] = [:], removing: Set<UUID> = []) throws {
        guard loaded, !migrationRequired, next.version == 3 else { throw StoreError.notLoaded }
        var committed = next
        let nodeIDs = Set(next.nodes.map(\.secretID))
        let subscriptionIDs = Set(next.subscriptions.map(\.secretID))
        guard Set(additions.keys).isSubset(of: nodeIDs.union(subscriptionIDs)),
              removing.isDisjoint(with: nodeIDs.union(subscriptionIDs)) else { throw StoreError.invalidData }
        var nodes = snapshot.nodeSecrets ?? [:]
        var subscriptions = snapshot.subscriptionSecrets ?? [:]
        for (id, data) in additions {
            guard data.count <= 4 * AppConstants.maximumMessageBytes else { throw StoreError.invalidData }
            if nodeIDs.contains(id) { nodes[id.uuidString] = try JSONDecoder().decode(ProxyNode.self, from: data) }
            else { subscriptions[id.uuidString] = try JSONDecoder().decode(SubscriptionSecret.self, from: data) }
        }
        let nodeKeys = Set(nodeIDs.map(\.uuidString)), subscriptionKeys = Set(subscriptionIDs.map(\.uuidString))
        committed.nodeSecrets = nodes.filter { nodeKeys.contains($0.key) }
        committed.subscriptionSecrets = subscriptions.filter { subscriptionKeys.contains($0.key) }
        // This queue belongs only to the explicit legacy migration/cleanup flow.
        committed.pendingSecretIDs = snapshot.pendingSecretIDs
        let durable = try save(committed)
        snapshot = committed
        warning = durable ? nil : "配置已保存，存储同步尚未确认。"
    }

    /// Read every old item before committing anything. Cancellation leaves the original file intact.
    func migrateLegacyCredentials() throws {
        guard migrationRequired, snapshot.version == 2 else { return }
        var next = snapshot
        next.nodeSecrets = [:]; next.subscriptionSecrets = [:]
        let legacyIDs = snapshot.activeSecretIDs.union(snapshot.pendingSecretIDs)
        for metadata in snapshot.nodes {
            let node = try JSONDecoder().decode(ProxyNode.self, from: readLegacy(metadata.secretID))
            guard NodeMetadata(node: node, secretID: metadata.secretID) == metadata else { throw StoreError.invalidData }
            next.nodeSecrets?[metadata.secretID.uuidString] = node
        }
        for metadata in snapshot.subscriptions {
            next.subscriptionSecrets?[metadata.secretID.uuidString] = try JSONDecoder().decode(SubscriptionSecret.self, from: readLegacy(metadata.secretID))
        }
        if let legacy = snapshot.legacyProfile, let old = legacy.node {
            guard snapshot.nodes.isEmpty, snapshot.subscriptions.isEmpty,
                  let password = String(data: try readLegacy(old.id), encoding: .utf8) else { throw StoreError.invalidData }
            let node = ProxyNode(id: old.id, name: old.name, server: old.server, port: old.port,
                                 cipher: old.cipher, password: password)
            let metadata = NodeMetadata(node: node, secretID: old.id)
            next.nodes = [metadata]; next.nodeSecrets?[old.id.uuidString] = node
        }
        next.version = 3; next.legacyProfile = nil
        next.pendingSecretIDs = legacyIDs.sorted { $0.uuidString < $1.uuidString }
        let durable = try save(next)
        snapshot = next; loaded = true; migrationRequired = false
        migrationCache.removeAll()
        if durable { cleanupPending() }
        else { warning = "配置已迁移，存储同步尚未确认；旧钥匙串数据暂时保留。" }
    }

    /// Called only by explicit migration or the user's old-Keychain cleanup action.
    func cleanupPending() {
        warning = nil
        guard loaded, !migrationRequired, !snapshot.pendingSecretIDs.isEmpty else { return }
        guard (try? save(snapshot)) == true else {
            warning = "配置尚未完成存储同步；旧钥匙串清理已推迟。"
            return
        }
        var next = snapshot
        next.pendingSecretIDs = snapshot.pendingSecretIDs.filter { id in
            do { try legacyVault.remove(id); return false } catch { return true }
        }
        do {
            let durable = try save(next); snapshot = next
            if !durable { warning = "旧钥匙串清理记录已保存，存储同步尚未确认。" }
        } catch { warning = "旧钥匙串清理记录尚未保存，可手动重试。"; return }
        if !next.pendingSecretIDs.isEmpty { warning = "部分旧钥匙串条目尚未删除，可手动清理。" }
    }

    private func readLegacy(_ id: UUID) throws -> Data {
        if let data = migrationCache[id] { return data }
        let data = try legacyVault.read(id)
        guard data.count <= 4 * AppConstants.maximumMessageBytes,
              migrationCache.values.reduce(0, { $0 + $1.count }) <= Self.maximumFileBytes - data.count else { throw StoreError.invalidData }
        migrationCache[id] = data
        return data
    }

    private func validate(_ value: LibrarySnapshot) throws {
        guard value.nodes.count <= 2_000, value.subscriptions.count <= 64,
              value.pendingSecretIDs.count <= (value.version == 2 ? 8_192 : 10_257),
              Set(value.nodes.map(\.id)).count == value.nodes.count,
              Set(value.subscriptions.map(\.id)).count == value.subscriptions.count,
              Set(value.nodes.map(\.secretID) + value.subscriptions.map(\.secretID)).count == value.nodes.count + value.subscriptions.count else {
            throw StoreError.invalidData
        }
        guard value.version == 3 else {
            guard value.version == 2 else { throw StoreError.invalidData }
            return
        }
        guard value.legacyProfile == nil, let nodes = value.nodeSecrets, let subscriptions = value.subscriptionSecrets,
              Set(nodes.keys) == Set(value.nodes.map { $0.secretID.uuidString }),
              Set(subscriptions.keys) == Set(value.subscriptions.map { $0.secretID.uuidString }) else { throw StoreError.invalidData }
        let subscriptionIDs = Set(value.subscriptions.map(\.id))
        for metadata in value.nodes {
            guard let node = nodes[metadata.secretID.uuidString], NodeMetadata(node: node, secretID: metadata.secretID) == metadata,
                  node.sourceID.map(subscriptionIDs.contains) ?? true else { throw StoreError.invalidData }
            try ConfigurationBuilder.validateNode(node)
        }
        for metadata in value.subscriptions {
            guard let record = subscriptions[metadata.secretID.uuidString],
                  metadata.refreshInterval.isFinite, (300...2_592_000).contains(metadata.refreshInterval),
                  record.payload.map({ $0.count <= SubscriptionService.maximumBytes }) ?? true else { throw StoreError.invalidData }
            _ = try SubscriptionService.validatedURL(record.url)
        }
        try value.validate(nodes: value.nodes.compactMap { nodes[$0.secretID.uuidString] })
    }

    @discardableResult private func save(_ value: LibrarySnapshot) throws -> Bool {
        guard value.version == 3 else { throw StoreError.invalidData }
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumFileBytes else { throw StoreError.invalidData }
        guard !isSymlink(directory) else { throw StoreError.unsafePath }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try verifyDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw StoreError.unsafePath }
        defer { close(directoryFD) }
        let destination = directory.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: destination.path) { try verifyFile(destination) }
        else if isSymlink(destination) { throw StoreError.unsafePath }
        let temporary = directory.appendingPathComponent(".profile-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        // Rename is the commit point. A later directory-sync failure is a durability warning.
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
        return fsync(directoryFD) == 0
    }

    private func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }
    private func verifyDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw StoreError.unsafePath }
    }
    private func verifyFile(_ url: URL) throws {
        try verifyDirectory()
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StoreError.unsafePath }
    }
}

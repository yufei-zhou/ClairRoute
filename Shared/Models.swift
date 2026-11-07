import Foundation

public enum AppConstants {
    public static let appIdentifier = "local.nano.ClairRoute"
    public static let helperIdentifier = "local.nano.ClairRoute.Helper"
    public static let machServiceName = "local.nano.ClairRoute.Helper"
    public static let mixedPort = 17_890
    public static let dnsPort = 53
    public static let supportDirectory = "/Library/Application Support/ClairRoute"
    public static let coreVersion = "1.19.31"
    public static let tunInterfaceName = "utun197"
    public static let chatGPTBundlePath = "/Applications/ChatGPT.app"
    public static let maximumMessageBytes = 1_048_576
}

public enum OutboundMode: String, Codable, CaseIterable, Sendable {
    case rule, global, direct
}

public enum ProxyProtocol: String, Codable, CaseIterable, Sendable {
    case shadowsocks = "ss", vmess, vless
}

public enum RuleKind: String, Codable, CaseIterable, Sendable {
    case processPathRegex = "PROCESS-PATH-REGEX"
    case processName = "PROCESS-NAME"
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case geosite = "GEOSITE"
}

public struct RoutingRule: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: RuleKind
    public var value: String
    public var policy: String
    public var enabled: Bool
    public var sourceID: UUID?

    public init(id: UUID = UUID(), kind: RuleKind, value: String, policy: String = "PROXY",
                enabled: Bool = true, sourceID: UUID? = nil) {
        self.id = id; self.kind = kind; self.value = value
        self.policy = policy; self.enabled = enabled; self.sourceID = sourceID
    }

    public static var chatGPT: Self {
        Self(id: UUID(uuidString: "021A6EC6-1773-4CF3-B36C-413D91A4053C")!,
             kind: .processPathRegex,
             value: "^" + NSRegularExpression.escapedPattern(for: AppConstants.chatGPTBundlePath).replacingOccurrences(of: "\\/", with: "/") + "/")
    }
}

/// Only these options may be edited in advanced YAML. Privileged paths and listeners
/// remain fixed in ConfigurationBuilder and cannot be overridden by a subscription.
public struct AdvancedOptions: Codable, Sendable, Equatable {
    public var dnsServers: [String] = ["https://1.1.1.1/dns-query", "https://9.9.9.9/dns-query"]
    public var proxyDNS: [String] = ["https://1.1.1.1/dns-query", "https://9.9.9.9/dns-query"]
    public var fakeIPFilter: [String] = ["*.lan", "*.local", "localhost"]
    public var ipv6 = true
    public var tunStack = "mixed"
    public var mtu = 1_500
    public var logLevel = "warning"
    public var tcpConcurrent = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case dnsServers, proxyDNS, fakeIPFilter, ipv6, tunStack, mtu, logLevel, tcpConcurrent
    }
}

public extension AdvancedOptions {
    /// Missing keys keep their defaults so that new options never break stored profiles.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? dnsServers
        proxyDNS = try c.decodeIfPresent([String].self, forKey: .proxyDNS) ?? proxyDNS
        fakeIPFilter = try c.decodeIfPresent([String].self, forKey: .fakeIPFilter) ?? fakeIPFilter
        ipv6 = try c.decodeIfPresent(Bool.self, forKey: .ipv6) ?? ipv6
        tunStack = try c.decodeIfPresent(String.self, forKey: .tunStack) ?? tunStack
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? mtu
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? logLevel
        tcpConcurrent = try c.decodeIfPresent(Bool.self, forKey: .tcpConcurrent) ?? tcpConcurrent
    }
}

/// Runtime-only credentials. Persist node metadata separately and passwords in Keychain.
public struct ProxyNode: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var server: String
    public var port: Int
    public var cipher: String
    public var password: String
    public var type: ProxyProtocol
    public var uuid: String
    public var flow: String
    public var servername: String
    public var clientFingerprint: String
    public var publicKey: String
    public var shortID: String
    public var tls: Bool
    public var network: String
    public var alterID: Int
    public var security: String
    public var wsPath: String
    public var wsHost: String
    public var serviceName: String
    public var plugin: String
    public var pluginOptions: [String: String]
    public var sourceID: UUID?

    public init(id: UUID = UUID(), name: String, server: String, port: Int,
                cipher: String = "", password: String = "", type: ProxyProtocol = .shadowsocks,
                uuid: String = "", flow: String = "", servername: String = "",
                clientFingerprint: String = "", publicKey: String = "", shortID: String = "",
                tls: Bool = false, network: String = "tcp", alterID: Int = 0,
                security: String = "auto", wsPath: String = "", wsHost: String = "",
                serviceName: String = "", plugin: String = "", pluginOptions: [String: String] = [:],
                sourceID: UUID? = nil) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.cipher = cipher
        self.password = password
        self.type = type; self.uuid = uuid; self.flow = flow; self.servername = servername
        self.clientFingerprint = clientFingerprint; self.publicKey = publicKey; self.shortID = shortID
        self.tls = tls; self.network = network; self.alterID = alterID; self.security = security
        self.wsPath = wsPath; self.wsHost = wsHost; self.serviceName = serviceName
        self.plugin = plugin; self.pluginOptions = pluginOptions; self.sourceID = sourceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, server, port, cipher, password, type, uuid, flow, servername
        case clientFingerprint, publicKey, shortID, tls, network, alterID, security
        case wsPath, wsHost, serviceName, plugin, pluginOptions, sourceID
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  server: try c.decode(String.self, forKey: .server), port: try c.decode(Int.self, forKey: .port),
                  cipher: try c.decodeIfPresent(String.self, forKey: .cipher) ?? "",
                  password: try c.decodeIfPresent(String.self, forKey: .password) ?? "",
                  type: try c.decodeIfPresent(ProxyProtocol.self, forKey: .type) ?? .shadowsocks,
                  uuid: try c.decodeIfPresent(String.self, forKey: .uuid) ?? "",
                  flow: try c.decodeIfPresent(String.self, forKey: .flow) ?? "",
                  servername: try c.decodeIfPresent(String.self, forKey: .servername) ?? "",
                  clientFingerprint: try c.decodeIfPresent(String.self, forKey: .clientFingerprint) ?? "",
                  publicKey: try c.decodeIfPresent(String.self, forKey: .publicKey) ?? "",
                  shortID: try c.decodeIfPresent(String.self, forKey: .shortID) ?? "",
                  tls: try c.decodeIfPresent(Bool.self, forKey: .tls) ?? false,
                  network: try c.decodeIfPresent(String.self, forKey: .network) ?? "tcp",
                  alterID: try c.decodeIfPresent(Int.self, forKey: .alterID) ?? 0,
                  security: try c.decodeIfPresent(String.self, forKey: .security) ?? "auto",
                  wsPath: try c.decodeIfPresent(String.self, forKey: .wsPath) ?? "",
                  wsHost: try c.decodeIfPresent(String.self, forKey: .wsHost) ?? "",
                  serviceName: try c.decodeIfPresent(String.self, forKey: .serviceName) ?? "",
                  plugin: try c.decodeIfPresent(String.self, forKey: .plugin) ?? "",
                  pluginOptions: try c.decodeIfPresent([String: String].self, forKey: .pluginOptions) ?? [:],
                  sourceID: try c.decodeIfPresent(UUID.self, forKey: .sourceID))
    }
}

/// Automatic selection prefers low latency with 50 ms switching tolerance among the
/// first `candidateCount` nodes of the selected node's subscription (or local nodes).
public struct AutoSelectSettings: Codable, Sendable, Equatable {
    public static let candidateRange = 2...20
    public static let intervals = [60, 120, 300, 600]
    public var enabled: Bool
    public var candidateCount: Int
    /// Seconds between latency checks; the core may also check after connection failures.
    public var interval: Int

    public init(enabled: Bool = false, candidateCount: Int = 5, interval: Int = 120) {
        self.enabled = enabled; self.candidateCount = candidateCount; self.interval = interval
    }
    private enum CodingKeys: String, CodingKey { case enabled, candidateCount, interval }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  candidateCount: try c.decodeIfPresent(Int.self, forKey: .candidateCount) ?? 5,
                  interval: try c.decodeIfPresent(Int.self, forKey: .interval) ?? 120)
    }
}

public struct RuntimeProfile: Codable, Sendable {
    public var nodes: [ProxyNode]
    public var mode: OutboundMode
    public var chatGPTOnly: Bool
    public var rules: [RoutingRule]
    public var fallbackPolicy: String
    public var selectedNode: String?
    public var advanced: AdvancedOptions
    public var autoSelect: AutoSelectSettings

    public init(nodes: [ProxyNode] = [], mode: OutboundMode = .rule,
                chatGPTOnly: Bool = true, rules: [RoutingRule]? = nil,
                fallbackPolicy: String = "DIRECT", selectedNode: String? = nil,
                advanced: AdvancedOptions = .init(), autoSelect: AutoSelectSettings = .init()) {
        self.nodes = nodes
        self.mode = mode
        self.chatGPTOnly = chatGPTOnly
        self.rules = rules ?? (chatGPTOnly ? [.chatGPT] : [])
        self.fallbackPolicy = !chatGPTOnly && rules == nil ? "PROXY" : fallbackPolicy
        self.selectedNode = selectedNode; self.advanced = advanced; self.autoSelect = autoSelect
    }
    private enum CodingKeys: String, CodingKey {
        case nodes, mode, chatGPTOnly, rules, fallbackPolicy, selectedNode, advanced, autoSelect
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(nodes: try c.decode([ProxyNode].self, forKey: .nodes),
                  mode: try c.decodeIfPresent(OutboundMode.self, forKey: .mode) ?? .rule,
                  chatGPTOnly: try c.decodeIfPresent(Bool.self, forKey: .chatGPTOnly) ?? true,
                  rules: try c.decodeIfPresent([RoutingRule].self, forKey: .rules),
                  fallbackPolicy: try c.decodeIfPresent(String.self, forKey: .fallbackPolicy) ?? "DIRECT",
                  selectedNode: try c.decodeIfPresent(String.self, forKey: .selectedNode),
                  advanced: try c.decodeIfPresent(AdvancedOptions.self, forKey: .advanced) ?? .init(),
                  autoSelect: try c.decodeIfPresent(AutoSelectSettings.self, forKey: .autoSelect) ?? .init())
    }
}

public struct ApplyRequest: Codable, Sendable {
    public var sessionID: UUID
    public var generation: UInt64
    public var tunEnabled: Bool
    public var systemProxyEnabled: Bool
    public var profile: RuntimeProfile
    public var trialMode: Bool?

    public init(sessionID: UUID, generation: UInt64, tunEnabled: Bool,
                systemProxyEnabled: Bool, profile: RuntimeProfile, trialMode: Bool? = nil) {
        self.sessionID = sessionID
        self.generation = generation
        self.tunEnabled = tunEnabled
        self.systemProxyEnabled = systemProxyEnabled
        self.profile = profile
        self.trialMode = trialMode
    }
}

public struct HeartbeatRequest: Codable, Sendable {
    public var sessionID: UUID
    public init(sessionID: UUID) { self.sessionID = sessionID }
}

public enum ServicePhase: String, Codable, Sendable {
    case idle, preparing, starting, active, reconfiguring, restoring, needsAttention
}

public struct ServiceStatus: Codable, Sendable {
    public var phase: ServicePhase
    public var tunEnabled: Bool
    public var systemProxyEnabled: Bool
    public var coreRunning: Bool
    public var corePID: Int32?
    public var generation: UInt64
    public var message: String
    public var coreVersion: String?
    public var recoveryPending: Bool

    public init(phase: ServicePhase, tunEnabled: Bool = false,
                systemProxyEnabled: Bool = false, coreRunning: Bool = false,
                corePID: Int32? = nil, generation: UInt64 = 0,
                message: String = "", coreVersion: String? = nil,
                recoveryPending: Bool = false) {
        self.phase = phase
        self.tunEnabled = tunEnabled
        self.systemProxyEnabled = systemProxyEnabled
        self.coreRunning = coreRunning
        self.corePID = corePID
        self.generation = generation
        self.message = message
        self.coreVersion = coreVersion
        self.recoveryPending = recoveryPending
    }

    public static var idle: Self {
        Self(phase: .idle, message: "尚未启用代理。")
    }
}

public struct ServiceReply: Codable, Sendable {
    public var status: ServiceStatus?
    public var error: String?

    public init(status: ServiceStatus? = nil, error: String? = nil) {
        self.status = status
        self.error = error
    }

    public static func success(_ status: ServiceStatus) -> Self { Self(status: status) }
    public static func failure(_ error: String, status: ServiceStatus? = nil) -> Self {
        Self(status: status, error: error)
    }
}

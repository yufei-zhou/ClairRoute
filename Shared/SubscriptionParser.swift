import Foundation

/// A normalized, bounded import. No provider URL or executable settings survive parsing.
public struct ParsedSubscription: Sendable {
    public var nodes: [ProxyNode]
    public var rules: [RoutingRule]
    public var warnings: [String]
    /// Expected normalization of a provider template; these are not import failures.
    public var notes: [String]
    public init(nodes: [ProxyNode], rules: [RoutingRule] = [], warnings: [String] = [], notes: [String] = []) {
        self.nodes = nodes; self.rules = rules; self.warnings = warnings; self.notes = notes
    }
}

/// Safe diagnostics for an unchanged import allowlist. Only field identifiers are
/// retained; the rejected mapping and all of its values are intentionally absent.
public struct SubscriptionFieldDiagnostic: LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public let scope: String
    public let unsupportedKeys: [String]
    /// Includes invalid identifier names and safe names beyond the display limit.
    public let omittedKeyCount: Int

    fileprivate init(scope: String, keys: Set<String>) {
        self.scope = scope // Every caller supplies a fixed label and optional enum/index.
        unsupportedKeys = Array(keys.filter(Self.displayableIdentifier).sorted().prefix(8))
        omittedKeyCount = keys.count - unsupportedKeys.count
    }

    public var errorDescription: String? {
        let listed = unsupportedKeys.isEmpty ? "" : "：" + unsupportedKeys.joined(separator: ", ")
        let omitted = omittedKeyCount == 0 ? "" : "（另有 \(omittedKeyCount) 个字段名因字符或数量限制未显示）"
        return scope + "含不支持的字段" + listed + omitted + "。未导入，请检查订阅格式。"
    }
    /// Prevent default Error interpolation from reflecting unsanitized stored data.
    public var description: String { errorDescription! }

    private static func displayableIdentifier(_ key: String) -> Bool {
        let bytes = key.utf8
        guard (1...48).contains(bytes.count), let first = bytes.first,
              (65...90).contains(first) || (97...122).contains(first),
              UUID(uuidString: key) == nil else { return false }
        // Reject the whole key rather than printing a possibly sensitive prefix.
        // No URLs, escapes, control characters, whitespace or display directives.
        return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

public enum SubscriptionParser {
    public static let maximumBytes = 4 * 1_024 * 1_024

    public static func parse(_ data: Data, sourceID: UUID? = nil) throws -> ParsedSubscription {
        guard !data.isEmpty, data.count <= maximumBytes, var text = String(data: data, encoding: .utf8) else { throw fail("订阅必须是有界 UTF-8 文本。") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if looksLikeURIList(text) { return try parseList(text, sourceID: sourceID) }
        let compact = text.filter { !$0.isWhitespace }
        if isBase64(compact), let decoded = decode64(compact), let list = String(data: decoded, encoding: .utf8), looksLikeURIList(list.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return try parseList(list, sourceID: sourceID)
        }
        guard let root = try SafeYAML.parse(text).map else { throw fail("YAML 订阅必须是映射对象。") }
        // This import schema intentionally excludes rule-providers, scripts, paths,
        // controller listeners and tun settings. They never reach the root core.
        let ignored: Set<String> = ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "allow-lan", "bind-address", "mode", "log-level", "ipv6", "dns", "hosts", "profile", "tun", "sniffer", "find-process-mode", "tcp-concurrent", "unified-delay", "keep-alive-interval", "keep-alive-idle", "global-client-fingerprint", "authentication", "skip-auth-prefixes", "lan-allowed-ips", "lan-disallowed-ips"]
        try keys(root, allowed: ignored.union(["proxies", "rules", "proxy-groups", "proxy-providers"]), scope: "订阅顶层")
        var values = [YAMLValue]()
        if let value = root["proxies"] {
            guard let list = value.array else { throw fail("proxies 必须是列表。") }; values = list
        }
        var inlineProviderNames = Set<String>()
        if let value = root["proxy-providers"] {
            guard let providers = value.map, providers.count <= 128 else { throw fail("订阅 inline provider 数量无效。") }
            for (name, value) in providers.sorted(by: { $0.key < $1.key }) {
                guard !name.isEmpty, name.utf8.count <= 128, let provider = value.map else { throw fail("订阅 inline provider 格式无效。") }
                try keys(provider, allowed: ["type", "payload"], scope: "订阅 inline provider")
                guard try string(provider, "type", required: true) == "inline", let payload = provider["payload"]?.array else { throw fail("订阅 provider 仅允许 inline payload，不允许 URL、path 或远程刷新。") }
                values.append(contentsOf: payload); inlineProviderNames.insert(name)
                guard values.count <= ConfigurationBuilder.maximumNodes else { throw fail("订阅节点总数超过 512。") }
            }
        }
        guard !values.isEmpty, values.count <= ConfigurationBuilder.maximumNodes else { throw fail("YAML 订阅需要 1–512 个节点。") }
        var nodes = [ProxyNode]()
        for (index, value) in values.enumerated() { nodes.append(try parseNode(value, sourceID: sourceID, index: index)) }
        var declaredGroups = Set<String>()
        if let value = root["proxy-groups"] {
            guard let groups = value.array, groups.count <= 256 else { throw fail("订阅代理组数量无效。") }
            for group in groups {
                guard let map = group.map else { throw fail("代理组必须是映射。") }
                try keys(map, allowed: ["name", "type", "proxies", "use", "url", "interval", "tolerance", "lazy", "timeout", "max-failed-times", "disable-udp", "hidden", "icon"], scope: "订阅代理组")
                let name = try string(map, "name", required: true)
                guard !name.isEmpty, name.utf8.count <= 128, declaredGroups.insert(name).inserted,
                      ["select", "url-test", "fallback", "load-balance"].contains(try string(map, "type", required: true)) else { throw fail("订阅代理组名称或类型无效。") }
                guard map["proxies"] != nil || map["use"] != nil else { throw fail("订阅代理组必须列出 proxies 或 inline use。") }
                if let value = map["proxies"] {
                    guard let children = value.array, children.count <= 1_024, children.allSatisfy({ $0.text != nil }) else { throw fail("订阅代理组必须列出有界 proxies。") }
                }
                if let value = map["use"] {
                    guard let providers = value.array, providers.count <= 128, providers.allSatisfy({ $0.text.map(inlineProviderNames.contains) == true }) else { throw fail("代理组 use 只能引用已导入的 inline provider。") }
                }
            }
        }
        var warnings: [String] = []
        var notes = declaredGroups.isEmpty ? [] : ["订阅代理组已合并为此订阅的节点组；自动测速 URL 和组行为不会导入。"]
        if !Set(root.keys).isDisjoint(with: ignored) { notes.append("订阅模板中的端口、DNS、TUN、模式等运行选项已忽略；使用 ClairRoute 本地设置。") }
        var rules = [RoutingRule]()
        if let value = root["rules"] {
            guard let entries = value.array, entries.count <= ConfigurationBuilder.maximumRules else { throw fail("订阅规则数量无效。") }
            let nodeNames = Set(nodes.map(\.name)); let sourcePolicy = sourceID.map(ConfigurationBuilder.sourcePolicy) ?? "PROXY"
            for entry in entries {
                guard let raw = entry.text, raw.utf8.count <= 2_048 else { throw fail("订阅规则必须是有界字符串。") }
                let fields = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if fields.first == "MATCH" {
                    guard fields.count == 2 else { throw fail("MATCH 规则格式无效。") }
                    if !notes.contains("订阅 MATCH 已忽略；兜底策略由用户设置。") { notes.append("订阅 MATCH 已忽略；兜底策略由用户设置。") }
                    continue
                }
                if fields.count >= 3, RuleKind(rawValue: fields[0]) == nil {
                    // Provider templates almost always carry GEOIP / IP-CIDR / RULE-SET rules.
                    // Skip them visibly instead of rejecting the whole subscription.
                    let note = "订阅中不支持的规则类型（如 GEOIP、IP-CIDR、RULE-SET）已跳过；未命中的流量按你设置的兜底策略处理。"
                    if !warnings.contains(note) { warnings.append(note) }
                    continue
                }
                guard fields.count == 3, let kind = RuleKind(rawValue: fields[0]) else { throw fail("订阅规则格式无效；支持进程、域名和 GEOSITE。") }
                var policy = fields[2]
                if !["DIRECT", "REJECT"].contains(policy), declaredGroups.contains(policy) || policy == "PROXY" { policy = sourcePolicy }
                guard ["DIRECT", "REJECT", sourcePolicy].contains(policy) || nodeNames.contains(policy) else { throw fail("订阅规则引用了未定义策略。") }
                let rule = RoutingRule(kind: kind, value: fields[1], policy: policy, sourceID: sourceID)
                try ConfigurationBuilder.validateRule(rule); rules.append(rule)
            }
        }
        return try checked(ParsedSubscription(nodes: nodes, rules: rules, warnings: warnings, notes: notes))
    }

    public static func parseURI(_ uri: String, sourceID: UUID? = nil) throws -> ProxyNode {
        guard uri.utf8.count <= 16_384, !uri.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw fail("节点 URI 长度或字符无效。") }
        let node: ProxyNode
        if uri.hasPrefix("ss://") { node = try parseSS(uri, sourceID: sourceID) }
        else if uri.hasPrefix("vmess://") { node = try parseVMess(uri, sourceID: sourceID) }
        else if uri.hasPrefix("vless://") { node = try parseVLESS(uri, sourceID: sourceID) }
        else { throw fail("仅支持 ss://、vmess:// 和 vless://。") }
        try ConfigurationBuilder.validateNode(node)
        return node
    }

    private static func parseList(_ text: String, sourceID: UUID?) throws -> ParsedSubscription {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= ConfigurationBuilder.maximumNodes else { throw fail("URI 列表需要 1–512 个节点。") }
        // Lists often mix in trojan://, hysteria2:// etc. Skip other schemes with a warning,
        // but still reject malformed links of the supported schemes.
        let supported = lines.filter(startsURI)
        guard !supported.isEmpty else { throw fail("仅支持 ss://、vmess:// 和 vless://。") }
        let warnings = supported.count == lines.count ? [] : ["已跳过 \(lines.count - supported.count) 个不支持的链接（仅支持 ss://、vmess://、vless://）。"]
        return try checked(ParsedSubscription(nodes: supported.map { try parseURI($0, sourceID: sourceID) }, warnings: warnings))
    }
    private static func checked(_ parsed: ParsedSubscription) throws -> ParsedSubscription {
        let profile = RuntimeProfile(nodes: parsed.nodes, rules: parsed.rules)
        try ConfigurationBuilder.validate(profile)
        return parsed
    }
    private static func startsURI(_ value: String) -> Bool { ["ss://", "vmess://", "vless://"].contains(where: value.hasPrefix) }
    /// True when the first line is any `scheme://` link (supported or not), i.e. not YAML.
    private static func looksLikeURIList(_ value: String) -> Bool {
        let first = value.prefix { !$0.isNewline }
        guard let separator = first.range(of: "://") else { return false }
        let scheme = first[..<separator.lowerBound]
        return !scheme.isEmpty && scheme.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 }
    }

    private static func parseSS(_ uri: String, sourceID: UUID?) throws -> ProxyNode {
        guard let components = URLComponents(string: uri) else { throw fail("Shadowsocks URI 无效。") }
        var host: String; var port: Int; var cipher: String; var password: String
        if let rawUser = components.percentEncodedUser, let rawHost = components.host, let rawPort = components.port {
            host = unbracket(rawHost); port = rawPort
            if let rawPassword = components.percentEncodedPassword {
                guard let decodedUser = rawUser.removingPercentEncoding, let decodedPassword = rawPassword.removingPercentEncoding else { throw fail("Shadowsocks URI 百分号转义无效。") }
                cipher = decodedUser; password = decodedPassword
            } else {
                guard let decodedUser = rawUser.removingPercentEncoding, let bytes = decode64(decodedUser), let auth = String(data: bytes, encoding: .utf8), let colon = auth.firstIndex(of: ":") else { throw fail("Shadowsocks URI 用户信息不是有效 Base64。") }
                cipher = String(auth[..<colon]); password = String(auth[auth.index(after: colon)...])
            }
            guard components.path.isEmpty || components.path == "/" else { throw fail("Shadowsocks URI 不支持额外路径。") }
        } else {
            // Legacy form is Base64(method:password@host:port), not a hostname URL.
            let body = String(uri.dropFirst(5).prefix { $0 != "#" && $0 != "?" })
            guard let bytes = decode64(body), let decoded = String(data: bytes, encoding: .utf8), let at = decoded.lastIndex(of: "@"), let colon = decoded[..<at].firstIndex(of: ":"), let endpoint = URLComponents(string: "ss://" + decoded[decoded.index(after: at)...]), let rawHost = endpoint.host, let rawPort = endpoint.port else { throw fail("旧式 Shadowsocks URI 无效。") }
            cipher = String(decoded[..<colon]); password = String(decoded[decoded.index(after: colon)..<at]); host = unbracket(rawHost); port = rawPort
        }
        let query = try queryItems(components, allowed: ["plugin"])
        var plugin = ""; var pluginOptions: [String: String] = [:]
        if let value = query["plugin"] {
            let fields = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, ["obfs-local", "obfs", "v2ray-plugin"].contains(name) else { throw fail("SS URI plugin 只支持内核内置 obfs/v2ray-plugin。") }
            plugin = name == "obfs-local" ? "obfs" : name
            for field in fields.dropFirst() {
                guard !field.isEmpty else { throw fail("SS plugin 字段为空。") }
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let key = pair[0] == "obfs" ? "mode" : pair[0] == "obfs-host" ? "host" : pair[0]
                guard pluginOptions[key] == nil else { throw fail("SS plugin 字段重复。") }
                pluginOptions[key] = pair.count == 2 ? pair[1] : "true"
            }
        }
        return ProxyNode(name: components.fragment?.isEmpty == false ? components.fragment! : "SS " + host, server: host, port: port, cipher: cipher, password: password, plugin: plugin, pluginOptions: pluginOptions, sourceID: sourceID)
    }

    private static func parseVMess(_ uri: String, sourceID: UUID?) throws -> ProxyNode {
        let body = String(uri.dropFirst(8))
        guard let bytes = decode64(body), let map = try SafeYAML.parse(bytes).map else { throw fail("VMess URI 必须包含 Base64 JSON。") }
        try keys(map, allowed: ["v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path", "tls", "sni", "fp", "alpn"], scope: "VMess URI")
        // v2rayN always writes "alpn"; only the empty (default) value is meaningful to us.
        guard try string(map, "alpn").isEmpty else { throw fail("VMess URI 暂不支持自定义 alpn。") }
        let version = try string(map, "v", fallback: "2")
        guard ["", "2"].contains(version), ["", "none"].contains(try string(map, "type", fallback: "none")) else { throw fail("VMess URI 版本或伪装类型不受支持。") }
        let tls = try string(map, "tls")
        guard ["", "none", "tls"].contains(tls) else { throw fail("VMess TLS 类型无效。") }
        let server = try string(map, "add", required: true); let network = try string(map, "net", fallback: "tcp")
        let path = try string(map, "path")
        let host = try string(map, "host")
        guard network != "tcp" || (path.isEmpty && host.isEmpty), network != "grpc" || host.isEmpty else { throw fail("VMess URI 传输字段不匹配，不能忽略 TCP/gRPC 伪装参数。") }
        let label = try string(map, "ps")
        return ProxyNode(name: label.isEmpty ? "VMess " + server : label, server: server, port: try integer(map, "port", required: true), type: .vmess,
            uuid: try string(map, "id", required: true), servername: try string(map, "sni"), clientFingerprint: try string(map, "fp"), tls: tls == "tls", network: network,
            alterID: try integer(map, "aid"), security: try string(map, "scy", fallback: "auto"), wsPath: network == "ws" ? path : "", wsHost: network == "ws" ? host : "", serviceName: network == "grpc" ? path : "", sourceID: sourceID)
    }

    private static func parseVLESS(_ uri: String, sourceID: UUID?) throws -> ProxyNode {
        guard let components = URLComponents(string: uri), let uuid = components.user, components.password == nil, let rawHost = components.host, let port = components.port, components.path.isEmpty || components.path == "/" else { throw fail("VLESS URI 地址、UUID 或端口无效。") }
        let query = try queryItems(components, allowed: ["encryption", "security", "type", "flow", "sni", "fp", "pbk", "sid", "path", "host", "serviceName", "headerType", "allowInsecure", "alpn"])
        // Common share-link parameters are accepted only at their default values, so nothing is silently dropped.
        guard (query["headerType"] ?? "none") == "none",
              ["0", "false"].contains(query["allowInsecure"] ?? "0"),
              (query["alpn"] ?? "").isEmpty else { throw fail("VLESS URI 的 headerType / allowInsecure / alpn 只支持默认值。") }
        guard query["encryption"] == nil || query["encryption"] == "none" else { throw fail("VLESS encryption 仅支持 none。") }
        let security = query["security"] ?? "none"
        guard ["none", "tls", "reality"].contains(security) else { throw fail("VLESS security 无效。") }
        guard security == "reality" ? !(query["pbk"] ?? "").isEmpty : query["pbk"] == nil && query["sid"] == nil else { throw fail("Reality 公钥与 security 不一致。") }
        let server = unbracket(rawHost)
        return ProxyNode(name: components.fragment?.isEmpty == false ? components.fragment! : "VLESS " + server, server: server, port: port, type: .vless, uuid: uuid,
            flow: query["flow"] ?? "", servername: query["sni"] ?? "", clientFingerprint: query["fp"] ?? "", publicKey: query["pbk"] ?? "", shortID: query["sid"] ?? "", tls: security != "none", network: query["type"] ?? "tcp", wsPath: query["path"] ?? "", wsHost: query["host"] ?? "", serviceName: query["serviceName"] ?? "", sourceID: sourceID)
    }

    private static func parseNode(_ value: YAMLValue, sourceID: UUID?, index: Int) throws -> ProxyNode {
        guard let map = value.map else { throw fail("节点必须是 YAML 映射。") }
        guard let type = ProxyProtocol(rawValue: try string(map, "type", required: true)) else { throw fail("节点协议仅支持 ss、vmess 和 vless。") }
        let common: Set<String> = ["name", "type", "server", "port", "udp"]
        let transport: Set<String> = ["uuid", "servername", "client-fingerprint", "tls", "network", "ws-opts", "grpc-opts", "skip-cert-verify"]
        let specific: Set<String>
        switch type {
        case .shadowsocks: specific = ["cipher", "password", "plugin", "plugin-opts"]
        case .vmess: specific = transport.union(["cipher", "alterId"])
        case .vless: specific = transport.union(["flow", "reality-opts", "encryption"])
        }
        try keys(map, allowed: common.union(specific), scope: "节点 #\(index + 1)（\(type.rawValue)）")
        if type == .vless, let value = map["encryption"] {
            // v1.19.31 transport/vless/encryption/factory.go NewClient returns
            // nil,nil for both "" and "none", exactly like the omitted default.
            // Other modes require model support; never silently discard them.
            guard case .string(let encryption) = value, ["", "none"].contains(encryption) else {
                throw fail("VLESS encryption 仅支持空字符串或 none；其他值不会被忽略，字段值已隐藏。")
            }
        }
        if map["udp"] != nil, try !boolean(map, "udp") { throw fail("当前节点模型要求启用 UDP。") }
        if try boolean(map, "skip-cert-verify") { throw fail("不能关闭节点证书验证。") }
        var node = ProxyNode(name: try string(map, "name", required: true), server: try string(map, "server", required: true), port: try integer(map, "port", required: true), cipher: type == .shadowsocks ? try string(map, "cipher", required: true) : "", password: try string(map, "password"), type: type,
            uuid: try string(map, "uuid"), flow: try string(map, "flow"), servername: try string(map, "servername"), clientFingerprint: try string(map, "client-fingerprint"), tls: try boolean(map, "tls"), network: try string(map, "network", fallback: "tcp"), alterID: try integer(map, "alterId"), security: type == .vmess ? try string(map, "cipher", fallback: "auto") : "auto", plugin: try string(map, "plugin"), sourceID: sourceID)
        if let value = map["reality-opts"] {
            guard let options = value.map, type == .vless else { throw fail("Reality 仅适用于 VLESS。") }
            try keys(options, allowed: ["public-key", "short-id"], scope: "Reality")
            node.publicKey = try string(options, "public-key", required: true); node.shortID = try string(options, "short-id")
        }
        if let value = map["ws-opts"] {
            guard let options = value.map, node.network == "ws" else { throw fail("ws-opts 要求 WebSocket 传输。") }
            try keys(options, allowed: ["path", "headers"], scope: "WebSocket")
            node.wsPath = try string(options, "path", fallback: "/")
            if let value = options["headers"] {
                guard let headers = value.map else { throw fail("WebSocket headers 无效。") }
                try keys(headers, allowed: ["Host"], scope: "WebSocket headers")
                node.wsHost = try string(headers, "Host")
            }
        }
        if let value = map["grpc-opts"] {
            guard let options = value.map, node.network == "grpc" else { throw fail("grpc-opts 要求 gRPC 传输。") }
            try keys(options, allowed: ["grpc-service-name"], scope: "gRPC")
            node.serviceName = try string(options, "grpc-service-name")
        }
        if let value = map["plugin-opts"] {
            guard let options = value.map else { throw fail("plugin-opts 必须是映射。") }
            for (key, value) in options {
                if let string = value.text { node.pluginOptions[key] = string }
                else if let bool = value.boolean { node.pluginOptions[key] = bool ? "true" : "false" }
                else { throw fail("plugin-opts 值必须是字符串或布尔值。") }
            }
        }
        try ConfigurationBuilder.validateNode(node)
        return node
    }

    private static func queryItems(_ components: URLComponents, allowed: Set<String>) throws -> [String: String] {
        let items = components.queryItems ?? []
        let unsupported = Set(items.map(\.name)).subtracting(allowed)
        if !unsupported.isEmpty { throw SubscriptionFieldDiagnostic(scope: "URI 参数", keys: unsupported) }
        var result: [String: String] = [:]
        for item in items {
            guard result[item.name] == nil, let value = item.value else { throw fail("URI 含重复或缺值的参数。") }
            result[item.name] = value
        }
        return result
    }
    private static func keys(_ map: [String: YAMLValue], allowed: Set<String>, scope: String) throws {
        let unsupported = Set(map.keys).subtracting(allowed)
        guard unsupported.isEmpty else { throw SubscriptionFieldDiagnostic(scope: scope, keys: unsupported) }
    }
    private static func string(_ map: [String: YAMLValue], _ key: String, fallback: String = "", required: Bool = false) throws -> String {
        guard let value = map[key] else { if required { throw fail("缺少必填节点字段。") }; return fallback }
        guard let result = value.text else { throw fail("节点字段应为字符串。") }; return result
    }
    private static func integer(_ map: [String: YAMLValue], _ key: String, required: Bool = false) throws -> Int {
        guard let value = map[key] else { if required { throw fail("缺少必填数字字段。") }; return 0 }
        guard let text = value.text, let number = Int(text) else { throw fail("节点数字字段无效。") }; return number
    }
    private static func boolean(_ map: [String: YAMLValue], _ key: String) throws -> Bool {
        guard let value = map[key] else { return false }
        guard let result = value.boolean else { throw fail("节点字段应为 true/false。") }; return result
    }
    private static func unbracket(_ host: String) -> String { host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host }
    private static func isBase64(_ value: String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 45, 95, 61].contains($0) } }
    private static func decode64(_ value: String) -> Data? { isBase64(value) ? ConfigurationBuilder.decodeBase64URL(value) : nil }
    private static func fail(_ message: String) -> ConfigurationError { .invalid(message) }
}

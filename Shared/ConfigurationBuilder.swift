import Darwin
import Foundation

public enum ConfigurationError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

public enum ConfigurationBuilder {
    public static let supportedCiphers = ["aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"]
    public static let maximumNodes = 512
    public static let maximumRules = 2_048
    public static func sourcePolicy(_ id: UUID) -> String { "SUB_" + id.uuidString.lowercased() }
    public static func orderedRules(_ rules: [RoutingRule]) -> [RoutingRule] {
        rules.filter { $0.sourceID == nil } + rules.filter { $0.sourceID != nil }
    }
    public static func policies(for nodes: [ProxyNode]) -> [String] {
        ["PROXY", "DIRECT", "REJECT"] + Array(Set(nodes.compactMap(\.sourceID))).map(sourcePolicy).sorted() + nodes.map(\.name)
    }

    public static func validate(_ profile: RuntimeProfile) throws {
        guard profile.nodes.count <= maximumNodes, profile.rules.count <= maximumRules else { throw invalid("节点或规则数量超过安全限制。") }
        var ids = Set<UUID>(); var names = Set<String>()
        for node in profile.nodes {
            try validateNode(node)
            guard ids.insert(node.id).inserted,
                  names.insert(node.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw invalid("节点名称或标识重复。") }
        }
        let allowed = Set(policies(for: profile.nodes))
        guard allowed.contains(profile.fallbackPolicy) else { throw invalid("兜底策略不存在。") }
        if let selected = profile.selectedNode, !profile.nodes.contains(where: { $0.name == selected }) { throw invalid("选中的节点不存在。") }
        var ruleIDs = Set<UUID>()
        for rule in profile.rules {
            guard ruleIDs.insert(rule.id).inserted else { throw invalid("规则标识重复。") }
            try validateRule(rule)
            guard allowed.contains(rule.policy) else { throw invalid("规则引用了不存在的策略。") }
        }
        try validateAdvanced(profile.advanced)
    }

    public static func validateNode(_ node: ProxyNode) throws {
        let reserved = Set(["PROXY", "DIRECT", "REJECT", "GLOBAL", "COMPATIBLE", "REJECT-DROP", "PASS"])
        guard bounded(node.name, 128), !node.name.isEmpty, !node.name.contains(","),
              node.name == node.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !reserved.contains(node.name.uppercased()), !node.name.uppercased().hasPrefix("SUB_"),
              !node.name.uppercased().hasPrefix("NODE_"),
              !node.name.hasPrefix("provider-") else { throw invalid("节点名称无效或与保留策略名称冲突。") }
        guard validServer(node.server), (1...65_535).contains(node.port) else { throw invalid("服务器必须是有效 IP/ASCII 域名，端口为 1–65535。") }
        guard ["tcp", "ws", "grpc"].contains(node.network),
              [node.uuid, node.flow, node.servername, node.clientFingerprint, node.publicKey, node.shortID,
               node.security, node.wsPath, node.wsHost, node.serviceName, node.plugin].allSatisfy({ bounded($0, 2_048) }) else { throw invalid("传输协议或节点字段无效。") }
        if !node.servername.isEmpty, !validServer(node.servername) { throw invalid("TLS Server Name 无效。") }
        if !node.wsHost.isEmpty, !validServer(node.wsHost) { throw invalid("WebSocket Host 必须是域名或 IP。") }
        if !node.wsPath.isEmpty, !node.wsPath.hasPrefix("/") { throw invalid("WebSocket 路径必须以 / 开头。") }
        guard node.network == "ws" || (node.wsPath.isEmpty && node.wsHost.isEmpty),
              node.network == "grpc" || node.serviceName.isEmpty else { throw invalid("传输字段与所选 network 不一致。") }
        let fingerprints = ["", "chrome", "firefox", "safari", "ios", "android", "edge", "random", "randomized", "360", "qq"]
        guard fingerprints.contains(node.clientFingerprint) else { throw invalid("不支持所选 TLS 客户端指纹。") }
        switch node.type {
        case .shadowsocks:
            guard supportedCiphers.contains(node.cipher), bounded(node.password, 4_096), !node.password.isEmpty else { throw invalid("Shadowsocks cipher 或密码无效。") }
            if node.cipher.hasPrefix("2022-") {
                let size = node.cipher == "2022-blake3-aes-128-gcm" ? 16 : 32
                let keys = node.password.split(separator: ":", omittingEmptySubsequences: false)
                guard keys.count <= 8, keys.allSatisfy({ key in
                    guard let data = Data(base64Encoded: String(key)) else { return false }
                    return data.count == size && data.base64EncodedString() == key
                }) else { throw invalid("SS2022 的每段密钥必须是规范 Base64，解码后为 \(size) 字节。") }
            }
            guard node.uuid.isEmpty, node.flow.isEmpty, node.publicKey.isEmpty, node.shortID.isEmpty,
                  node.servername.isEmpty, node.clientFingerprint.isEmpty, !node.tls, node.alterID == 0,
                  node.security == "auto", node.network == "tcp" else { throw invalid("Shadowsocks 不接受 VMess/VLESS 传输字段。") }
            try validatePlugin(node)
        case .vmess, .vless:
            guard UUID(uuidString: node.uuid) != nil, node.uuid.count == 36,
                  node.password.isEmpty, node.cipher.isEmpty, node.plugin.isEmpty, node.pluginOptions.isEmpty else { throw invalid("VMess/VLESS UUID 无效，或混入了 Shadowsocks 密码/plugin。") }
            if node.type == .vmess {
                guard (0...65_535).contains(node.alterID),
                      ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305"].contains(node.security),
                      node.flow.isEmpty, node.publicKey.isEmpty, node.shortID.isEmpty else { throw invalid("VMess 加密或 alterId 字段无效。") }
            } else {
                guard ["", "xtls-rprx-vision"].contains(node.flow), node.alterID == 0, node.security == "auto" else { throw invalid("VLESS flow 或无关 VMess 字段无效。") }
                if !node.flow.isEmpty, (!node.tls || node.network != "tcp") { throw invalid("XTLS Vision 要求 TLS 和 TCP。") }
                if !node.publicKey.isEmpty {
                    guard node.tls, !node.servername.isEmpty, !node.clientFingerprint.isEmpty,
                          node.publicKey.count == 43, decodeBase64URL(node.publicKey)?.count == 32,
                          node.shortID.count <= 16, node.shortID.count.isMultiple(of: 2),
                          node.shortID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw invalid("Reality 要求 TLS、SNI、指纹、32 字节 Base64URL 公钥和最多 8 字节十六进制 short-id。") }
                } else if !node.shortID.isEmpty { throw invalid("Reality short-id 缺少对应 public-key。") }
            }
        }
    }

    public static func validateRule(_ rule: RoutingRule) throws {
        guard !rule.value.isEmpty, bounded(rule.value, 1_024), !rule.value.contains(","),
              !rule.policy.isEmpty, bounded(rule.policy, 128), !rule.policy.contains(",") else { throw invalid("规则值或策略无效。") }
        switch rule.kind {
        case .processPathRegex:
            // GUI emits an anchored escaped bundle prefix. Reject general backtracking
            // patterns from subscriptions rather than exposing root to regex DoS.
            guard rule.value.hasPrefix("^/") || rule.value.hasPrefix("^\\/"), rule.value.hasSuffix("/") || rule.value.hasSuffix("$"),
                  literalPathRegex(rule.value), (try? NSRegularExpression(pattern: rule.value)) != nil else { throw invalid("进程路径规则只接受 ^ 开头的转义绝对路径前缀（结尾 /）或精确路径（结尾 $）。") }
        case .processName:
            guard !rule.value.contains("/"), !rule.value.contains("\\"), rule.value.utf8.count <= 256 else { throw invalid("进程名不能包含路径。") }
        case .domain, .domainSuffix:
            guard validServer(rule.value), !rule.value.contains(":"), rule.value.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else { throw invalid("域名规则值无效。") }
        case .domainKeyword: guard rule.value.utf8.count <= 253 else { throw invalid("域名关键词过长。") }
        case .geosite:
            guard rule.value.utf8.count <= 128, rule.value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 64, 33].contains($0) }) else { throw invalid("GEOSITE 名称无效。") }
        }
    }

    public static func validateAdvanced(_ options: AdvancedOptions) throws {
        guard ["mixed", "system", "gvisor"].contains(options.tunStack), (1_280...9_000).contains(options.mtu),
              ["silent", "error", "warning", "info"].contains(options.logLevel),
              (1...8).contains(options.dnsServers.count), (1...8).contains(options.proxyDNS.count),
              options.fakeIPFilter.count <= 128 else { throw invalid("高级选项超出安全支持范围。") }
        for entry in options.dnsServers + options.proxyDNS {
            if validServer(entry), entry.utf8.contains(where: { $0 == 46 || $0 == 58 }), !entry.contains("/") { continue }
            guard bounded(entry, 512), let url = URLComponents(string: entry),
                  ["https", "tls"].contains(url.scheme), let host = url.host, validServer(host),
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
                  url.port == nil || (1...65_535).contains(url.port!) else { throw invalid("DNS 上游仅允许 IP/域名、HTTPS 或 TLS，不能包含凭据、规则片段或本地路径。") }
        }
        guard options.fakeIPFilter.allSatisfy({ bounded($0, 253) && !$0.isEmpty && !$0.contains(",") && !$0.contains(":") && !$0.contains("/") }) else { throw invalid("fake-ip-filter 仅允许有界域名模式。") }
    }

    public static func makeConfiguration(profile: RuntimeProfile, tunEnabled: Bool, controllerPath: String) throws -> Data {
        try validate(profile)
        guard controllerPath.hasPrefix("/"), controllerPath.utf8.count < 104, bounded(controllerPath, 103),
              !(controllerPath as NSString).pathComponents.contains("..") else { throw invalid("内部控制器 socket 路径无效。") }
        let grouped = Dictionary(grouping: profile.nodes) { $0.sourceID.map { "provider-" + $0.uuidString.lowercased() } ?? "provider-local" }
        var providers: [String: Any] = [:]
        for key in grouped.keys.sorted() { providers[key] = ["type": "inline", "payload": grouped[key]!.map(nodeConfiguration)] }
        var groups: [[String: Any]] = profile.nodes.map { node in
            let provider = node.sourceID.map { "provider-" + $0.uuidString.lowercased() } ?? "provider-local"
            let internalName = "NODE_" + node.id.uuidString.lowercased()
            return ["name": node.name, "type": "select", "use": [provider], "filter": "^" + internalName + "$", "default-selected": internalName]
        }
        for id in Set(profile.nodes.compactMap(\.sourceID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            groups.append(["name": sourcePolicy(id), "type": "select", "use": ["provider-" + id.uuidString.lowercased()]])
        }
        let names = profile.nodes.isEmpty ? ["REJECT"] : profile.nodes.map(\.name)
        groups.append(["name": "PROXY", "type": "select", "proxies": names, "default-selected": profile.selectedNode ?? names[0]])
        groups.append(["name": "GLOBAL", "type": "select", "proxies": ["PROXY"], "default-selected": "PROXY"])
        let options = profile.advanced
        let rules = orderedRules(profile.rules).filter(\.enabled).map { "\($0.kind.rawValue),\($0.value),\($0.policy)" } + ["MATCH,\(profile.fallbackPolicy)"]
        let configuration: [String: Any] = [
            "mode": profile.mode.rawValue, "mixed-port": AppConstants.mixedPort,
            "bind-address": "127.0.0.1", "allow-lan": false, "ipv6": options.ipv6,
            "find-process-mode": "strict", "log-level": options.logLevel,
            "external-controller-unix": controllerPath,
            "profile": ["store-selected": false, "store-fake-ip": false],
            "geo-auto-update": false, "geodata-mode": true,
            "geox-url": ["geoip": "", "geosite": "", "mmdb": "", "asn": ""],
            "etag-support": false, "tcp-concurrent": options.tcpConcurrent,
            "tun": ["enable": tunEnabled, "device": AppConstants.tunInterfaceName, "stack": options.tunStack,
                    "mtu": options.mtu, "auto-route": true, "auto-detect-interface": true, "dns-hijack": ["any:53", "tcp://any:53"]],
            "dns": ["enable": tunEnabled, "listen": tunEnabled ? "127.0.0.1:\(AppConstants.dnsPort)" : "",
                    "ipv6": options.ipv6, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
                    "fake-ip-filter": options.fakeIPFilter, "default-nameserver": ["1.1.1.1", "9.9.9.9"],
                    "nameserver": options.dnsServers, "proxy-server-nameserver": options.proxyDNS],
            "proxies": [], "proxy-providers": providers, "proxy-groups": groups, "rules": rules
        ]
        let result = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys, .withoutEscapingSlashes])
        guard result.count <= AppConstants.maximumMessageBytes else { throw invalid("生成的配置超过 1 MiB 安全限制。") }
        return result
    }

    static func nodeConfiguration(_ node: ProxyNode) -> [String: Any] {
        var out: [String: Any] = ["name": "NODE_" + node.id.uuidString.lowercased(), "type": node.type.rawValue, "server": node.server, "port": node.port, "udp": true]
        if node.type == .shadowsocks {
            out["cipher"] = node.cipher; out["password"] = node.password
            if !node.plugin.isEmpty {
                out["plugin"] = node.plugin
                var opts: [String: Any] = node.pluginOptions
                if opts["mode"] == nil { opts["mode"] = node.plugin == "obfs" ? "tls" : "websocket" }
                for key in ["tls", "mux", "skip-cert-verify"] where opts[key] != nil { opts[key] = node.pluginOptions[key] == "true" }
                out["plugin-opts"] = opts
            }
        } else {
            out["uuid"] = node.uuid; out["tls"] = node.tls; out["network"] = node.network
            if node.type == .vmess { out["alterId"] = node.alterID; out["cipher"] = node.security }
            if !node.flow.isEmpty { out["flow"] = node.flow }
            if !node.servername.isEmpty { out["servername"] = node.servername }
            if !node.clientFingerprint.isEmpty { out["client-fingerprint"] = node.clientFingerprint }
            if !node.publicKey.isEmpty { out["reality-opts"] = ["public-key": node.publicKey, "short-id": node.shortID] }
            if node.network == "ws" {
                var opts: [String: Any] = ["path": node.wsPath.isEmpty ? "/" : node.wsPath]
                if !node.wsHost.isEmpty { opts["headers"] = ["Host": node.wsHost] }
                out["ws-opts"] = opts
            }
            if node.network == "grpc" { out["grpc-opts"] = ["grpc-service-name": node.serviceName] }
        }
        return out
    }

    private static func validatePlugin(_ node: ProxyNode) throws {
        guard ["", "obfs", "v2ray-plugin"].contains(node.plugin), node.pluginOptions.count <= 8 else { throw invalid("仅支持内核内置 obfs 和 v2ray-plugin；不允许插件路径或可执行文件。") }
        if node.plugin.isEmpty { guard node.pluginOptions.isEmpty else { throw invalid("plugin-opts 缺少 plugin。") }; return }
        let allowed = node.plugin == "obfs" ? Set(["mode", "host"]) : Set(["mode", "host", "path", "tls", "mux", "skip-cert-verify"])
        guard Set(node.pluginOptions.keys).isSubset(of: allowed), node.pluginOptions.values.allSatisfy({ bounded($0, 2_048) }) else { throw invalid("plugin-opts 包含不支持的字段。") }
        let mode = node.pluginOptions["mode"] ?? (node.plugin == "obfs" ? "tls" : "websocket")
        guard node.plugin == "obfs" ? ["http", "tls"].contains(mode) : mode == "websocket" else { throw invalid("plugin 模式无效。") }
        for key in ["tls", "mux", "skip-cert-verify"] {
            if let value = node.pluginOptions[key], !["true", "false"].contains(value) { throw invalid("plugin 布尔字段无效。") }
        }
        guard node.pluginOptions["skip-cert-verify"] != "true" else { throw invalid("不能关闭服务器证书验证。") }
    }
    private static func literalPathRegex(_ pattern: String) -> Bool {
        let chars = Array(pattern.dropFirst()); var escaped = false
        for (i, c) in chars.enumerated() {
            if escaped { guard ".[](){}*+?^$\\|/ -".contains(c) else { return false }; escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "$" && i == chars.count - 1 { continue }
            if ".[](){}*+?^$|".contains(c) { return false }
        }
        return !escaped
    }
    static func bounded(_ value: String, _ maximum: Int) -> Bool { value.utf8.count <= maximum && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    static func invalid(_ message: String) -> ConfigurationError { .invalid(message) }
    static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
    static func validServer(_ server: String) -> Bool {
        guard !server.isEmpty, server.utf8.count <= 253, server == server.trimmingCharacters(in: .whitespacesAndNewlines), server.utf8.allSatisfy({ $0 < 128 }) else { return false }
        var ipv4 = in_addr(); var ipv6 = in6_addr()
        if server.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 || server.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
        if server.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) { return false }
        let host = server.hasSuffix(".") ? String(server.dropLast()) : server
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

public extension AdvancedOptions {
    static let exampleYAML = """
    ipv6: true
    log-level: warning
    tcp-concurrent: false
    tun:
      stack: mixed
      mtu: 1500
    dns:
      nameserver: [https://1.1.1.1/dns-query, https://9.9.9.9/dns-query]
      proxy-server-nameserver: [https://1.1.1.1/dns-query, https://9.9.9.9/dns-query]
      fake-ip-filter: ['*.lan', '*.local', localhost]
    """
    static func parse(yaml: String) throws -> AdvancedOptions {
        guard let map = try SafeYAML.parse(yaml).map else { throw ConfigurationBuilder.invalid("高级 YAML 必须是映射。") }
        try allowed(map, ["ipv6", "log-level", "tcp-concurrent", "tun", "dns"])
        var value = AdvancedOptions()
        if let v = map["ipv6"] { guard let b = v.boolean else { throw invalid() }; value.ipv6 = b }
        if let v = map["tcp-concurrent"] { guard let b = v.boolean else { throw invalid() }; value.tcpConcurrent = b }
        if let v = map["log-level"] { guard let s = v.text else { throw invalid() }; value.logLevel = s }
        if let v = map["tun"] {
            guard let tun = v.map else { throw invalid() }; try allowed(tun, ["stack", "mtu"])
            if let v = tun["stack"] { guard let s = v.text else { throw invalid() }; value.tunStack = s }
            if let v = tun["mtu"] { guard let i = v.int else { throw invalid() }; value.mtu = i }
        }
        if let v = map["dns"] {
            guard let dns = v.map else { throw invalid() }; try allowed(dns, ["nameserver", "proxy-server-nameserver", "fake-ip-filter"])
            func strings(_ item: YAMLValue) throws -> [String] { guard let list = item.array, list.allSatisfy({ $0.text != nil }) else { throw invalid() }; return list.compactMap(\.text) }
            if let v = dns["nameserver"] { value.dnsServers = try strings(v) }
            if let v = dns["proxy-server-nameserver"] { value.proxyDNS = try strings(v) }
            if let v = dns["fake-ip-filter"] { value.fakeIPFilter = try strings(v) }
        }
        try ConfigurationBuilder.validateAdvanced(value); return value
    }
    var yamlString: String {
        let object: [String: Any] = ["ipv6": ipv6, "log-level": logLevel, "tcp-concurrent": tcpConcurrent,
            "tun": ["stack": tunStack, "mtu": mtu], "dns": ["nameserver": dnsServers, "proxy-server-nameserver": proxyDNS, "fake-ip-filter": fakeIPFilter]]
        return (try? String(data: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)) ?? Self.exampleYAML
    }
    private static func allowed(_ map: [String: YAMLValue], _ keys: Set<String>) throws {
        guard Set(map.keys).isSubset(of: keys) else { throw ConfigurationBuilder.invalid("高级 YAML 包含未授权字段；不允许更改控制器、路径、provider、执行命令或监听端口。") }
    }
    private static func invalid() -> ConfigurationError { .invalid("高级 YAML 字段类型无效。") }
}

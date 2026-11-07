import Foundation
import Darwin

struct OfflineFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func check(_ expression: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try expression() else { throw OfflineFailure(message) }
}
func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw OfflineFailure("Unexpected acceptance: " + message)
}
func b64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

@main struct OfflineTests {
    @MainActor static func main() async {
        do {
            try parserTests()
            try parserDiagnosticTests()
            try yamlTests()
            try compatibilityTests()
            try configurationTests()
            try recoveryTests()
            try await runLibraryTests()
            try await runAppModelTests()
            print("PASS — all offline tests; no core, Helper, Keychain, UI or network execution")
        } catch {
            print("FAIL — " + String(describing: error))
            exit(1)
        }
    }

    /// Real-world subscription shapes that must import without losing supported data.
    static func compatibilityTests() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let apostrophe = try SubscriptionParser.parse(Data("""
        proxies:
          - {name: Bob's HK, type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: p}
          - name: Joe's JP # comment
            type: ss
            server: example.test
            port: 8443
            cipher: aes-256-gcm
            password: q
        """.utf8))
        try check(apostrophe.nodes.map(\.name) == ["Bob's HK", "Joe's JP"], "apostrophes in plain YAML values are ordinary text")
        let rules = try SubscriptionParser.parse(Data("""
        proxies:
          - {name: A, type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: p}
        rules:
          - GEOIP,CN,DIRECT,no-resolve
          - IP-CIDR,10.0.0.0/8,DIRECT
          - DOMAIN-SUFFIX,example.com,A
          - MATCH,A
        """.utf8))
        try check(rules.rules.count == 1 && rules.rules[0].kind == .domainSuffix && !rules.warnings.isEmpty, "unsupported subscription rule types are skipped with a warning")
        let vless = "vless://" + uuid + "@example.test:443?security=tls&type=tcp&headerType=none&allowInsecure=0&alpn=&sni=example.test#V"
        let mixed = try SubscriptionParser.parse(Data((vless + "\ntrojan://secret@example.test:443#T\n").utf8))
        try check(mixed.nodes.count == 1 && mixed.warnings.count == 1, "unsupported schemes in a URI list are skipped with a warning")
        try check(try SubscriptionParser.parse(Data(b64("trojan://secret@example.test:443#T\n" + vless).utf8)).nodes.count == 1, "Base64 list starting with an unsupported scheme")
        try rejects("insecure VLESS share link") { _ = try SubscriptionParser.parseURI("vless://" + uuid + "@example.test:443?security=tls&allowInsecure=1") }
        try rejects("non-default VLESS headerType") { _ = try SubscriptionParser.parseURI("vless://" + uuid + "@example.test:443?headerType=http") }
        try rejects("list without any supported link") { _ = try SubscriptionParser.parse(Data("trojan://secret@example.test:443#T".utf8)) }
        let vmess = "vmess://" + b64("{\"v\":\"2\",\"ps\":\"M\",\"add\":\"example.test\",\"port\":\"443\",\"id\":\"" + uuid + "\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"tls\",\"alpn\":\"\"}")
        try check(try SubscriptionParser.parseURI(vmess).name == "M", "v2rayN VMess link with empty alpn")
        let options = try JSONDecoder().decode(AdvancedOptions.self, from: Data(#"{"ipv6":false}"#.utf8))
        try check(!options.ipv6 && options.mtu == 1_500 && options.tunStack == "mixed", "advanced options decode with missing keys")
    }

    static func parserTests() throws {
        let ss = try SubscriptionParser.parseURI("ss://" + b64("aes-256-gcm:p:a+ss") + "@example.test:443#Sample%20SS")
        try check(ss.name == "Sample SS" && ss.password == "p:a+ss" && ss.type == .shadowsocks, "SIP002 Base64 auth and escaped name")
        let legacy = try SubscriptionParser.parseURI("ss://" + b64("aes-128-gcm:pass@[2001:db8::1]:8388") + "#IPv6")
        try check(legacy.server == "2001:db8::1" && legacy.port == 8388, "legacy SS with IPv6")
        let plain = try SubscriptionParser.parseURI("ss://aes-256-gcm:p%3Ass%40%23@example.test:443#Plain")
        try check(plain.password == "p:ss@#", "SIP002 percent credentials")
        let key = Data(repeating: 7, count: 16).base64EncodedString()
        let modern = try SubscriptionParser.parseURI("ss://" + b64("2022-blake3-aes-128-gcm:" + key) + "@example.test:443#SS2022")
        try check(modern.password == key, "SS2022 length-checked key")
        try rejects("short SS2022 key") { _ = try SubscriptionParser.parseURI("ss://" + b64("2022-blake3-aes-128-gcm:YQ==") + "@example.test:443") }
        let obfs = try SubscriptionParser.parseURI("ss://" + b64("aes-256-gcm:test") + "@example.test:443/?plugin=obfs-local%3Bobfs%3Dtls%3Bobfs-host%3Dexample.test#Obfs")
        try check(obfs.plugin == "obfs" && obfs.pluginOptions["mode"] == "tls", "built-in obfs URI normalization")
        try rejects("external plugin executable") { _ = try SubscriptionParser.parseURI("ss://" + b64("aes-256-gcm:test") + "@example.test:443?plugin=%2Ftmp%2Fevil") }
        let vmessJSON = #"{"v":"2","ps":"VMess","add":"example.test","port":"443","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.example.test","path":"/socket","tls":"tls","sni":"example.test","fp":"chrome"}"#
        let vmess = try SubscriptionParser.parseURI("vmess://" + b64(vmessJSON))
        try check(vmess.type == .vmess && vmess.tls && vmess.network == "ws" && vmess.wsPath == "/socket", "VMess JSON + WebSocket")
        let realityKey = Data(repeating: 3, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let vlessURI = "vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@example.test:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.test&fp=chrome&pbk=" + realityKey + "&sid=0123#Reality"
        let vless = try SubscriptionParser.parseURI(vlessURI)
        try check(vless.type == .vless && vless.flow == "xtls-rprx-vision" && vless.publicKey == realityKey && vless.shortID == "0123", "VLESS Reality + Vision")
        try rejects("VLESS duplicate parameters") { _ = try SubscriptionParser.parseURI(vlessURI.replacingOccurrences(of: "&sid=0123", with: "&sid=0123&sid=4567")) }
        try rejects("VLESS invalid short id") { _ = try SubscriptionParser.parseURI(vlessURI.replacingOccurrences(of: "sid=0123", with: "sid=xyz")) }
        let list = try SubscriptionParser.parse(Data(b64("ss://" + b64("aes-256-gcm:test") + "@example.test:443#SS\n" + vlessURI).utf8))
        try check(list.nodes.count == 2, "whole-subscription Base64 URI list")
        let yaml = """
        proxies:
          - name: YAML SS
            type: ss
            server: example.test
            port: 443
            cipher: aes-256-gcm
            password: 'safe: a # password'
            udp: true
          - {name: YAML VMess, type: vmess, server: example.test, port: 443, uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee, cipher: auto, alterId: 0}
        proxy-groups:
          - name: Imported
            type: select
            proxies: [YAML SS, YAML VMess]
        rules:
          - DOMAIN-SUFFIX,example.test,Imported
          - MATCH,DIRECT
        """
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let parsed = try SubscriptionParser.parse(Data(yaml.utf8), sourceID: sourceID)
        try check(parsed.nodes.count == 2 && parsed.nodes.allSatisfy { $0.sourceID == sourceID }, "YAML source identity")
        try check(parsed.rules.count == 1 && parsed.rules[0].policy == ConfigurationBuilder.sourcePolicy(sourceID), "import group normalized and MATCH controlled by user")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/full-clash.yaml")
        let fullTemplate = try SubscriptionParser.parse(Data(contentsOf: fixture), sourceID: sourceID)
        try check(fullTemplate.nodes.count == 2 && fullTemplate.notes.contains(where: { $0.contains("运行选项已忽略") }), "full Clash template safely extracts direct and inline nodes")
        try check(parsed.warnings.isEmpty && parsed.notes.count == 2, "expected group and MATCH normalization does not create persistent warnings")
        let regenerated = try ConfigurationBuilder.makeConfiguration(profile: RuntimeProfile(nodes: fullTemplate.nodes, rules: fullTemplate.rules), tunEnabled: false, controllerPath: "/var/run/clairroute/controller.sock")
        let templateOutput = try JSONSerialization.jsonObject(with: regenerated) as! [String: Any]
        try check(templateOutput["allow-lan"] as? Bool == false && templateOutput["mode"] as? String == "rule" && templateOutput["mixed-port"] as? Int == 17890, "subscription runtime options never reach generated configuration")
        try rejects("malicious rule-providers") { _ = try SubscriptionParser.parse(Data((yaml + "\nrule-providers:\n  bad: {type: file, path: /etc/passwd}\n").utf8)) }
        try rejects("malicious proxy-provider payload") { _ = try SubscriptionParser.parse(Data("proxy-providers: {bad: {type: http, url: https://example.test, path: /etc/evil}}".utf8)) }
        try rejects("dangerous per-node dialer") { _ = try SubscriptionParser.parse(Data(yaml.replacingOccurrences(of: "udp: true", with: "dialer-proxy: /tmp/evil").utf8)) }
        try rejects("unsupported protocol") { _ = try SubscriptionParser.parse(Data(yaml.replacingOccurrences(of: "type: ss", with: "type: socks5").utf8)) }
        print("Parser: SS, SS2022, VMess, VLESS Reality, Base64, YAML and malicious input tests passed")
    }

    static func parserDiagnosticTests() throws {
        let secret = "test-marker-never-echo-field-value"
        let credentialUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let sourceURL = "https://subscription.invalid/path?secret=never-echo-url"
        let baseNode: [String: Any] = ["name": secret, "type": "vless", "server": "example.test", "port": 443, "uuid": credentialUUID]
        func encode(_ node: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["proxies": [node]]) }
        func diagnostic(_ body: () throws -> Void) throws -> SubscriptionFieldDiagnostic {
            do { try body() }
            catch let error as SubscriptionFieldDiagnostic { return error }
            catch { throw OfflineFailure("Expected typed unsupported-field diagnostic") }
            throw OfflineFailure("Unsupported fields were accepted")
        }
        var node = baseNode
        node["tfo"] = secret; node["alpn"] = [sourceURL]; node["packet-encoding"] = credentialUUID
        let rejection = try diagnostic { _ = try SubscriptionParser.parse(encode(node)) }
        try check(rejection.scope == "节点 #1（vless）" && rejection.unsupportedKeys == ["alpn", "packet-encoding", "tfo"], "typed unsupported keys have safe protocol/index context and stable order")
        try check(rejection.omittedKeyCount == 0, "ordinary unsupported field names are visible")
        let descriptions = rejection.localizedDescription + String(describing: rejection)
        try check(!descriptions.contains(secret) && !descriptions.contains(credentialUUID) && !descriptions.contains(sourceURL), "diagnostics never contain node names, credential values or subscription URLs")

        var strange = baseNode
        let unsafeKeys = [sourceURL, "field\ncontrol", "field\u{202E}direction", "--display-directive", String(repeating: "a", count: 80), credentialUUID]
        for key in unsafeKeys { strange[key] = secret }
        strange["x-unknown"] = secret
        let redacted = try diagnostic { _ = try SubscriptionParser.parse(encode(strange)) }
        try check(redacted.unsupportedKeys == ["x-unknown"] && redacted.omittedKeyCount == unsafeKeys.count, "unsafe identifiers are hidden entirely, not truncated")
        try check(unsafeKeys.allSatisfy { !redacted.localizedDescription.contains($0) }, "unsafe field names cannot inject control text or a URL")
        var many = baseNode
        for index in 0..<40 { many["field-" + String(format: "%02d", index)] = secret }
        let bounded = try diagnostic { _ = try SubscriptionParser.parse(encode(many)) }
        try check(bounded.unsupportedKeys.count == 8 && bounded.omittedKeyCount == 32 && bounded.localizedDescription.utf8.count < 1_024, "diagnostic key count and message length are bounded")

        let root = try diagnostic {
            _ = try SubscriptionParser.parse(JSONSerialization.data(withJSONObject: ["rule-providers": ["bad": ["url": sourceURL, "password": secret]]]))
        }
        try check(root.unsupportedKeys == ["rule-providers"] && !root.localizedDescription.contains(sourceURL), "root dangerous-field diagnostic remains redacted")
        let query = try diagnostic {
            _ = try SubscriptionParser.parseURI("vless://" + credentialUUID + "@example.test:443?spx=" + secret)
        }
        try check(query.scope == "URI 参数" && query.unsupportedKeys == ["spx"] && !query.localizedDescription.contains(secret), "URI unsupported parameter reports its name only")

        // Public fake Reality fields reproduce a common provider schema, without
        // reading or persisting a real subscription response or credential.
        var reality = baseNode
        reality["tls"] = true; reality["network"] = "tcp"; reality["flow"] = "xtls-rprx-vision"
        reality["servername"] = "example.test"; reality["client-fingerprint"] = "chrome"
        reality["reality-opts"] = ["public-key": Data(repeating: 3, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""), "short-id": "0123"]
        let omitted = try SubscriptionParser.parse(encode(reality)).nodes[0]
        for value in ["", "none"] {
            reality["encryption"] = value
            let imported = try SubscriptionParser.parse(encode(reality)).nodes[0]
            let profile = RuntimeProfile(nodes: [imported])
            let generated = try ConfigurationBuilder.makeConfiguration(profile: profile, tunEnabled: false, controllerPath: "/var/run/clairroute-test.sock")
            try check(imported.type == omitted.type && imported.uuid == omitted.uuid && imported.flow == omitted.flow && imported.publicKey == omitted.publicKey && imported.shortID == omitted.shortID, "VLESS empty/none encryption preserves Reality and Vision")
            try check(!String(decoding: generated, as: UTF8.self).contains("\"encryption\""), "proven equivalent no-encryption defaults normalize to omitted core field")
        }
        for value: Any in ["mlkem768x25519plus.native.1rtt.test", "auto", "None", " ", 0, false, NSNull(), ["value": secret]] {
            reality["encryption"] = value
            try rejects("non-default or non-string VLESS encryption") { _ = try SubscriptionParser.parse(encode(reality)) }
        }
        print("Parser diagnostics: bounded key names only, secret redaction and VLESS empty/none encryption compatibility passed")
    }

    static func yamlTests() throws {
        let nested = try SafeYAML.parse("""
        proxies:
        - name: first
          nested: {boolean: true, array: [one, two]}
        rules:
        - DOMAIN,example.test,PROXY
        """)
        try check(nested.map?["proxies"]?.array?.count == 1, "indentless YAML sequence")
        try check(nested.map?["rules"]?.array?.first?.text == "DOMAIN,example.test,PROXY", "commas preserved in plain rule")
        try check(try SafeYAML.parse(#"{"number": 443, "false": false, "null": null}"#).map?["number"]?.int == 443, "JSON is YAML subset")
        try check(try SafeYAML.parse("short-id: 0123").map?["short-id"]?.text == "0123", "leading zeroes in credentials are preserved")
        let scalarCases: [(String, String)] = [
            ("ab''cd", "ab''cd"),
            (#"ab""cd"#, #"ab""cd"#),
            ("Bob 'HK", "Bob 'HK"),
            (#"Bob "HK"#, #"Bob "HK"#),
            ("ab:'cd", "ab:'cd"),
            (#"ab-"cd"#, #"ab-"cd"#),
            ("'ab''cd # [credential] }'", "ab'cd # [credential] }"),
            (#""ab\"cd # [credential] }""#, #"ab"cd # [credential] }"#)
        ]
        for (source, expected) in scalarCases {
            let block = try SafeYAML.parse("password: \(source) # discarded\nnext: intact")
            try check(block.map?["password"]?.text == expected && block.map?["next"]?.text == "intact", "block scalar quote boundaries preserve credentials and strip comments")
            let flow = try SafeYAML.parse("node: {password: \(source), next: intact} # discarded")
            try check(flow.map?["node"]?.map?["password"]?.text == expected && flow.map?["node"]?.map?["next"]?.text == "intact", "flow scalar quote boundaries preserve credentials and closing delimiters")
            let sequence = try SafeYAML.parse("values:\n  - \(source) # discarded\n  - intact")
            try check(sequence.map?["values"]?.array == [.string(expected), .string("intact")], "sequence scalar quote boundaries match block and flow maps")
        }
        let multiline = try SafeYAML.parse(#"""
        node: {name: Demo,
          password: ab''cd, # discarded
          tags: [ab ""literal,
            'can''t # [ ]', "a \"quote\" # }"]}
        """#)
        try check(multiline.map?["node"]?.map?["password"]?.text == "ab''cd", "multiline flow maps retain their scalar context across comments")
        try check(multiline.map?["node"]?.map?["tags"]?.array == [.string(#"ab ""literal"#), .string("can't # [ ]"), .string(#"a "quote" # }"#)], "mixed plain and quoted flow sequence values agree on delimiters")
        let continuedPlain = try SafeYAML.parse("node: {password: ab\n  'cd # discarded\n  , next: intact}")
        try check(continuedPlain.map?["node"]?.map?["password"]?.text == "ab 'cd", "continuation lines cannot turn part of a plain scalar into a quoted scalar")
        try check(try SafeYAML.parse(#"{"a'key":"can''t # ] }","other":true}"#).map?["a'key"]?.text == "can''t # ] }", "compact JSON separators remain valid next to quoted strings")
        try check(try SafeYAML.parse("password: ab[cd{ef # discarded").map?["password"]?.text == "ab[cd{ef", "block plain brackets do not create flow collections")
        try rejects("unclosed quoted flow scalar") { _ = try SafeYAML.parse("node: {password: 'ab''cd}") }
        try rejects("characters following a quoted scalar") { _ = try SafeYAML.parse("password: 'ab'cd # discarded") }
        try rejects("duplicate JSON/YAML keys") { _ = try SafeYAML.parse("a: 1\na: 2") }
        try rejects("YAML anchors") { _ = try SafeYAML.parse("a: &secret value\nb: *secret") }
        try rejects("YAML tags") { _ = try SafeYAML.parse("a: !!python/object x") }
        try rejects("YAML complex keys") { _ = try SafeYAML.parse("? [one, two]\n: value") }
        try rejects("YAML multiline scalar") { _ = try SafeYAML.parse("a: |\n  arbitrary") }
        try rejects("YAML tab indentation") { _ = try SafeYAML.parse("a:\n\tb: true") }
        try rejects("depth limit") { _ = try SafeYAML.parse(String(repeating: "[", count: 25) + "true" + String(repeating: "]", count: 25)) }
        try rejects("oversized input") { _ = try SafeYAML.parse(Data(repeating: 65, count: 4 * 1_024 * 1_024 + 1)) }
        let advanced = try AdvancedOptions.parse(yaml: AdvancedOptions.exampleYAML)
        try check(try AdvancedOptions.parse(yaml: advanced.yamlString) == advanced, "advanced YAML roundtrip")
        try rejects("advanced arbitrary controller") { _ = try AdvancedOptions.parse(yaml: "external-controller: 0.0.0.0:9090") }
        try rejects("advanced local nameserver file") { _ = try AdvancedOptions.parse(yaml: "dns:\n  nameserver: [file:///etc/passwd]") }
        print("Safe YAML: structural limits, unsupported syntax and advanced-option allowlist tests passed")
    }

    static func configurationTests() throws {
        let nodeID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let node = ProxyNode(id: nodeID, name: "Golden SS", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "test-only-password", sourceID: sourceID)
        let subscription = RoutingRule(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .domainSuffix, value: "example.test", policy: "Golden SS", sourceID: sourceID)
        let process = RoutingRule.chatGPT
        let profile = RuntimeProfile(nodes: [node], rules: [subscription, process], selectedNode: node.name)
        try check(ConfigurationBuilder.orderedRules(profile.rules).map(\.id) == [process.id, subscription.id], "user rules always precede subscription rules; relative order is stable")
        let data = try ConfigurationBuilder.makeConfiguration(profile: profile, tunEnabled: true, controllerPath: "/var/run/clairroute/controller.sock")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rules = json["rules"] as! [String]
        try check(rules[0].hasPrefix("PROCESS-PATH-REGEX,") && rules.last == "MATCH,DIRECT", "default ChatGPT rule and direct fallback")
        let groups = json["proxy-groups"] as! [[String: Any]]
        try check(groups.first(where: { $0["name"] as? String == "PROXY" })?["default-selected"] as? String == node.name, "selected node survives freshly generated configuration")
        try check(groups.first?["default-selected"] as? String == "NODE_" + nodeID.uuidString.lowercased(), "provider internal node names cannot collide with wrapper groups")
        let providers = json["proxy-providers"] as! [String: [String: Any]]
        try check(providers.values.allSatisfy { $0["type"] as? String == "inline" && $0["path"] == nil && $0["url"] == nil }, "only memory inline providers, no credential cache path or remote URL")
        let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/selected-chatgpt.json")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL))
        let normalizedExpected = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .withoutEscapingSlashes])
        try check(data == normalizedExpected, "configuration golden file")
        var invalid = profile; invalid.nodes[0].name = "PROXY"
        try rejects("reserved node name") { try ConfigurationBuilder.validate(invalid) }
        invalid = profile; invalid.nodes[0].plugin = "/tmp/evil"
        try rejects("external plugin path") { try ConfigurationBuilder.validate(invalid) }
        invalid = profile; invalid.rules[0] = RoutingRule(kind: .processPathRegex, value: "^/(a+)+$/")
        try rejects("unbounded process regex") { try ConfigurationBuilder.validate(invalid) }
        try autoSelectTests(sourceID: sourceID)
        let defaultProfile = RuntimeProfile()
        try check(defaultProfile.rules == [.chatGPT] && defaultProfile.fallbackPolicy == "DIRECT", "fresh install defaults to ChatGPT only")
        let oldProfile = try JSONDecoder().decode(RuntimeProfile.self, from: Data(#"{"nodes":[],"mode":"rule","chatGPTOnly":true}"#.utf8))
        try check(oldProfile.rules == [.chatGPT], "M1 persisted profile backward decoding")
        try check(LibrarySnapshot().rules == [.chatGPT, .netflix, .hbo], "fresh library routes ChatGPT, Netflix and HBO through PROXY")
        let chatGPTJSON = String(data: try JSONEncoder().encode([RoutingRule.chatGPT]), encoding: .utf8)!
        let upgraded = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(#"{"version":3,"rules":\#(chatGPTJSON)}"#.utf8))
        try check(upgraded.rules == RoutingRule.defaults && upgraded.defaultRulesRevision == RoutingRule.defaultsRevision,
                  "an existing profile receives the new default rules once")
        var trimmed = upgraded; trimmed.rules.removeAll { $0 == .hbo }
        let reloaded = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONEncoder().encode(trimmed))
        try check(reloaded.rules == [.chatGPT, .netflix], "a deleted default rule is not added back")
        let custom = RoutingRule(kind: .geosite, value: "NETFLIX", policy: "DIRECT")
        let customJSON = String(data: try JSONEncoder().encode([custom]), encoding: .utf8)!
        let kept = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(#"{"version":3,"rules":\#(customJSON)}"#.utf8))
        try check(kept.rules == [custom, .hbo], "an existing Netflix rule keeps the user's policy")
        print("Configuration: golden, stable priority, selection, default routing and provider isolation tests passed")
    }

    static func autoSelectTests(sourceID: UUID) throws {
        let pool = (1...6).map { ProxyNode(name: "Auto \($0)", server: "example.test", port: 440 + $0, cipher: "aes-256-gcm", password: "test-only-password", sourceID: sourceID) }
        let local = ProxyNode(name: "Local", server: "example.test", port: 8443, cipher: "aes-256-gcm", password: "test-only-password")
        let firstFive = (1...5).map { "Auto \($0)" }
        var profile = RuntimeProfile(nodes: [local] + pool, selectedNode: "Auto 3", autoSelect: AutoSelectSettings(enabled: true))
        func groups() throws -> [String: [String: Any]] {
            let data = try ConfigurationBuilder.makeConfiguration(profile: profile, tunEnabled: false, controllerPath: "/var/run/clairroute-test.sock")
            let list = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["proxy-groups"] as! [[String: Any]]
            return Dictionary(uniqueKeysWithValues: list.map { ($0["name"] as! String, $0) })
        }
        try check(ConfigurationBuilder.autoSelectCandidates(profile) == firstFive, "automatic candidates are the first five nodes of the selected node's subscription; the sixth is excluded")
        var output = try groups()
        let auto = output[ConfigurationBuilder.autoPolicy]
        try check(auto?["type"] as? String == "url-test" && auto?["proxies"] as? [String] == firstFive
            && auto?["interval"] as? Int == 120 && auto?["tolerance"] as? Int == 50 && auto?["lazy"] as? Bool == false, "automatic group is a native url-test over the candidates")
        try check(output["PROXY"]?["default-selected"] as? String == ConfigurationBuilder.autoPolicy
            && (output["PROXY"]?["proxies"] as? [String])?.first == ConfigurationBuilder.autoPolicy, "PROXY starts on the automatic group")
        try check(output[ConfigurationBuilder.sourcePolicy(sourceID)]?["default-selected"] as? String == "PROXY", "subscription rules follow PROXY instead of the provider's first node")
        profile.selectedNode = "Local"
        output = try groups()
        try check(ConfigurationBuilder.autoSelectCandidates(profile) == ["Local"]
            && output[ConfigurationBuilder.sourcePolicy(sourceID)]?["proxies"] == nil, "a local selection anchors candidates to local nodes and leaves subscription groups alone")
        profile.autoSelect.enabled = false
        output = try groups()
        try check(output[ConfigurationBuilder.autoPolicy] == nil && output["PROXY"]?["default-selected"] as? String == "Local"
            && output["PROXY"]?["proxies"] as? [String] == ["Local"] + pool.map(\.name), "disabled automatic selection generates the previous manual PROXY group")
        let otherSource = UUID(uuidString: "88888888-2222-3333-4444-555555555555")!
        profile.nodes.append(ProxyNode(name: "Other subscription", server: "example.test", port: 443,
                                      cipher: "aes-256-gcm", password: "test-only-password", sourceID: otherSource))
        profile.selectedNode = "Auto 3"
        output = try groups()
        try check(output[ConfigurationBuilder.sourcePolicy(sourceID)]?["default-selected"] as? String == "PROXY"
            && output[ConfigurationBuilder.sourcePolicy(otherSource)]?["proxies"] == nil, "only the selected subscription follows PROXY")
        profile.selectedNode = "Other subscription"
        output = try groups()
        try check(output[ConfigurationBuilder.sourcePolicy(otherSource)]?["default-selected"] as? String == "PROXY"
            && output[ConfigurationBuilder.sourcePolicy(sourceID)]?["proxies"] == nil,
                  "switching subscriptions moves the PROXY link and removes the previous link")
        profile.autoSelect = AutoSelectSettings(enabled: true, interval: 7)
        try rejects("unsupported automatic interval") { try ConfigurationBuilder.validate(profile) }
        profile.autoSelect = AutoSelectSettings(enabled: true, candidateCount: 0)
        try rejects("empty automatic candidate set") { try ConfigurationBuilder.validate(profile) }
        let older = try JSONDecoder().decode(RuntimeProfile.self, from: Data(#"{"nodes":[]}"#.utf8))
        try check(older.autoSelect == AutoSelectSettings(), "profiles without automatic selection decode with it off")
    }

    static func recoveryTests() throws {
        let deadline = RecoveryDeadline(bootID: 42, continuousNanoseconds: 120_000_000_000)
        try check(!deadline.hasExpired(bootID: 42, continuousNanoseconds: 119_999_999_999), "trial before 120 seconds")
        try check(deadline.hasExpired(bootID: 42, continuousNanoseconds: 120_000_000_000), "trial at 120 seconds")
        try check(deadline.hasExpired(bootID: 42, continuousNanoseconds: 120_000_000_001), "trial after 120 seconds")
        try check(deadline.hasExpired(bootID: 43, continuousNanoseconds: 0), "boot changed")
        let process = RecoveryProcessFingerprint(pid: 123, startedSeconds: 1_000, startedMicroseconds: 100)
        try check(process.matches(process), "matching process generation")
        try check(!process.matches(RecoveryProcessFingerprint(pid: 123, startedSeconds: 1_001, startedMicroseconds: 100)), "reused PID with different start time")
        try check(!process.matches(nil), "missing process cannot be signalled")
        print("Recovery: 120-second monotonic deadline, reboot and PID-generation tests passed")
    }
}

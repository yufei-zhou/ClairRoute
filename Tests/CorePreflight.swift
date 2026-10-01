import Foundation
import Darwin

/// Deliberately separate from OfflineTests: stdout is generated fixture config only.
/// This executable does not launch the core or access any network or Keychain API.
@main struct CorePreflight {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let subscription = try SubscriptionParser.parse(Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/full-clash.yaml")), sourceID: sourceID)
        var nodes = subscription.nodes
        let keys: [(String, Int)] = [("2022-blake3-aes-128-gcm", 16), ("2022-blake3-aes-256-gcm", 32), ("2022-blake3-chacha20-poly1305", 32)]
        for (cipher, size) in keys {
            nodes.append(ProxyNode(name: "Preflight " + cipher, server: "example.test", port: 443, cipher: cipher, password: Data(repeating: 7, count: size).base64EncodedString()))
        }
        nodes.append(ProxyNode(name: "Preflight obfs", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "fixture-only-password", plugin: "obfs", pluginOptions: ["mode": "tls", "host": "example.test"]))
        nodes.append(ProxyNode(name: "Preflight v2ray-plugin", server: "example.test", port: 443, cipher: "aes-256-gcm", password: "fixture-only-password", plugin: "v2ray-plugin", pluginOptions: ["mode": "websocket", "host": "example.test", "path": "/socket", "tls": "true"]))
        nodes.append(ProxyNode(name: "Preflight VMess WS", server: "example.test", port: 443, type: .vmess, uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", servername: "example.test", clientFingerprint: "chrome", tls: true, network: "ws", wsPath: "/socket", wsHost: "example.test"))
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        nodes.append(ProxyNode(name: "Preflight VLESS Reality", server: "example.test", port: 443, type: .vless, uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", flow: "xtls-rprx-vision", servername: "example.test", clientFingerprint: "chrome", publicKey: publicKey, shortID: "0123", tls: true))
        let rules = [RoutingRule.chatGPT, RoutingRule(kind: .geosite, value: "telegram", policy: "PROXY")] + subscription.rules
        var advanced = AdvancedOptions()
        // Avoid even the core's IPv6 socket capability probe during this preflight.
        advanced.ipv6 = false
        let profile = RuntimeProfile(nodes: nodes, rules: rules, selectedNode: "Preflight VLESS Reality", advanced: advanced)
        let config = try ConfigurationBuilder.makeConfiguration(profile: profile, tunEnabled: false, controllerPath: "/var/run/clairroute-preflight.sock")
        FileHandle.standardOutput.write(config)
    }
}

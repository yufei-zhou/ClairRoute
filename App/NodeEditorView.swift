import SwiftUI

struct NodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var node: ProxyNode
    let save: (ProxyNode) throws -> Void
    @State private var error: String?
    @State private var pluginOptions = ""

    /// Must stay in sync with the fingerprints accepted by `ConfigurationBuilder.validateNode`.
    private static let fingerprints = ["", "chrome", "firefox", "safari", "ios", "android", "edge", "random", "randomized", "360", "qq"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("节点配置").font(.title2.bold())
            Form {
                Section("基本信息") {
                    TextField("名称", text: $node.name)
                    Picker("协议", selection: $node.type) {
                        Text("Shadowsocks").tag(ProxyProtocol.shadowsocks)
                        Text("VMess").tag(ProxyProtocol.vmess)
                        Text("VLESS / Reality").tag(ProxyProtocol.vless)
                    }
                    TextField("服务器", text: $node.server, prompt: Text("域名或 IP"))
                    TextField("端口", value: $node.port, format: .number.grouping(.never))
                }
                if node.type == .shadowsocks {
                    Section("认证") {
                        Picker("加密方式", selection: $node.cipher) {
                            ForEach(ConfigurationBuilder.supportedCiphers, id: \.self) { Text($0).tag($0) }
                        }
                        SecureField("密码 / SS2022 Base64 密钥", text: $node.password)
                        Picker("插件", selection: $node.plugin) {
                            Text("无").tag(""); Text("obfs").tag("obfs"); Text("v2ray-plugin").tag("v2ray-plugin")
                        }
                        if !node.plugin.isEmpty {
                            TextField("插件选项", text: $pluginOptions, prompt: Text("key=value;key=value"))
                        }
                    }
                } else {
                    Section("认证") {
                        SecureField("UUID", text: $node.uuid)
                        if node.type == .vless {
                            Picker("Flow", selection: $node.flow) { Text("无").tag(""); Text("xtls-rprx-vision").tag("xtls-rprx-vision") }
                        } else {
                            TextField("Alter ID", value: $node.alterID, format: .number.grouping(.never))
                            Picker("加密方式", selection: $node.security) {
                                ForEach(["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"], id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    Section("TLS") {
                        Toggle("启用 TLS", isOn: $node.tls)
                        TextField("SNI / Server name", text: $node.servername)
                        Picker("客户端指纹", selection: $node.clientFingerprint) {
                            ForEach(Self.fingerprints, id: \.self) { Text($0.isEmpty ? "默认" : $0).tag($0) }
                        }
                        if node.type == .vless {
                            TextField("Reality 公钥", text: $node.publicKey, prompt: Text("留空表示不使用 Reality"))
                            TextField("Reality short ID", text: $node.shortID)
                        }
                    }
                    Section("传输") {
                        Picker("传输方式", selection: $node.network) {
                            Text("TCP").tag("tcp"); Text("WebSocket").tag("ws"); Text("gRPC").tag("grpc")
                        }
                        if node.network == "ws" {
                            TextField("WebSocket 路径", text: $node.wsPath, prompt: Text("/"))
                            TextField("WebSocket Host", text: $node.wsHost)
                        } else if node.network == "grpc" {
                            TextField("gRPC service name", text: $node.serviceName)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 460)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存节点") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 650)
        .onAppear { pluginOptions = node.pluginOptions.keys.sorted().map { $0 + "=" + (node.pluginOptions[$0] ?? "") }.joined(separator: ";") }
        .onChange(of: node.type) { _, type in resetFields(for: type) }
        .onChange(of: node.network) { _, network in
            // Fields of the previous transport would otherwise fail validation on save.
            if network != "ws" { node.wsPath = ""; node.wsHost = "" }
            if network != "grpc" { node.serviceName = "" }
        }
    }

    private func submit() {
        do {
            var options: [String: String] = [:]
            for item in pluginOptions.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, !pair[0].isEmpty, options[pair[0]] == nil else { throw ClientError.rejected("插件选项格式应为 key=value，以分号分隔且不重复。") }
                options[pair[0]] = pair[1]
            }
            var value = node
            value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.server = value.server.trimmingCharacters(in: .whitespacesAndNewlines)
            value.pluginOptions = value.plugin.isEmpty ? [:] : options
            try save(value)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    /// Clears fields that do not apply to the newly selected protocol.
    private func resetFields(for type: ProxyProtocol) {
        if type == .shadowsocks {
            node.uuid = ""; node.flow = ""; node.servername = ""; node.clientFingerprint = ""
            node.publicKey = ""; node.shortID = ""; node.tls = false; node.network = "tcp"
            node.alterID = 0; node.security = "auto"; node.wsPath = ""; node.wsHost = ""; node.serviceName = ""
            if node.cipher.isEmpty { node.cipher = "aes-256-gcm" }
        } else {
            node.cipher = ""; node.password = ""; node.plugin = ""; node.pluginOptions = [:]; pluginOptions = ""
            if type == .vmess { node.flow = ""; node.publicKey = ""; node.shortID = "" }
            else { node.alterID = 0; node.security = "auto"; node.tls = true; if node.clientFingerprint.isEmpty { node.clientFingerprint = "chrome" } }
        }
    }
}

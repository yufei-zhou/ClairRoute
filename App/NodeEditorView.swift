import SwiftUI

struct NodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var node: ProxyNode
    let save: (ProxyNode) throws -> Void
    @State private var error: String?
    @State private var pluginOptions = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("节点配置").font(.title2.bold())
            ScrollView {
                Form {
                    TextField("名称", text: $node.name)
                    Picker("协议", selection: $node.type) {
                        Text("Shadowsocks").tag(ProxyProtocol.shadowsocks)
                        Text("VMess").tag(ProxyProtocol.vmess)
                        Text("VLESS / Reality").tag(ProxyProtocol.vless)
                    }
                    TextField("服务器", text: $node.server)
                    TextField("端口", value: $node.port, format: .number.grouping(.never))
                    if node.type == .shadowsocks {
                        Picker("Cipher", selection: $node.cipher) {
                            ForEach(ConfigurationBuilder.supportedCiphers, id: \.self) { Text($0).tag($0) }
                        }
                        SecureField("密码 / SS2022 Base64 密钥", text: $node.password)
                        Picker("插件", selection: $node.plugin) {
                            Text("无").tag(""); Text("obfs").tag("obfs"); Text("v2ray-plugin").tag("v2ray-plugin")
                        }
                        if !node.plugin.isEmpty {
                            TextField("插件选项（key=value;…）", text: $pluginOptions)
                        }
                    } else {
                        SecureField("UUID", text: $node.uuid)
                        if node.type == .vless {
                            Picker("Flow", selection: $node.flow) { Text("无").tag(""); Text("xtls-rprx-vision").tag("xtls-rprx-vision") }
                        } else {
                            TextField("Alter ID", value: $node.alterID, format: .number.grouping(.never))
                            Picker("Security", selection: $node.security) {
                                ForEach(["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"], id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Toggle("TLS", isOn: $node.tls)
                        TextField("Server name / SNI", text: $node.servername)
                        TextField("Client fingerprint", text: $node.clientFingerprint)
                        if node.type == .vless {
                            TextField("Reality public key", text: $node.publicKey)
                            TextField("Reality short ID", text: $node.shortID)
                        }
                        Picker("传输", selection: $node.network) {
                            Text("TCP").tag("tcp"); Text("WebSocket").tag("ws"); Text("gRPC").tag("grpc")
                        }
                        if node.network == "ws" {
                            TextField("WebSocket path", text: $node.wsPath); TextField("WebSocket Host", text: $node.wsHost)
                        } else if node.network == "grpc" { TextField("gRPC service name", text: $node.serviceName) }
                    }
                }.formStyle(.grouped)
            }.frame(height: 440)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存节点") {
                    do {
                        var options: [String: String] = [:]
                        for item in pluginOptions.split(separator: ";") {
                            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                            guard pair.count == 2, !pair[0].isEmpty, options[pair[0]] == nil else { throw ClientError.rejected("插件选项格式应为 key=value，以分号分隔且不重复。") }
                            options[pair[0]] = pair[1]
                        }
                        node.pluginOptions = node.plugin.isEmpty ? [:] : options
                        try save(node); node.password = ""; node.uuid = ""; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 650)
        .onAppear { pluginOptions = node.pluginOptions.keys.sorted().map { $0 + "=" + (node.pluginOptions[$0] ?? "") }.joined(separator: ";") }
        .onChange(of: node.type) { _, type in
            if type == .shadowsocks {
                node.uuid = ""; node.flow = ""; node.servername = ""; node.clientFingerprint = ""
                node.publicKey = ""; node.shortID = ""; node.tls = false; node.network = "tcp"
                node.alterID = 0; node.security = "auto"; node.wsPath = ""; node.wsHost = ""; node.serviceName = ""
                if node.cipher.isEmpty { node.cipher = "aes-256-gcm" }
            } else {
                node.cipher = ""; node.password = ""; node.plugin = ""; node.pluginOptions = [:]; pluginOptions = ""
                if type == .vmess { node.flow = ""; node.publicKey = ""; node.shortID = "" }
                else { node.alterID = 0; node.security = "auto"; node.tls = true; node.clientFingerprint = "chrome" }
            }
        }
    }
}

import AppKit
import SwiftUI

// Separate executable, never part of the shipped app. All state is synthetic and
// every service is injected: no real subscriptions, credentials, XPC or network.
private final class PreviewPreferences: AppPreferenceStorage {
    func string(forKey key: String) -> String? { nil }
    func set(_ value: Any?, forKey key: String) {}
}
private final class PreviewVault: SecretVault {
    func read(_ id: UUID) throws -> Data { throw StoreError.missingSecret }
    func write(_ data: Data, id: UUID) throws { throw StoreError.invalidData }
    func remove(_ id: UUID) throws { throw StoreError.invalidData }
}
@MainActor private final class PreviewHelper: HelperControlling {
    var onDisconnect: (() -> Void)?
    func status() async throws -> ServiceStatus { .idle }
    func stop() async throws -> ServiceStatus { .idle }
    func apply(_ request: ApplyRequest) async throws -> ServiceStatus { throw ClientError.unsignedBuild }
    func heartbeat(sessionID: UUID) async throws -> ServiceStatus { .idle }
    func connections() async throws -> [ConnectionSnapshot] { [] }
    func proxies() async throws -> [ProxySnapshot] { [] }
    func delay(node: String) async throws -> Int { throw ClientError.unsignedBuild }
}
private actor PreviewSubscriptions: SubscriptionFetching {
    private var calls = 0
    func fetch(_ url: URL) async throws -> SubscriptionDownload {
        calls += 1
        if calls == 3 { throw SubscriptionError.httpStatus(503) }
        var yaml = "mixed-port: 7890\nmode: rule\nproxies:\n"
        for index in 1...6 {
            yaml += "  - {name: 'Sample \(index) · a-long-node-name.example.test:443', type: ss, server: example.test, port: 443, cipher: aes-256-gcm, password: fixture-only}\n"
        }
        yaml += "proxy-groups:\n  - {name: 'Sample group', type: select, proxies: ['Sample 1 · a-long-node-name.example.test:443']}\nrules:\n  - MATCH,PROXY\n"
        if calls == 4 { yaml += "  - GEOIP,CN,DIRECT\n" }
        return SubscriptionDownload(data: Data(yaml.utf8), userInfo: nil)
    }
}
@MainActor private enum PreviewFixture {
    static func make() -> AppModel {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-preview/fixtures/" + UUID().uuidString)
        let library = AppLibraryModel(store: ProfileStore(directory: directory, vault: PreviewVault()),
                                      service: PreviewSubscriptions(), automaticRefresh: false)
        try! library.addSubscription(name: "Sample subscription", url: "https://example.test/subscription", interval: 86_400)
        // Enable the controls for layout testing; every privileged operation still goes
        // to PreviewHelper, and the real App delegate is never instantiated.
        let model = AppModel(library: library, client: PreviewHelper(), preferences: PreviewPreferences(), signed: true)
        model.selectedPage = .library
        return model
    }
    static func seed(_ model: AppModel) async {
        guard model.library.nodes.isEmpty, let id = model.library.subscriptions.first?.id else { return }
        try? await model.library.refreshSubscription(id: id)
        try? model.library.selectNode(model.library.nodes.dropFirst().first?.name)
        model.dismissError()
    }
}
@main struct ClairRouteUIPreview: App {
    @StateObject private var model = PreviewFixture.make()
    var body: some Scene {
        Window("ClairRoute UI Preview", id: "preview") {
            MainView(model: model, library: model.library).task { await PreviewFixture.seed(model) }
        }.defaultSize(width: 1060, height: 740)
            .windowStyle(.titleBar)
    }
}

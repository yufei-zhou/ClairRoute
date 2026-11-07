import Foundation
import Network

enum LaunchConnection: String, CaseIterable {
    case manual, automatic
    static let preferenceKey = "ClairRoute.launchConnection"
    var title: String { self == .manual ? "手动连接" : "自动连接" }
}

/// Only confirmed ordinary sessions update this preference; stopping preserves it.
enum StartupTakeover: String, CaseIterable {
    case tun, systemProxy, both
    static let preferenceKey = "ClairRoute.lastSuccessfulTakeover"
    var tunEnabled: Bool { self != .systemProxy }
    var systemProxyEnabled: Bool { self != .tun }
    var title: String {
        switch self {
        case .tun: "增强模式（TUN）"
        case .systemProxy: "系统代理"
        case .both: "增强模式（TUN）+ 系统代理"
        }
    }
    init?(tun: Bool, systemProxy: Bool) {
        switch (tun, systemProxy) {
        case (true, false): self = .tun
        case (false, true): self = .systemProxy
        case (true, true): self = .both
        case (false, false): return nil
        }
    }
}

@MainActor protocol StartupNetworkMonitoring: AnyObject {
    var isAvailable: Bool { get }
    func start()
    func stop()
}

/// Observes the system path only. It does not send a probe or change networking.
@MainActor final class StartupNetworkMonitor: StartupNetworkMonitoring {
    private var monitor: NWPathMonitor?
    private var generation = UUID()
    private(set) var isAvailable = false
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let token = UUID(); generation = token
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.isAvailable = available
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.nano.ClairRoute.launch-network"))
    }
    func stop() {
        generation = UUID()
        monitor?.cancel(); monitor = nil; isAvailable = false
    }
}

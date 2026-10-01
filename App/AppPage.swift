/// Sidebar destinations of the main window.
enum AppPage: String, CaseIterable, Identifiable {
    case overview, library, rules, connections, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概览"
        case .library: "节点与订阅"
        case .rules: "规则"
        case .connections: "连接"
        case .advanced: "高级与维护"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .library: "server.rack"
        case .rules: "list.bullet.rectangle"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .advanced: "gearshape"
        }
    }
}

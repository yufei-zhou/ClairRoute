import Foundation

/// Both endpoints must set their code-signing requirement before resuming the connection.
/// Data contains bounded Codable messages; the helper never accepts paths, commands or YAML.
@objc public protocol ClairRouteHelperProtocol {
    func apply(_ data: Data, withReply reply: @escaping (Data) -> Void)
    func stop(withReply reply: @escaping (Data) -> Void)
    func readStatus(withReply reply: @escaping (Data) -> Void)
    func heartbeat(_ data: Data, withReply reply: @escaping (Data) -> Void)
    func inspect(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

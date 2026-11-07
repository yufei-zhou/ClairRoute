import Foundation

enum ClientError: LocalizedError {
    case unsignedBuild, unavailable, invalidReply, rejected(String), timeout
    case rejectedWithStatus(String, ServiceStatus)
    var errorDescription: String? {
        switch self {
        case .unsignedBuild: "当前构建没有配置本机签名身份，只能查看界面。请按 README 完成本机签名和安装。"
        case .unavailable: "无法连接特权 Helper；当前网络状态尚未确认。请检查本机安装并重新读取状态。"
        case .invalidReply: "Helper 返回了无效或未经验证的响应。"
        case .rejected(let message): message
        case .rejectedWithStatus(let message, _): message
        case .timeout: "Helper 响应超时。请查看状态；Helper 的会话监督仍会处理恢复。"
        }
    }
    var reportedStatus: ServiceStatus? {
        if case .rejectedWithStatus(_, let status) = self { return status }
        return nil
    }
}

private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func complete(_ result: Result<Data, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Offline lifecycle tests replace every privileged call with a recorder.
@MainActor protocol HelperControlling: AnyObject {
    var onDisconnect: (() -> Void)? { get set }
    func status() async throws -> ServiceStatus
    func stop() async throws -> ServiceStatus
    func apply(_ request: ApplyRequest) async throws -> ServiceStatus
    func heartbeat(sessionID: UUID) async throws -> ServiceStatus
    func connections() async throws -> [ConnectionSnapshot]
    func proxies() async throws -> [ProxySnapshot]
    func delay(node: String) async throws -> Int
}

@MainActor final class HelperClient: HelperControlling {
    private var connection: NSXPCConnection?
    private var activeSessionID: UUID?
    private var delayInFlight = false
    var onDisconnect: (() -> Void)?

    static var hasSigningIdentity: Bool {
        guard let fingerprint = Bundle.main.object(forInfoDictionaryKey: "ClairRouteCertificateSHA1") as? String else { return false }
        return fingerprint.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil
    }

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        guard Self.hasSigningIdentity,
              let requirement = Bundle.main.object(forInfoDictionaryKey: "ClairRouteHelperRequirement") as? String,
              !requirement.isEmpty else { throw ClientError.unsignedBuild }
        let c = NSXPCConnection(machServiceName: AppConstants.machServiceName, options: .privileged)
        c.setCodeSigningRequirement(requirement)
        c.remoteObjectInterface = NSXPCInterface(with: ClairRouteHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil; self?.activeSessionID = nil; self?.onDisconnect?() }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.activeSessionID = nil; self?.onDisconnect?() }
        }
        c.resume()
        connection = c
        return c
    }

    private func exchange(timeout: TimeInterval = 90,
                          _ body: (any ClairRouteHelperProtocol, @escaping (Data) -> Void) -> Void) async throws -> Data {
        let c = try connect()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.complete(.failure(ClientError.timeout)) }
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in
                gate.complete(.failure(ClientError.unavailable))
            }) as? any ClairRouteHelperProtocol else {
                gate.complete(.failure(ClientError.unavailable)); return
            }
            body(proxy) { data in
                guard data.count <= AppConstants.maximumMessageBytes else {
                    gate.complete(.failure(ClientError.invalidReply)); return
                }
                gate.complete(.success(data))
            }
        }
        guard c.effectiveUserIdentifier == 0 else { c.invalidate(); throw ClientError.invalidReply }
        return data
    }

    private func perform(timeout: TimeInterval = 90,
                         _ body: (any ClairRouteHelperProtocol, @escaping (Data) -> Void) -> Void) async throws -> ServiceStatus {
        let data = try await exchange(timeout: timeout, body)
        guard let reply = try? JSONDecoder().decode(ServiceReply.self, from: data) else {
            throw ClientError.invalidReply
        }
        if let error = reply.error {
            if let status = reply.status { throw ClientError.rejectedWithStatus(error, status) }
            throw ClientError.rejected(error)
        }
        guard let status = reply.status else { throw ClientError.invalidReply }
        return status
    }

    func status() async throws -> ServiceStatus { try await perform(timeout: 5) { $0.readStatus(withReply: $1) } }
    func stop() async throws -> ServiceStatus {
        let status = try await perform(timeout: 45) { $0.stop(withReply: $1) }
        activeSessionID = nil
        return status
    }
    func apply(_ request: ApplyRequest) async throws -> ServiceStatus {
        let data = try JSONEncoder().encode(request)
        guard data.count <= AppConstants.maximumMessageBytes else { throw ClientError.invalidReply }
        let status = try await perform { $0.apply(data, withReply: $1) }
        activeSessionID = status.phase == .active ? request.sessionID : nil
        return status
    }
    func heartbeat(sessionID: UUID) async throws -> ServiceStatus {
        let data = try JSONEncoder().encode(HeartbeatRequest(sessionID: sessionID))
        return try await perform(timeout: 5) { $0.heartbeat(data, withReply: $1) }
    }

    func connections() async throws -> [ConnectionSnapshot] {
        guard let result = try await inspect(.connections).connections else { throw ClientError.invalidReply }
        return result
    }

    func proxies() async throws -> [ProxySnapshot] {
        guard let result = try await inspect(.proxies).proxies else { throw ClientError.invalidReply }
        return result
    }

    func delay(node: String) async throws -> Int {
        guard !delayInFlight else { throw ClientError.rejected("另一个节点延迟测试仍在进行。") }
        delayInFlight = true
        defer { delayInFlight = false }
        guard let result = try await inspect(.delay, node: node).delayMilliseconds else { throw ClientError.invalidReply }
        return result
    }

    func select(node: String) async throws -> ServiceStatus {
        guard let result = try await inspect(.select, node: node).status else { throw ClientError.invalidReply }
        return result
    }

    private func inspect(_ operation: InspectionOperation, node: String? = nil) async throws -> InspectionReply {
        guard let sessionID = activeSessionID else { throw ClientError.rejected("请先启用一个已验证的代理会话。") }
        let request = InspectionRequest(sessionID: sessionID, operation: operation, node: node)
        let data = try JSONEncoder().encode(request)
        let timeout: TimeInterval = switch operation {
        case .select: 60 // Includes confirmation, selection rollback, and network restoration.
        case .delay: 12
        case .connections, .proxies: 6
        }
        let response = try await exchange(timeout: timeout) { $0.inspect(data, withReply: $1) }
        guard let reply = try? JSONDecoder().decode(InspectionReply.self, from: response) else { throw ClientError.invalidReply }
        if let error = reply.error {
            if let status = reply.status { throw ClientError.rejectedWithStatus(error, status) }
            throw ClientError.rejected(error)
        }
        return reply
    }
}

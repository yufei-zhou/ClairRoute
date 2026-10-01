import Foundation

public struct ConnectionSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let process: String
    public let processPath: String
    public let host: String
    public let destinationIP: String
    public let destinationPort: Int
    public let network: String
    public let rule: String
    public let rulePayload: String
    public let chains: [String]
    public let upload: UInt64
    public let download: UInt64
}

public struct ProxySnapshot: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let selected: String?
    public let members: [String]
    public let alive: Bool?
}

public enum InspectionOperation: String, Codable, Sendable {
    case connections, proxies, delay, select
}

/// A bounded named operation; never an HTTP method, arbitrary path, URL, or body.
public struct InspectionRequest: Codable, Sendable {
    public let sessionID: UUID
    public let operation: InspectionOperation
    public let node: String?

    public init(sessionID: UUID, operation: InspectionOperation, node: String? = nil) {
        self.sessionID = sessionID
        self.operation = operation
        self.node = node
    }
}

public struct InspectionReply: Codable, Sendable {
    public var connections: [ConnectionSnapshot]?
    public var proxies: [ProxySnapshot]?
    public var delayMilliseconds: Int?
    public var status: ServiceStatus?
    public var error: String?

    public init(connections: [ConnectionSnapshot]? = nil, proxies: [ProxySnapshot]? = nil,
                delayMilliseconds: Int? = nil, status: ServiceStatus? = nil, error: String? = nil) {
        self.connections = connections
        self.proxies = proxies
        self.delayMilliseconds = delayMilliseconds
        self.status = status
        self.error = error
    }
}

/// Pure expiration logic, separately testable without starting processes or touching networking.
public struct RecoveryDeadline: Codable, Equatable, Sendable {
    public let bootID: UInt64
    public let continuousNanoseconds: UInt64
    public init(bootID: UInt64, continuousNanoseconds: UInt64) {
        self.bootID = bootID
        self.continuousNanoseconds = continuousNanoseconds
    }
    public func hasExpired(bootID: UInt64, continuousNanoseconds: UInt64) -> Bool {
        self.bootID != bootID || continuousNanoseconds >= self.continuousNanoseconds
    }
}

/// PID alone is insufficient: a recovered record must also match process creation time.
public struct RecoveryProcessFingerprint: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public init(pid: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
    }
    public func matches(_ candidate: Self?) -> Bool { candidate == self }
}

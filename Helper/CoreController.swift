import Darwin
import Foundation

public struct CoreSnapshot: Sendable {
    public let mode: String
    public let mixedPort: Int
    public let tunEnabled: Bool?

    public init(mode: String, mixedPort: Int, tunEnabled: Bool?) {
        self.mode = mode
        self.mixedPort = mixedPort
        self.tunEnabled = tunEnabled
    }
}

public enum CoreControllerError: LocalizedError, Sendable {
    case unavailable, timedOut, unsafeSocket, malformedResponse, responseTooLarge
    case rejected(Int)
    case invalidConfiguration, unexpectedVersion

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "内核本地控制器尚未就绪或连接已关闭。"
        case .timedOut: return "内核本地控制器请求超时。"
        case .unsafeSocket: return "内核 socket 所有者或目录权限不安全。"
        case .malformedResponse: return "内核控制器返回了无效响应。"
        case .responseTooLarge: return "内核控制器响应超过安全大小限制。"
        case .rejected(let code): return "内核拒绝了配置请求（HTTP \(code)）；响应正文已隐藏以保护凭据。"
        case .invalidConfiguration: return "无法编码内存中的内核配置。"
        case .unexpectedVersion: return "正在运行的内核版本与固定版本不一致。"
        }
    }
}

/// Root-side transport. Call only on the helper's serial worker queue.
/// There is intentionally no public arbitrary-method/path/request API.
public final class CoreController: Sendable {
    private let socketPath: String
    private static let maximumBody = AppConstants.maximumMessageBytes
    private static let maximumHeader = 16_384
    private static let maximumWireBytes = maximumBody + 65_536

    public init(socketPath: String) { self.socketPath = socketPath }

    public func health() throws {
        let data = try request(method: "GET", path: "/version", timeout: 2)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            throw CoreControllerError.malformedResponse
        }
        guard version == AppConstants.coreVersion || version == "v" + AppConstants.coreVersion else {
            throw CoreControllerError.unexpectedVersion
        }
    }

    public func reload(configuration: Data) throws {
        guard configuration.count <= Self.maximumBody,
              let yaml = String(data: configuration, encoding: .utf8) else {
            throw CoreControllerError.invalidConfiguration
        }
        let body = try JSONSerialization.data(withJSONObject: ["payload": yaml],
                                               options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= Self.maximumBody * 2 else { throw CoreControllerError.invalidConfiguration }
        _ = try request(method: "PUT", path: "/configs?force=true", body: body, timeout: 10)
    }

    public func snapshot() throws -> CoreSnapshot {
        let data = try request(method: "GET", path: "/configs", timeout: 3)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = object["mode"] as? String,
              OutboundMode(rawValue: mode) != nil,
              let port = object["mixed-port"] as? Int,
              (0...65_535).contains(port) else {
            throw CoreControllerError.malformedResponse
        }
        let tun = object["tun"] as? [String: Any]
        return CoreSnapshot(mode: mode, mixedPort: port, tunEnabled: tun?["enable"] as? Bool)
    }

    public func connections() throws -> [ConnectionSnapshot] {
        let bytes = try request(method: "GET", path: "/connections", timeout: 3)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let rows = object["connections"] as? [[String: Any]] else {
            throw CoreControllerError.malformedResponse
        }
        // The entire HTTP response is bounded. Only a compact display projection crosses XPC.
        let snapshots: [ConnectionSnapshot] = rows.prefix(200).compactMap { row in
            guard let metadata = row["metadata"] as? [String: Any],
                  let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return nil }
            let port = Self.integer(metadata["destinationPort"]) ?? 0
            return ConnectionSnapshot(id: id,
                process: Self.text(metadata["process"], maximum: 256),
                processPath: Self.text(metadata["processPath"], maximum: 2_048),
                host: Self.text(metadata["host"], maximum: 253),
                destinationIP: Self.text(metadata["destinationIP"], maximum: 128),
                destinationPort: (0...65_535).contains(port) ? port : 0,
                network: Self.text(metadata["network"], maximum: 16),
                rule: Self.text(row["rule"], maximum: 64),
                rulePayload: Self.text(row["rulePayload"], maximum: 512),
                chains: (row["chains"] as? [String] ?? []).prefix(16).map { Self.text($0, maximum: 128) },
                upload: UInt64(Self.text(row["upload"], maximum: 32)) ?? 0,
                download: UInt64(Self.text(row["download"], maximum: 32)) ?? 0)
        }
        var result: [ConnectionSnapshot] = []
        var bytesUsed = 0
        for snapshot in snapshots {
            bytesUsed += (try JSONEncoder().encode(snapshot)).count + 1
            if bytesUsed > 800_000 { break }
            result.append(snapshot)
        }
        return result
    }

    public func proxies(allowedNames: Set<String>) throws -> [ProxySnapshot] {
        let bytes = try request(method: "GET", path: "/proxies", timeout: 3)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let proxies = object["proxies"] as? [String: [String: Any]] else {
            throw CoreControllerError.malformedResponse
        }
        // Callers supply the validated node set plus fixed control groups. Do not
        // truncate away PROXY when all 512 allowed nodes sort before its name.
        return allowedNames.sorted().compactMap { name in
            guard let value = proxies[name] else { return nil }
            let selected = value["now"] as? String
            let members = (value["all"] as? [String] ?? []).filter { allowedNames.contains($0) }
            return ProxySnapshot(name: name, type: Self.text(value["type"], maximum: 64),
                selected: selected.flatMap { allowedNames.contains($0) ? $0 : nil },
                members: Array(members.prefix(512)), alive: value["alive"] as? Bool)
        }
    }

    public func delay(node: String) throws -> Int {
        let path = try Self.proxyPath(node) + "/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000"
        let bytes = try request(method: "GET", path: path, timeout: 6)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let delay = Self.integer(object["delay"]), (0...60_000).contains(delay) else {
            throw CoreControllerError.malformedResponse
        }
        return delay
    }

    public func selectProxy(node: String) throws {
        _ = try Self.proxyPath(node)
        let body = try JSONSerialization.data(withJSONObject: ["name": node])
        _ = try request(method: "PUT", path: "/proxies/PROXY", body: body, timeout: 3)
    }

    private static func proxyPath(_ node: String) throws -> String {
        guard !node.isEmpty, node.utf8.count <= 128,
              !node.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoreControllerError.invalidConfiguration
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = node.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw CoreControllerError.invalidConfiguration
        }
        return "/proxies/" + encoded
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return Int(value.stringValue) }
        return nil
    }

    private static func text(_ value: Any?, maximum: Int) -> String {
        let text: String
        if let value = value as? String { text = value }
        else if let value = value as? NSNumber { text = value.stringValue }
        else { return "" }
        guard text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "" }
        return text
    }

    private func request(method: String, path: String, body: Data = Data(),
                         timeout: TimeInterval) throws -> Data {
        try validateSocket()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreControllerError.unavailable }
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw CoreControllerError.unavailable
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CoreControllerError.unavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        try connect(fd, deadline: deadline)
        // The root-only directory prevents pathname replacement by an unprivileged user.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == 0 else {
            throw CoreControllerError.unsafeSocket
        }
        let header = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var message = Data(header.utf8)
        message.append(body)
        try write(message, to: fd, deadline: deadline)
        return try readResponse(from: fd, deadline: deadline)
    }

    private func validateSocket() throws {
        guard socketPath.hasPrefix("/"), socketPath.utf8.count < 104,
              !socketPath.utf8.contains(0),
              !(socketPath as NSString).pathComponents.contains("..") else {
            throw CoreControllerError.unsafeSocket
        }
        var socketInfo = stat()
        guard lstat(socketPath, &socketInfo) == 0 else { throw CoreControllerError.unavailable }
        guard socketInfo.st_uid == 0, socketInfo.st_mode & S_IFMT == S_IFSOCK else {
            throw CoreControllerError.unsafeSocket
        }
        let parent = (socketPath as NSString).deletingLastPathComponent
        var directoryInfo = stat()
        guard lstat(parent, &directoryInfo) == 0,
              directoryInfo.st_uid == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o077 == 0 else {
            throw CoreControllerError.unsafeSocket
        }
    }

    private func connect(_ fd: Int32, deadline: UInt64) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: socketPath.utf8)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw CoreControllerError.unavailable }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: failure))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else {
                throw CoreControllerError.unavailable
            }
        }
    }

    private func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw CoreControllerError.timedOut }
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&entry, 1, milliseconds)
            if result == 0 { throw CoreControllerError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw CoreControllerError.unavailable
            }
            guard entry.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw CoreControllerError.unavailable
            }
            // POLLHUP may accompany the final readable bytes or EOF.
            if entry.revents & (events | Int16(POLLHUP)) != 0 { return }
        }
    }

    private func write(_ data: Data, to fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let sent = Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if sent > 0 { offset += sent; continue }
                if sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                throw CoreControllerError.unavailable
            }
        }
    }

    private struct ResponseHead {
        let status: Int
        let contentLength: Int?
        let chunked: Bool
    }

    private func readResponse(from fd: Int32, deadline: UInt64) throws -> Data {
        var wire = Data()
        var body = Data()
        var head: ResponseHead?
        var scratch = [UInt8](repeating: 0, count: 16_384)
        var consumed = 0
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = scratch.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CoreControllerError.unavailable
            }
            if count == 0 {
                guard let head else { throw CoreControllerError.malformedResponse }
                if head.chunked {
                    guard let decoded = try decodeChunked(body) else { throw CoreControllerError.malformedResponse }
                    return decoded
                }
                if let expected = head.contentLength, body.count != expected {
                    throw CoreControllerError.malformedResponse
                }
                return body
            }
            consumed += count
            guard consumed <= Self.maximumWireBytes else { throw CoreControllerError.responseTooLarge }
            let received = Data(scratch.prefix(count))
            if head == nil {
                wire.append(received)
                guard let delimiter = wire.range(of: Data("\r\n\r\n".utf8)) else {
                    guard wire.count <= Self.maximumHeader else { throw CoreControllerError.responseTooLarge }
                    continue
                }
                guard delimiter.lowerBound <= Self.maximumHeader else { throw CoreControllerError.responseTooLarge }
                let parsed = try parseHead(Data(wire[..<delimiter.lowerBound]))
                guard (200...299).contains(parsed.status) else { throw CoreControllerError.rejected(parsed.status) }
                head = parsed
                body = Data(wire[delimiter.upperBound...])
                wire.removeAll(keepingCapacity: false)
            } else {
                body.append(received)
            }
            guard let head else { throw CoreControllerError.malformedResponse }
            if head.status == 204 {
                guard body.isEmpty else { throw CoreControllerError.malformedResponse }
                return Data()
            }
            if head.chunked {
                if let decoded = try decodeChunked(body) { return decoded }
            } else {
                guard body.count <= Self.maximumBody else { throw CoreControllerError.responseTooLarge }
                if let expected = head.contentLength {
                    guard body.count <= expected else { throw CoreControllerError.malformedResponse }
                    if body.count == expected { return body }
                }
            }
        }
    }

    private func parseHead(_ data: Data) throws -> ResponseHead {
        guard let text = String(data: data, encoding: .ascii) else { throw CoreControllerError.malformedResponse }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw CoreControllerError.malformedResponse }
        let status = first.split(separator: " ", maxSplits: 2)
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
              status[1].count == 3, let code = Int(status[1]) else { throw CoreControllerError.malformedResponse }
        var length: Int?
        var transfer: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line.first != " ", line.first != "\t" else { throw CoreControllerError.malformedResponse }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                guard length == nil, !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(value), parsed <= Self.maximumBody else {
                    throw CoreControllerError.malformedResponse
                }
                length = parsed
            case "transfer-encoding":
                guard transfer == nil, value.lowercased() == "chunked" else {
                    throw CoreControllerError.malformedResponse
                }
                transfer = value.lowercased()
            case "content-encoding":
                guard value.lowercased() == "identity" else { throw CoreControllerError.malformedResponse }
            default: break
            }
        }
        guard !(length != nil && transfer != nil) else { throw CoreControllerError.malformedResponse }
        if code == 204, (length != nil && length != 0) || transfer != nil {
            throw CoreControllerError.malformedResponse
        }
        return ResponseHead(status: code, contentLength: length, chunked: transfer != nil)
    }

    /// Returns nil only for a bounded, incomplete chunked body. Never confuses EOF with success.
    private func decodeChunked(_ data: Data) throws -> Data? {
        let bytes = [UInt8](data)
        var offset = 0
        var decoded = Data()
        var chunks = 0
        func lineEnd(from start: Int) throws -> Int? {
            var index = start
            while index + 1 < bytes.count {
                if index - start > 4_096 { throw CoreControllerError.responseTooLarge }
                if bytes[index] == 13 && bytes[index + 1] == 10 { return index }
                index += 1
            }
            if bytes.count - start > 4_096 { throw CoreControllerError.responseTooLarge }
            return nil
        }
        while true {
            guard let end = try lineEnd(from: offset) else { return nil }
            let sizePart = bytes[offset..<end].prefix(while: { $0 != 59 })
            guard !sizePart.isEmpty, sizePart.count <= 16,
                  sizePart.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let sizeText = String(bytes: sizePart, encoding: .ascii),
                  let size = Int(sizeText, radix: 16), size <= Self.maximumBody - decoded.count else {
                throw CoreControllerError.malformedResponse
            }
            offset = end + 2
            if size == 0 {
                let trailerStart = offset
                while true {
                    guard let trailerEnd = try lineEnd(from: offset) else { return nil }
                    guard trailerEnd - trailerStart <= Self.maximumHeader else { throw CoreControllerError.responseTooLarge }
                    if trailerEnd == offset {
                        guard trailerEnd + 2 == bytes.count else { throw CoreControllerError.malformedResponse }
                        return decoded
                    }
                    guard bytes[offset..<trailerEnd].contains(58) else { throw CoreControllerError.malformedResponse }
                    offset = trailerEnd + 2
                }
            }
            chunks += 1
            guard chunks <= 4_096 else { throw CoreControllerError.responseTooLarge }
            guard bytes.count - offset >= size + 2 else { return nil }
            decoded.append(contentsOf: bytes[offset..<(offset + size)])
            offset += size
            guard bytes[offset] == 13, bytes[offset + 1] == 10 else { throw CoreControllerError.malformedResponse }
            offset += 2
        }
    }
}

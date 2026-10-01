import Darwin
import Foundation

/// No node credentials are stored here. Values describe only settings owned by this session.
struct NetworkValue: Codable, Equatable {
    let propertyList: Data?

    init(_ value: Any?) throws {
        propertyList = try value.map {
            try PropertyListSerialization.data(fromPropertyList: ["value": $0], format: .binary, options: 0)
        }
    }

    func decoded() throws -> Any? {
        guard let propertyList else { return nil }
        let wrapper = try PropertyListSerialization.propertyList(from: propertyList, options: [], format: nil)
        guard let dictionary = wrapper as? [String: Any], let value = dictionary["value"] else {
            throw NetworkSettingsError.invalidJournal
        }
        return value
    }

    func matches(_ value: Any?) throws -> Bool {
        switch (try decoded(), value) {
        case (nil, nil): return true
        case let (expected?, actual?): return (expected as AnyObject).isEqual(actual)
        default: return false
        }
    }
}

struct NetworkProtocolLease: Codable {
    let serviceID: String
    let serviceName: String
    let protocolType: String
    let originallyPresent: Bool
    let originallyEnabled: Bool
    let originalConfigurationWasNil: Bool
    let previous: [String: NetworkValue]
    let installed: [String: NetworkValue]

    var key: String { serviceID + ":" + protocolType }
}

struct NetworkJournal: Codable {
    let version: Int
    var sessionID: UUID?
    var leases: [String: NetworkProtocolLease]

    static var empty: Self { .init(version: 1, sessionID: nil, leases: [:]) }
}

/// Uses a directory descriptor and openat/renameat; never follows a journal symlink.
/// The helper creates its root-owned state directory before constructing this object.
final class NetworkJournalStore {
    private let directory: Int32
    private let filename = "network-recovery.json"
    private let maximumBytes = 1_048_576

    init(directory url: URL) throws {
        guard geteuid() == 0 else { throw NetworkSettingsError.rootRequired }
        guard url.isFileURL, url.path.hasPrefix("/Library/Application Support/ClairRoute/") ||
                url.path == "/Library/Application Support/ClairRoute" else {
            throw NetworkSettingsError.unsafeStateDirectory
        }
        // Every ancestor must be root-controlled, including the directory used for renameat.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == 0,
                  info.st_mode & 0o022 == 0 else {
                throw NetworkSettingsError.unsafeStateDirectory
            }
        }
        directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw NetworkSettingsError.journalIO("open directory", errno) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == 0, info.st_mode & 0o077 == 0 else {
            close(directory)
            throw NetworkSettingsError.unsafeStateDirectory
        }
    }

    deinit { close(directory) }

    func load() throws -> NetworkJournal {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return .empty }
            throw NetworkSettingsError.journalIO("open journal", errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw NetworkSettingsError.invalidJournal
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw NetworkSettingsError.journalIO("read journal", errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw NetworkSettingsError.invalidJournal }
        }
        let journal = try JSONDecoder().decode(NetworkJournal.self, from: data)
        guard journal.version == 1, journal.leases.count <= 256 else {
            throw NetworkSettingsError.invalidJournal
        }
        for (key, lease) in journal.leases {
            guard key == lease.key, !lease.serviceID.isEmpty,
                  ["DNS", "Proxies"].contains(lease.protocolType),
                  lease.previous.keys == lease.installed.keys,
                  lease.previous.count <= 32 else { throw NetworkSettingsError.invalidJournal }
            for value in lease.previous.values { _ = try value.decoded() }
            for value in lease.installed.values { _ = try value.decoded() }
        }
        return journal
    }

    func save(_ journal: NetworkJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= maximumBytes else { throw NetworkSettingsError.invalidJournal }
        let temporary = ".network-recovery-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NetworkSettingsError.journalIO("create journal", errno) }
        defer {
            close(fd)
            _ = unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NetworkSettingsError.journalIO("write journal", errno)
                }
                guard count > 0 else { throw NetworkSettingsError.journalIO("write journal", EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw NetworkSettingsError.journalIO("sync journal", errno) }
        guard renameat(directory, temporary, directory, filename) == 0 else {
            throw NetworkSettingsError.journalIO("replace journal", errno)
        }
        guard fsync(directory) == 0 else { throw NetworkSettingsError.journalIO("sync directory", errno) }
    }
}

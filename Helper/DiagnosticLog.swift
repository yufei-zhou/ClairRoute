import Darwin
import Foundation

/// Bounded, root-written diagnostics under /Library/Logs/ClairRoute, readable by admin users
/// without sudo. Contains only Helper event messages (our own strings) and mihomo's runtime log
/// (destinations and node addresses, never credentials). Logging failures never affect proxying.
enum DiagnosticLog {
    static let directory = "/Library/Logs/ClairRoute"
    static let coreFile = "core.log"
    static let eventFile = "helper.log"
    private static let maximumBytes: off_t = 4 * 1024 * 1024
    private static let adminGroup: gid_t = 80
    private static let lock = NSLock()

    /// Opens (creating if needed) the directory without following links. Nil disables logging.
    private static func openDirectory() -> Int32? {
        if mkdir(directory, 0o750) != 0 && errno != EEXIST { return nil }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              fchown(fd, 0, adminGroup) == 0, fchmod(fd, 0o750) == 0 else { close(fd); return nil }
        return fd
    }

    /// Returns an append-only descriptor for `name`, rotating it to `name.1` once it is too large.
    static func openFile(_ name: String) -> Int32? {
        guard let dir = openDirectory() else { return nil }
        defer { close(dir) }
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_size > maximumBytes {
            _ = renameat(dir, name, dir, name + ".1")
        }
        let fd = openat(dir, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o640)
        guard fd >= 0 else { return nil }
        guard fstat(fd, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              fchown(fd, 0, adminGroup) == 0, fchmod(fd, 0o640) == 0 else { close(fd); return nil }
        return fd
    }

    /// The running core keeps one append-only descriptor open, so its log cannot be renamed away.
    /// Once it is too large, copy it to `name.1` and truncate it in place; appends continue at 0.
    static func rotateInPlace(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let dir = openDirectory() else { return }
        defer { close(dir) }
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, info.st_size > maximumBytes else { return }
        let source = openat(dir, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { return }
        defer { close(source) }
        _ = unlinkat(dir, name + ".1", 0)
        let copy = openat(dir, name + ".1", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o640)
        if copy >= 0 {
            _ = fchown(copy, 0, adminGroup)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                _ = buffer.withUnsafeBytes { write(copy, $0.baseAddress, count) }
            }
            close(copy)
        }
        _ = ftruncate(source, 0)
    }

    /// Appends one timestamped line to helper.log.
    static func event(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let fd = openFile(eventFile) else { return }
        defer { close(fd) }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withInternetDateTime])
        let line = stamp + " " + message.replacingOccurrences(of: "\n", with: " ") + "\n"
        _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
    }
}

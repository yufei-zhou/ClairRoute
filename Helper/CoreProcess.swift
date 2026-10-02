import Foundation
import Darwin

struct CoreProcessIdentity: Codable, Equatable {
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func read(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == 0, info.pbi_ruid == 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is the C function-like macro 4 * MAXPATHLEN.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0,
              String(decoding: path.prefix(while: { $0 != 0 }), as: UTF8.self) == HelperSecurity.binary.path else { return nil }
        return Self(pid: pid, startedSeconds: info.pbi_start_tvsec,
                    startedMicroseconds: info.pbi_start_tvusec)
    }

    private var fingerprint: RecoveryProcessFingerprint {
        RecoveryProcessFingerprint(pid: pid, startedSeconds: startedSeconds, startedMicroseconds: startedMicroseconds)
    }
    var stillMatches: Bool { fingerprint.matches(Self.read(pid)?.fingerprint) }
}

struct CoreProcessRecord: Codable {
    let version: Int
    let identity: CoreProcessIdentity
    var interfaceIndex: UInt32?
}

/// Contains process identity only; no node, config, credential, or subscription data.
enum CoreProcessJournal {
    static let url = HelperSecurity.state.appendingPathComponent("core-process.json")

    static func load() throws -> CoreProcessRecord? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw HelperFailure.refused("Cannot inspect the core recovery record.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else {
            throw HelperFailure.refused("The core recovery record has unsafe metadata.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        let record = try JSONDecoder().decode(CoreProcessRecord.self, from: bytes)
        guard record.version == 1, record.identity.pid > 1 else {
            throw HelperFailure.refused("The core recovery record is invalid.")
        }
        return record
    }

    static func save(_ record: CoreProcessRecord) throws {
        let data = try JSONEncoder().encode(record)
        let temporary = HelperSecurity.state.appendingPathComponent(".core-process-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HelperFailure.refused("Cannot prepare the core recovery record.") }
        defer { close(descriptor); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw HelperFailure.refused("Cannot commit the core recovery record.")
        }
        try syncDirectory()
    }

    static func clear() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw HelperFailure.refused("Cannot clear the completed core recovery record.")
        }
        try syncDirectory()
    }

    private static func syncDirectory() throws {
        let directory = open(HelperSecurity.state.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw HelperFailure.refused("Cannot sync core recovery state.") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw HelperFailure.refused("Cannot sync core recovery state.") }
    }
}

/// Suspended spawn allows durable recovery identity to be recorded before core code runs.
/// Explicit fd inheritance also prevents the core inheriting Helper's privileged XPC handles.
final class CoreProcess {
    let identity: CoreProcessIdentity
    private var input: Int32
    private var exitStatus: Int32?
    private var observation: DispatchSourceProcess?
    var pid: pid_t { identity.pid }
    var running: Bool { collectExit(); return exitStatus == nil }
    var succeeded: Bool { collectExit(); return exitStatus == 0 }

    init(validation: Bool, beforeResume: (CoreProcessIdentity) throws -> Void,
         didExit: @escaping @Sendable () -> Void) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw HelperFailure.refused("Cannot create the in-memory configuration pipe.") }
        var succeeded = false
        defer { close(descriptors[0]); if !succeeded { close(descriptors[1]) } }
        input = descriptors[1]
        guard fcntl(input, F_SETFL, O_NONBLOCK) == 0,
              fcntl(input, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HelperFailure.refused("Cannot make the configuration pipe bounded and private.")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw HelperFailure.refused("Cannot prepare core process isolation.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw HelperFailure.refused("Cannot prepare core process isolation.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var empty = sigset_t()
        sigemptyset(&empty)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE)
        let flags = POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setsigmask(&attributes, &empty) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw HelperFailure.refused("Cannot prepare core process isolation.")
        }
        let arguments = [HelperSecurity.binary.path] + (validation ? ["-t"] : []) + ["-d", HelperSecurity.state.path, "-f", "-"]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + HelperSecurity.state.path]
        var child: pid_t = 0
        let result = Self.withCStringArray(arguments) { argv in
            Self.withCStringArray(environment) { envp in
                posix_spawn(&child, HelperSecurity.binary.path, &actions, &attributes, argv, envp)
            }
        }
        guard result == 0 else { throw HelperFailure.refused("The pinned core could not be spawned.") }
        guard let identity = CoreProcessIdentity.read(child) else {
            kill(child, SIGKILL)
            var status: Int32 = 0; waitpid(child, &status, 0)
            throw HelperFailure.refused("Cannot authenticate the suspended core process.")
        }
        self.identity = identity
        do {
            try beforeResume(identity)
            let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
            source.setEventHandler(handler: didExit)
            source.resume()
            observation = source
            guard kill(child, SIGCONT) == 0 else { throw HelperFailure.refused("Cannot resume the recorded core process.") }
        } catch {
            kill(child, SIGKILL)
            var status: Int32 = 0; waitpid(child, &status, 0)
            observation?.cancel()
            // The deferred cleanup closes the write end; stop deinit from closing it a second time.
            input = -1
            throw error
        }
        succeeded = true
    }

    deinit { if input >= 0 { close(input) }; observation?.cancel() }

    func sendConfiguration(_ data: Data, timeout: TimeInterval = 8) throws {
        defer { close(input); input = -1 }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard running, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw HelperFailure.refused("The core did not consume its configuration within the deadline.")
                }
                var descriptor = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                let result = poll(&descriptor, 1, 100)
                if result < 0 && errno == EINTR { continue }
                guard result >= 0 else { throw HelperFailure.refused("The configuration pipe is unavailable.") }
                if result == 0 { continue }
                let count = write(input, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw HelperFailure.refused("The core closed its configuration pipe.") }
                offset += count
            }
        }
    }

    func terminate() throws {
        if try signalIfRunning(SIGTERM) {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while running, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
            _ = try signalIfRunning(SIGKILL)
            let forcedDeadline = ProcessInfo.processInfo.systemUptime + 2
            while running, ProcessInfo.processInfo.systemUptime < forcedDeadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !running else { throw HelperFailure.refused("The core did not exit; its recovery record was retained.") }
        }
        observation?.cancel()
    }

    private func signalIfRunning(_ signal: Int32) throws -> Bool {
        guard running else { return false }
        guard identity.stillMatches else {
            // Identity reads may fail for an exited child. Collect it, then return:
            // waitpid releases its PID, which must never be signalled afterwards.
            guard running else { return false }
            throw HelperFailure.refused("Core process identity changed; refusing to signal another process.")
        }
        // No waitpid occurs between the identity check and kill. Even if the
        // child exits here, its unreaped zombie keeps this PID from being reused.
        guard kill(pid, signal) == 0 || errno == ESRCH else {
            throw HelperFailure.refused("The core could not be signalled; its recovery record was retained.")
        }
        return true
    }

    private func collectExit() {
        guard exitStatus == nil else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { exitStatus = status }
        else if result < 0 && errno == ECHILD { exitStatus = -1 }
    }

    private static func withCStringArray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

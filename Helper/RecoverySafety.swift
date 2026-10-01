import Foundation
import Darwin

enum SafetyProcessRole: String, Codable { case helper, guardProcess }

struct SafetyProcessIdentity: Codable, Equatable {
    let role: SafetyProcessRole
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func read(_ role: SafetyProcessRole, pid: pid_t) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == 0, info.pbi_ruid == 0 else { return nil }
        let name = role == .helper ? "ClairRouteHelper" : "ClairRouteRecoveryGuard"
        let expected = "/Applications/ClairRoute.app/Contents/MacOS/" + name
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self) == expected else { return nil }
        return Self(role: role, pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    var fingerprint: RecoveryProcessFingerprint {
        RecoveryProcessFingerprint(pid: pid, startedSeconds: startedSeconds, startedMicroseconds: startedMicroseconds)
    }
    var stillMatches: Bool { fingerprint.matches(Self.read(role, pid: pid)?.fingerprint) }

    /// A stale PID is never signalled. Expired records still allow restoration of owned settings.
    func terminateIfMatching() throws {
        guard stillMatches else { return }
        kill(pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while stillMatches, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if stillMatches { kill(pid, SIGKILL) }
        let forcedDeadline = ProcessInfo.processInfo.systemUptime + 2
        while stillMatches, ProcessInfo.processInfo.systemUptime < forcedDeadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !stillMatches else { throw HelperFailure.refused("The recorded Helper did not exit; independent recovery remains pending.") }
    }
}

struct SafetyClock: Codable {
    let bootID: UInt64
    let continuousNanoseconds: UInt64

    static func now() throws -> Self {
        var boot = timeval()
        var length = MemoryLayout.size(ofValue: boot)
        guard sysctlbyname("kern.boottime", &boot, &length, nil, 0) == 0, boot.tv_sec > 0 else {
            throw HelperFailure.refused("Cannot establish the independent recovery clock.")
        }
        var basis = mach_timebase_info_data_t()
        guard mach_timebase_info(&basis) == KERN_SUCCESS, basis.denom > 0 else {
            throw HelperFailure.refused("Cannot establish the continuous recovery clock.")
        }
        let ticks = mach_continuous_time()
        let denominator = UInt64(basis.denom)
        let numerator = UInt64(basis.numer)
        let (whole, overflow) = (ticks / denominator).multipliedReportingOverflow(by: numerator)
        let (nanoseconds, additionOverflow) = whole.addingReportingOverflow((ticks % denominator) * numerator / denominator)
        guard !overflow, !additionOverflow else { throw HelperFailure.refused("The recovery clock overflowed.") }
        return Self(bootID: UInt64(boot.tv_sec), continuousNanoseconds: nanoseconds)
    }
}

struct TrialLease: Codable {
    let version: Int
    let sessionID: UUID
    let helper: SafetyProcessIdentity
    let deadline: RecoveryDeadline
}

struct GuardHeartbeat: Codable {
    let version: Int
    let identity: SafetyProcessIdentity
    let clock: SafetyClock
}

/// Installation readiness only. This record never authorizes a network mutation.
struct HelperReadiness: Codable {
    let version: Int
    let identity: SafetyProcessIdentity
    let clock: SafetyClock
    let ready: Bool
}

struct RecoveryMarker: Codable {
    let version: Int
    let sessionID: UUID
    let helper: SafetyProcessIdentity
}

enum SafetyFile {
    case lease, marker, heartbeat, helperReadiness
    var url: URL {
        switch self {
        case .lease: HelperSecurity.state.appendingPathComponent("trial-lease.json")
        case .marker: HelperSecurity.state.appendingPathComponent("recovery-in-progress.json")
        case .heartbeat: HelperSecurity.runtime.appendingPathComponent("recovery-guard.json")
        case .helperReadiness: HelperSecurity.runtime.appendingPathComponent("helper-ready.json")
        }
    }
    private var transient: Bool { self == .heartbeat || self == .helperReadiness }

    func load<T: Decodable>(_ type: T.Type) throws -> T? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw HelperFailure.refused("Cannot read independent recovery state.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 8_192 else {
            throw HelperFailure.refused("Independent recovery state has unsafe metadata.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 8_192 else { throw HelperFailure.refused("Independent recovery state is oversized.") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw HelperFailure.refused("Independent recovery state is invalid; automatic activation is blocked.") }
    }

    func save<T: Encodable>(_ record: T) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 8_192 else { throw HelperFailure.refused("Independent recovery state is oversized.") }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".safety-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HelperFailure.refused("Cannot prepare independent recovery state.") }
        defer { close(descriptor); unlink(temporary.path) }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        guard (transient || fsync(descriptor) == 0), rename(temporary.path, url.path) == 0 else {
            throw HelperFailure.refused("Cannot commit independent recovery state.")
        }
        if !transient { try syncDirectory() }
    }

    func remove() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw HelperFailure.refused("Cannot clear independent recovery state.") }
        if !transient { try syncDirectory() }
    }

    private func syncDirectory() throws {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperFailure.refused("Cannot sync independent recovery state.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw HelperFailure.refused("Cannot sync independent recovery state.") }
    }
}

final class SafetyLockToken {
    private var releaseBlock: (() -> Void)?
    init(_ release: @escaping () -> Void) { releaseBlock = release }
    func release() { releaseBlock?(); releaseBlock = nil }
    deinit { release() }
}

/// Helper uses its serial worker; Guard uses its own serial worker. flock arbitrates processes.
final class RecoverySafety {
    private let descriptor: Int32
    private var depth = 0

    init() throws {
        let url = HelperSecurity.state.appendingPathComponent("recovery.lock")
        descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HelperFailure.refused("Cannot open the independent recovery lock.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw HelperFailure.refused("The independent recovery lock is unsafe.")
        }
    }

    deinit { close(descriptor) }

    func lock(allowRecoveryMarker: Bool = false) throws -> SafetyLockToken {
        if !allowRecoveryMarker { try ensureNotRecovering() }
        if depth == 0, flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            throw HelperFailure.refused("Another protected recovery transaction is in progress.")
        }
        depth += 1
        let token = SafetyLockToken { [self] in
            depth -= 1
            if depth == 0 { flock(descriptor, LOCK_UN) }
        }
        if !allowRecoveryMarker { try ensureNotRecovering() }
        return token
    }

    func requireHelperStartupAllowed() throws {
        try ensureNotRecovering()
        guard try SafetyFile.lease.load(TrialLease.self) == nil else {
            throw HelperFailure.refused("The independent guard must finish the previous limited trial before the Helper restarts.")
        }
    }

    func ensureNotRecovering() throws {
        guard try SafetyFile.marker.load(RecoveryMarker.self) == nil else {
            throw HelperFailure.refused("Independent recovery is in progress; new network changes are blocked.")
        }
    }

    func armTrial(sessionID: UUID) throws {
        try ensureNotRecovering()
        guard try guardIsFresh() else {
            throw HelperFailure.refused("The independent recovery guard is unavailable. A limited network trial cannot start.")
        }
        let now = try SafetyClock.now()
        if let lease = try SafetyFile.lease.load(TrialLease.self) {
            guard lease.version == 1, lease.sessionID == sessionID,
                  lease.helper == SafetyProcessIdentity.read(.helper, pid: getpid()),
                  !lease.deadline.hasExpired(bootID: now.bootID, continuousNanoseconds: now.continuousNanoseconds) else {
                throw HelperFailure.refused("The limited trial is expired or belongs to another session.")
            }
            return // Reconfiguration cannot extend the fixed deadline.
        }
        guard let helper = SafetyProcessIdentity.read(.helper, pid: getpid()) else {
            throw HelperFailure.refused("Cannot establish the installed Helper's identity for independent recovery.")
        }
        let (deadline, overflow) = now.continuousNanoseconds.addingReportingOverflow(120_000_000_000)
        guard !overflow else { throw HelperFailure.refused("The trial deadline cannot be represented.") }
        try SafetyFile.lease.save(TrialLease(version: 1, sessionID: sessionID, helper: helper,
            deadline: RecoveryDeadline(bootID: now.bootID, continuousNanoseconds: deadline)))
    }

    func requireOrdinarySession() throws {
        guard try SafetyFile.lease.load(TrialLease.self) == nil else {
            throw HelperFailure.refused("Stop the limited trial before starting an ordinary session; its deadline cannot be removed by reconfiguration.")
        }
    }

    func finishOwnedTrial() throws {
        guard let lease = try SafetyFile.lease.load(TrialLease.self) else { return }
        guard lease.helper == SafetyProcessIdentity.read(.helper, pid: getpid()) else {
            throw HelperFailure.refused("A different Helper owns the pending limited trial.")
        }
        try SafetyFile.lease.remove()
    }

    func guardIsFresh() throws -> Bool {
        guard let heartbeat = try SafetyFile.heartbeat.load(GuardHeartbeat.self), heartbeat.version == 1,
              heartbeat.identity.role == .guardProcess, heartbeat.identity.stillMatches else { return false }
        let now = try SafetyClock.now()
        return now.bootID == heartbeat.clock.bootID &&
            now.continuousNanoseconds >= heartbeat.clock.continuousNanoseconds &&
            now.continuousNanoseconds - heartbeat.clock.continuousNanoseconds < 5_000_000_000
    }

    func trialNeedsRestoration() throws -> Bool {
        guard let lease = try SafetyFile.lease.load(TrialLease.self) else { return false }
        let now = try SafetyClock.now()
        if lease.deadline.hasExpired(bootID: now.bootID, continuousNanoseconds: now.continuousNanoseconds) { return true }
        return try !guardIsFresh()
    }
}

import Foundation
import Darwin
import os

/// A separate launchd job, with no IPC listener and no general command execution interface.
private final class RecoveryGuardRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.nano.ClairRoute.RecoveryGuard")
    private let identity: SafetyProcessIdentity
    private let clientRequirement: String
    private let safety: RecoverySafety
    private var timer: DispatchSourceTimer?
    private let log = Logger(subsystem: "local.nano.ClairRoute.RecoveryGuard", category: "recovery")

    init(clientRequirement: String) throws {
        guard let identity = SafetyProcessIdentity.read(.guardProcess, pid: getpid()) else {
            throw HelperFailure.refused("The independent guard must run from its fixed installed executable.")
        }
        self.identity = identity
        self.clientRequirement = clientRequirement
        safety = try RecoverySafety()
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    func stop() {
        queue.async { [self] in
            do {
                try recoverIfNecessary(force: true)
                try SafetyFile.heartbeat.remove()
                exit(EXIT_SUCCESS)
            } catch {
                log.error("Independent recovery could not finish before guard shutdown; recovery records were retained.")
                exit(EXIT_FAILURE)
            }
        }
    }

    private func tick() {
        do {
            try SafetyFile.heartbeat.save(GuardHeartbeat(version: 1, identity: identity, clock: try SafetyClock.now()))
            try recoverIfNecessary(force: false)
        } catch {
            // No config, endpoint, process metadata, or credentials enter logging.
            log.error("Independent recovery has pending work or unsafe state. Activation stays blocked while its marker exists.")
        }
    }

    private func recoverIfNecessary(force: Bool) throws {
        let lease = try SafetyFile.lease.load(TrialLease.self)
        var marker = try SafetyFile.marker.load(RecoveryMarker.self)
        // The idle guard never constructs NetworkSettingsManager or mutates network state.
        guard lease != nil || marker != nil else { return }
        if let lease {
            guard lease.version == 1, lease.helper.role == .helper else {
                throw HelperFailure.refused("The limited trial record is invalid.")
            }
            let now = try SafetyClock.now()
            let expired = lease.deadline.hasExpired(bootID: now.bootID, continuousNanoseconds: now.continuousNanoseconds)
            guard force || marker != nil || expired || !lease.helper.stillMatches else { return }
            if marker == nil {
                marker = RecoveryMarker(version: 1, sessionID: lease.sessionID, helper: lease.helper)
                try SafetyFile.marker.save(marker!)
            }
        }
        guard let marker, marker.version == 1, marker.helper.role == .helper else {
            throw HelperFailure.refused("The independent recovery marker is invalid.")
        }
        // New Helper instances refuse activation while a trial lease or recovery marker exists.
        // A matching existing Helper is stopped before touching either recovery journal.
        try marker.helper.terminateIfMatching()
        let transaction = try safety.lock(allowRecoveryMarker: true)
        defer { transaction.release() }
        var failure: Error?
        // Restore DNS/proxy first, while a surviving core can still answer on loopback.
        do {
            let network = try NetworkSettingsManager(stateDirectory: HelperSecurity.state)
            try network.recoverIfNeeded()
            if network.recoveryPending { throw HelperFailure.refused("Owned network settings are still pending recovery.") }
        } catch { failure = error }
        let core = CoreSupervisor(clientRequirement: clientRequirement, didExit: {})
        do { try core.recoverPreviousProcess() }
        catch { if failure == nil { failure = error } }
        if let failure { throw failure }
        try SafetyFile.lease.remove()
        try SafetyFile.marker.remove()
        log.notice("The independent limited trial rollback completed.")
    }
}

#if CLAIRROUTE_RECOVERY_GUARD
@main
enum ClairRouteRecoveryGuardMain {
    static func main() {
        guard CommandLine.arguments.count == 1 else { exit(EX_USAGE) }
        do {
            umask(0o077)
            signal(SIGPIPE, SIG_IGN)
            try HelperSecurity.prepareDirectories()
            let requirement = try HelperSecurity.requirement(key: "ClairRouteClientRequirement", identifier: AppConstants.appIdentifier)
            try HelperSecurity.verifyCode(URL(fileURLWithPath: "/Applications/ClairRoute.app"), requirement: requirement, directory: true)
            let runtime = try RecoveryGuardRuntime(clientRequirement: requirement)
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            termination.setEventHandler { runtime.stop() }
            interruption.setEventHandler { runtime.stop() }
            termination.resume(); interruption.resume()
            runtime.start()
            withExtendedLifetime((runtime, termination, interruption)) { dispatchMain() }
        } catch {
            Logger(subsystem: "local.nano.ClairRoute.RecoveryGuard", category: "startup")
                .error("Independent recovery guard refused activation due to invalid signing or installation prerequisites.")
            exit(EX_CONFIG)
        }
    }
}
#endif

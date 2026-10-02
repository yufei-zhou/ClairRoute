import Foundation
import CryptoKit
import Darwin

private struct CoreManifest: Decodable {
    let version: String
    let archiveSHA256: String
    let binarySHA256: String
    let signingRequirement: String
}

private struct GeoManifest: Decodable {
    let version: Int
    let geositeSHA256: String
}

enum CoreSelectionFailure: LocalizedError {
    case rollbackUnconfirmed

    var errorDescription: String? {
        "The previous proxy selection could not be confirmed after a failed node change."
    }
}

/// Access only on SessionCoordinator's serial queue. No caller-controlled executable or path.
final class CoreSupervisor {
    private var process: CoreProcess?
    private var processRecord: CoreProcessRecord?
    private var ownedInterfaceIndex: UInt32?
    private let controller = CoreController(socketPath: HelperSecurity.controller)
    private let clientRequirement: String
    private let didExit: @Sendable () -> Void
    private(set) var lastConfiguration: Data?
    var running: Bool { process?.running ?? (processRecord?.identity.stillMatches ?? false) }
    var pid: Int32? { running ? (process?.pid ?? processRecord?.identity.pid) : nil }
    var recoveryPending: Bool { ownedInterfaceIndex != nil || processRecord != nil }
    var ownsTUNInterface: Bool {
        guard let ownedInterfaceIndex else { return false }
        return if_nametoindex(AppConstants.tunInterfaceName) == ownedInterfaceIndex
    }

    init(clientRequirement: String, didExit: @escaping @Sendable () -> Void) {
        self.clientRequirement = clientRequirement
        self.didExit = didExit
    }

    /// Inspect ownership without stopping a surviving DNS server. Restoration
    /// must release the system's loopback consumers before terminating the core.
    func adoptPreviousProcess() throws {
        guard process == nil, processRecord == nil,
              let record = try CoreProcessJournal.load() else { return }
        processRecord = record
        ownedInterfaceIndex = record.interfaceIndex
    }

    func recoverPreviousProcess() throws {
        try adoptPreviousProcess()
        guard let record = processRecord else { return }
        if record.identity.stillMatches {
            kill(record.identity.pid, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while record.identity.stillMatches, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if record.identity.stillMatches { kill(record.identity.pid, SIGKILL) }
            let forcedDeadline = ProcessInfo.processInfo.systemUptime + 2
            while record.identity.stillMatches, ProcessInfo.processInfo.systemUptime < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !record.identity.stillMatches else {
                throw HelperFailure.refused("A recorded core process did not terminate. Recovery remains pending.")
            }
        }
        try confirmInterfaceRemoved()
        try CoreProcessJournal.clear()
        processRecord = nil
        try removeStaleSocket()
    }

    private func verifyInstallation() throws {
        let app = URL(fileURLWithPath: "/Applications/ClairRoute.app", isDirectory: true)
        try HelperSecurity.verifyCode(app, requirement: clientRequirement, directory: true)
        let bundledManifest = app.appendingPathComponent("Contents/Resources/CoreManifest.json")
        try HelperSecurity.assertRootOwned(bundledManifest, directory: false)
        try HelperSecurity.assertRootOwned(HelperSecurity.manifest, directory: false)
        let trustedBytes = try Data(contentsOf: bundledManifest)
        let installedBytes = try Data(contentsOf: HelperSecurity.manifest)
        guard trustedBytes.count < 16_384, installedBytes == trustedBytes else {
            throw HelperFailure.refused("The installed core manifest differs from the signed application.")
        }
        let manifest = try JSONDecoder().decode(CoreManifest.self, from: trustedBytes)
        guard manifest.version == AppConstants.coreVersion,
              manifest.archiveSHA256 == HelperSecurity.expectedArchiveDigest,
              manifest.binarySHA256.count == 64,
              manifest.signingRequirement.contains("certificate leaf"),
              manifest.signingRequirement.contains("local.nano.ClairRoute.Core") else {
            throw HelperFailure.refused("The core manifest does not match this pinned application release.")
        }
        try HelperSecurity.verifyCode(HelperSecurity.binary, requirement: manifest.signingRequirement)
        let bytes = try Data(contentsOf: HelperSecurity.binary, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.binarySHA256 else {
            throw HelperFailure.refused("The installed core SHA256 does not match the signed manifest.")
        }
        let bundledGeo = app.appendingPathComponent("Contents/Resources/GeoManifest.json")
        let installedGeo = HelperSecurity.root.appendingPathComponent("GeoManifest.json")
        let geosite = HelperSecurity.state.appendingPathComponent("geosite.dat")
        try HelperSecurity.assertRootOwned(bundledGeo, directory: false)
        try HelperSecurity.assertRootOwned(installedGeo, directory: false)
        try HelperSecurity.assertRootOwned(geosite, directory: false)
        let trustedGeoBytes = try Data(contentsOf: bundledGeo)
        guard trustedGeoBytes.count <= 16_384,
              try Data(contentsOf: installedGeo) == trustedGeoBytes else {
            throw HelperFailure.refused("The installed GEOSITE manifest differs from the signed application.")
        }
        let geoManifest = try JSONDecoder().decode(GeoManifest.self, from: trustedGeoBytes)
        guard geoManifest.version == 1, geoManifest.geositeSHA256.count == 64 else {
            throw HelperFailure.refused("The bundled GEOSITE manifest is invalid.")
        }
        let geoBytes = try Data(contentsOf: geosite, options: .mappedIfSafe)
        let geoDigest = SHA256.hash(data: geoBytes).map { String(format: "%02x", $0) }.joined()
        guard geoDigest == geoManifest.geositeSHA256 else {
            throw HelperFailure.refused("The installed GEOSITE database SHA256 does not match the signed manifest.")
        }
    }

    func preflight(_ configuration: Data) throws {
        try verifyInstallation()
        guard configuration.count <= AppConstants.maximumMessageBytes else {
            throw HelperFailure.refused("The generated configuration exceeds the supported size.")
        }
        let check = try CoreProcess(validation: true, beforeResume: { _ in }, didExit: {})
        do {
            try check.sendConfiguration(configuration)
        } catch {
            try? check.terminate()
            throw HelperFailure.refused("The core could not read its in-memory configuration.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while check.running, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !check.running else {
            try check.terminate()
            throw HelperFailure.refused("Core configuration validation timed out; network settings were not applied.")
        }
        guard check.succeeded else {
            // Core diagnostics can contain supplied credentials. Never forward raw output.
            throw HelperFailure.refused("The pinned core rejected the generated configuration. Credentials and raw core output are hidden.")
        }
    }

    func start(_ configuration: Data, tunEnabled: Bool, mode: OutboundMode) throws {
        guard !running else { throw HelperFailure.refused("The core is already running.") }
        try verifyInstallation()
        if tunEnabled, if_nametoindex(AppConstants.tunInterfaceName) != 0 {
            throw HelperFailure.refused("The reserved ClairRoute TUN interface is already in use. Stop the conflicting session first.")
        }
        try removeStaleSocket()
        let child = try CoreProcess(validation: false, beforeResume: { [self] identity in
            let record = CoreProcessRecord(version: 1, identity: identity, interfaceIndex: nil)
            try CoreProcessJournal.save(record)
            processRecord = record
        }, didExit: didExit)
        process = child
        do {
            try child.sendConfiguration(configuration)
            try waitForHealth(tunEnabled: tunEnabled, mode: mode)
            lastConfiguration = configuration
        } catch {
            if tunEnabled { try? captureOwnedInterface() }
            try? stop()
            throw error
        }
    }

    func reload(_ configuration: Data, tunEnabled: Bool, mode: OutboundMode) throws {
        guard running else { throw HelperFailure.refused("The core is not running.") }
        if tunEnabled, ownedInterfaceIndex == nil,
           if_nametoindex(AppConstants.tunInterfaceName) != 0 {
            throw HelperFailure.refused("Another session owns the reserved TUN interface.")
        }
        try controller.reload(configuration: configuration)
        try waitForHealth(tunEnabled: tunEnabled, mode: mode)
        if !tunEnabled { try confirmInterfaceRemoved() }
        lastConfiguration = configuration
    }

    func ensureHealthy(tunEnabled: Bool, mode: OutboundMode) throws {
        guard running else { throw HelperFailure.refused("The core exited unexpectedly.") }
        try controller.health()
        let snapshot = try controller.snapshot()
        guard snapshot.mode.lowercased() == mode.rawValue,
              snapshot.mixedPort == AppConstants.mixedPort,
              snapshot.tunEnabled == tunEnabled else {
            throw HelperFailure.refused("The core state differs from the requested proxy mode.")
        }
        if tunEnabled {
            guard let index = ownedInterfaceIndex,
                  if_nametoindex(AppConstants.tunInterfaceName) == index else {
                throw HelperFailure.refused("The owned TUN interface is unavailable.")
            }
        }
    }

    func connections() throws -> [ConnectionSnapshot] {
        guard running else { throw HelperFailure.refused("The core is not running.") }
        return try controller.connections()
    }

    func proxies(allowedNames: Set<String>) throws -> [ProxySnapshot] {
        guard running else { throw HelperFailure.refused("The core is not running.") }
        return try controller.proxies(allowedNames: allowedNames)
    }

    func delay(node: String) throws -> Int {
        guard running else { throw HelperFailure.refused("The core is not running.") }
        return try controller.delay(node: node)
    }

    func select(node: String, allowedNames: Set<String>) throws {
        guard running, allowedNames.contains(node) else {
            throw HelperFailure.refused("The selected node is not part of this validated session.")
        }
        let inspectedNames = allowedNames.union(["PROXY"])
        func currentSelection() throws -> String {
            let result = try controller.proxies(allowedNames: inspectedNames)
            guard let selected = result.first(where: { $0.name == "PROXY" })?.selected,
                  allowedNames.contains(selected) else {
                throw HelperFailure.refused("The core did not confirm a valid current proxy selection.")
            }
            return selected
        }
        // Read before mutation: if this fails, neither the core nor the desired
        // profile changes. Even a failed PUT may have applied before disconnecting.
        let previous = try currentSelection()
        guard previous != node else { return }
        do {
            try controller.selectProxy(node: node)
            guard try currentSelection() == node else {
                throw HelperFailure.refused("The core did not confirm the selected node.")
            }
        } catch {
            let selectionError = error
            do {
                try controller.selectProxy(node: previous)
                guard try currentSelection() == previous else {
                    throw CoreSelectionFailure.rollbackUnconfirmed
                }
            } catch { throw CoreSelectionFailure.rollbackUnconfirmed }
            throw selectionError
        }
    }

    func stop() throws {
        if let child = process { try child.terminate() }
        else { try recoverPreviousProcess() }
        process = nil
        lastConfiguration = nil
        try confirmInterfaceRemoved()
        try CoreProcessJournal.clear()
        processRecord = nil
        try removeStaleSocket()
    }

    private func waitForHealth(tunEnabled: Bool, mode: OutboundMode) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        repeat {
            guard running else { throw HelperFailure.refused("The core stopped during startup.") }
            if tunEnabled { try captureOwnedInterface() }
            do {
                try ensureHealthy(tunEnabled: tunEnabled, mode: mode)
                return
            } catch {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                Thread.sleep(forTimeInterval: 0.15)
            }
        } while true
        throw HelperFailure.refused("The core did not become healthy within the startup deadline.")
    }

    private func captureOwnedInterface() throws {
        let index = if_nametoindex(AppConstants.tunInterfaceName)
        // The core may recreate its fixed interface during a successful reconfiguration.
        if index != 0, ownedInterfaceIndex != index {
            ownedInterfaceIndex = index
            if var record = processRecord {
                record.interfaceIndex = index
                try CoreProcessJournal.save(record)
                processRecord = record
            }
        }
    }

    private func confirmInterfaceRemoved() throws {
        guard let owned = ownedInterfaceIndex else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while if_nametoindex(AppConstants.tunInterfaceName) == owned,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard if_nametoindex(AppConstants.tunInterfaceName) != owned else {
            throw HelperFailure.refused("The owned TUN interface remains after shutdown. Automatic cleanup is incomplete; no unrelated routes were changed.")
        }
        // Routes bound to a destroyed interface are removed by the kernel. Never flush routes.
        ownedInterfaceIndex = nil
    }

    private func removeStaleSocket() throws {
        var info = stat()
        if lstat(HelperSecurity.controller, &info) != 0 {
            guard errno == ENOENT else { throw HelperFailure.refused("Cannot inspect the controller socket.") }
            return
        }
        guard info.st_uid == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw HelperFailure.refused("An unexpected object occupies the protected controller path.")
        }
        guard unlink(HelperSecurity.controller) == 0 else {
            throw HelperFailure.refused("Cannot remove the previous controller socket.")
        }
    }
}

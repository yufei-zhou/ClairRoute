import Foundation
import Darwin

private final class ReplyDelivery: @unchecked Sendable {
    let block: (Data) -> Void
    init(_ block: @escaping (Data) -> Void) { self.block = block }
    func send(_ reply: ServiceReply) {
        // All reply values are generated here; raw request/core output is never reflected.
        if let data = try? JSONEncoder().encode(reply) { block(data) }
        else { block(Data("{\"error\":\"Cannot encode Helper status.\"}".utf8)) }
    }
    func send(_ reply: InspectionReply) {
        if let data = try? JSONEncoder().encode(reply), data.count <= AppConstants.maximumMessageBytes { block(data) }
        else { block(Data("{\"error\":\"Inspection response exceeds the supported size.\"}".utf8)) }
    }
}

/// Every mutable session, process, and network object is confined to this queue.
final class SessionCoordinator: @unchecked Sendable {
    private let worker = DispatchQueue(label: "local.nano.ClairRoute.Helper.session")
    private let network: NetworkSettingsManager
    private let safety: RecoverySafety
    private let clientRequirement: String
    private lazy var core = CoreSupervisor(clientRequirement: clientRequirement) { [weak self] in
        self?.enqueueCoreExit()
    }
    private var status = ServiceStatus.idle
    private var owner: AuthenticatedClient?
    private var desired: ApplyRequest?
    private var ownerExit: DispatchSourceProcess?
    private var leaseTimer: DispatchSourceTimer?
    private var power: PowerEvents?
    private var powerReady = false
    private var unresolvedPreviousInterface = false
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var sleeping = false
    private var wakeGraceUntil: TimeInterval = 0
    private var networkWork: DispatchWorkItem?
    private var reconciliationPending = false
    private var reconciliationAttempts = 0
    private var selectedNode: String?
    private var recoveryBootstrapPending = true
    private var restorationRetry: DispatchWorkItem?
    private var restorationRetryID: UUID?
    private var restorationAttempts = 0
    private var shuttingDown = false

    init(clientRequirement: String) throws {
        self.clientRequirement = clientRequirement
        safety = try RecoverySafety()
        let transaction = try safety.lock()
        defer { transaction.release() }
        try safety.requireHelperStartupAllowed()
        network = try NetworkSettingsManager(stateDirectory: HelperSecurity.state)
    }

    func activate() {
        worker.async { [self] in
            // Startup uses the same retryable recovery path as a disconnected
            // GUI. A transient lock/DNS failure must not disable its watchdog.
            network.startObserving { [weak self] in self?.networkDidChange() }
            power = PowerEvents { [weak self] event in self?.powerChanged(event) }
            powerReady = power?.start() == true
            _ = restore(reason: "Previous owned network settings were restored.")
            if !powerReady || !network.observationAvailable {
                status.phase = .needsAttention
                let message = "Network or sleep/wake monitoring could not be registered. Proxying is disabled until both monitors are available."
                status.message = status.recoveryPending ? status.message + " " + message : message
            }
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                self?.checkLease()
                self?.publishInstallationReadiness()
            }
            leaseTimer = timer
            timer.resume()
            publishInstallationReadiness()
        }
    }

    func apply(_ data: Data, client: AuthenticatedClient, reply: @escaping (Data) -> Void) {
        let delivery = ReplyDelivery(reply)
        worker.async { [self] in
            do {
                guard !shuttingDown else { throw HelperFailure.refused("The Helper is shutting down.") }
                try client.requireConsoleOwner()
                try requireOwner(client)
                let transaction = try safety.lock()
                defer { transaction.release() }
                let request: ApplyRequest = try decode(data)
                if let desired {
                    guard desired.sessionID == request.sessionID,
                          request.generation > desired.generation else {
                        throw HelperFailure.refused("The session or configuration generation is stale. Reconnect before applying again.")
                    }
                    guard (desired.trialMode == true) == (request.trialMode == true) else {
                        throw HelperFailure.refused("Stop the current session before switching between an ordinary session and a limited trial.")
                    }
                }
                if !request.tunEnabled && !request.systemProxyEnabled {
                    let failure = restore(reason: "Proxying is disabled.")
                    delivery.send(failure.map { .failure($0, status: status) } ?? .success(status))
                    return
                }
                guard !status.recoveryPending else {
                    throw HelperFailure.refused("A previous restoration remains incomplete. Use Stop / Restore before enabling proxying.")
                }
                guard powerReady && network.observationAvailable else {
                    throw HelperFailure.refused("Network or system sleep/wake monitoring is unavailable. Restart the Helper before enabling proxying.")
                }
                try ConfigurationBuilder.validate(request.profile)
                guard !request.profile.nodes.isEmpty else {
                    throw HelperFailure.refused("Add a proxy node before enabling proxying.")
                }
                if request.tunEnabled, desired?.tunEnabled != true,
                   let conflict = network.conflictDescription() {
                    throw HelperFailure.refused(conflict)
                }
                let configuration = try ConfigurationBuilder.makeConfiguration(
                    profile: request.profile, tunEnabled: request.tunEnabled,
                    controllerPath: HelperSecurity.controller)
                let previous = desired
                let previousConfiguration = core.lastConfiguration
                var mutationStarted = false
                status.phase = previous == nil ? .preparing : .reconfiguring
                do {
                    try core.preflight(configuration)
                    mutationStarted = true
                    if request.trialMode == true { try safety.armTrial(sessionID: request.sessionID) }
                    else { try safety.requireOrdinarySession() }
                    try network.prepare(sessionID: request.sessionID)
                    if owner == nil { bindOwner(client) }
                    status.phase = previous == nil ? .starting : .reconfiguring
                    if let previous,
                       (previous.tunEnabled && !request.tunEnabled) ||
                       (previous.systemProxyEnabled && !request.systemProxyEnabled) {
                        // Restore a removed listener's DNS/proxy consumers while it is alive.
                        try network.apply(tunEnabled: previous.tunEnabled && request.tunEnabled,
                            systemProxyEnabled: previous.systemProxyEnabled && request.systemProxyEnabled)
                    }
                    if core.running { try core.reload(configuration, tunEnabled: request.tunEnabled, mode: request.profile.mode) }
                    else { try core.start(configuration, tunEnabled: request.tunEnabled, mode: request.profile.mode) }
                    try restoreSelection(in: request.profile)
                    try safety.ensureNotRecovering()
                    try network.apply(tunEnabled: request.tunEnabled, systemProxyEnabled: request.systemProxyEnabled)
                    desired = request
                    lastHeartbeat = ProcessInfo.processInfo.systemUptime
                    reconciliationAttempts = 0
                    setActive(request, message: request.trialMode == true
                        ? "A fixed 120-second trial is active. The independent guard will restore networking automatically."
                        : "Proxy session is active.")
                    delivery.send(.success(status))
                } catch {
                    let originalError = safeMessage(error)
                    if !mutationStarted {
                        if let previous { setActive(previous, message: "The proposed configuration was rejected before changing the active session.") }
                        else { status = .idle }
                        delivery.send(.failure(originalError, status: status))
                        return
                    }
                    if let previous, let previousConfiguration {
                        do {
                            if core.running { try core.reload(previousConfiguration, tunEnabled: previous.tunEnabled, mode: previous.profile.mode) }
                            else { try core.start(previousConfiguration, tunEnabled: previous.tunEnabled, mode: previous.profile.mode) }
                            try restoreSelection(in: previous.profile)
                            try network.apply(tunEnabled: previous.tunEnabled, systemProxyEnabled: previous.systemProxyEnabled)
                            desired = previous
                            lastHeartbeat = ProcessInfo.processInfo.systemUptime
                            setActive(previous, message: "The previous configuration was restored after an apply failure.")
                            delivery.send(.failure(originalError + " The previous configuration was restored.", status: status))
                        } catch {
                            let restoration = restore(reason: "Configuration rollback failed; proxying was stopped.")
                            delivery.send(.failure(originalError + " Rollback failed." + (restoration.map { " " + $0 } ?? " Network settings were restored."), status: status))
                        }
                    } else {
                        let restoration = restore(reason: "Startup failed; proxying was stopped.")
                        delivery.send(.failure(originalError + (restoration.map { " " + $0 } ?? " Network settings were restored."), status: status))
                    }
                }
            } catch {
                delivery.send(.failure(safeMessage(error), status: status))
            }
        }
    }

    func stop(client: AuthenticatedClient, reply: @escaping (Data) -> Void) {
        let delivery = ReplyDelivery(reply)
        worker.async { [self] in
            do {
                try client.requireConsoleOwner()
                try requireOwner(client)
                let failure = restore(reason: "Proxying stopped and owned network settings were restored.")
                delivery.send(failure.map { .failure($0, status: status) } ?? .success(status))
            } catch { delivery.send(.failure(safeMessage(error), status: status)) }
        }
    }

    func readStatus(client: AuthenticatedClient, reply: @escaping (Data) -> Void) {
        let delivery = ReplyDelivery(reply)
        worker.async { [self] in
            do { try client.requireConsoleOwner(); delivery.send(.success(status)) }
            catch { delivery.send(.failure(safeMessage(error))) }
        }
    }

    func heartbeat(_ data: Data, client: AuthenticatedClient, reply: @escaping (Data) -> Void) {
        let delivery = ReplyDelivery(reply)
        worker.async { [self] in
            do {
                try client.requireConsoleOwner()
                let request: HeartbeatRequest = try decode(data)
                guard owner == client, desired?.sessionID == request.sessionID else {
                    throw HelperFailure.refused("There is no active session owned by this connection.")
                }
                lastHeartbeat = ProcessInfo.processInfo.systemUptime
                delivery.send(.success(status))
            } catch { delivery.send(.failure(safeMessage(error), status: status)) }
        }
    }

    func inspect(_ data: Data, client: AuthenticatedClient, reply: @escaping (Data) -> Void) {
        let delivery = ReplyDelivery(reply)
        worker.async { [self] in
            do {
                try client.requireConsoleOwner()
                let request: InspectionRequest = try decode(data)
                guard owner == client, let desired, desired.sessionID == request.sessionID,
                      status.phase == .active, core.running else {
                    throw HelperFailure.refused("Inspection requires the authenticated owner of an active proxy session.")
                }
                let transaction = try safety.lock()
                defer { transaction.release() }
                let nodes = Set(desired.profile.nodes.map(\.name))
                // The automatic group may be PROXY's current member, but is never a manual target.
                let policies = nodes.union([ConfigurationBuilder.autoPolicy])
                switch request.operation {
                case .connections:
                    guard request.node == nil else { throw HelperFailure.refused("This inspection operation does not accept a node.") }
                    delivery.send(InspectionReply(connections: try core.connections()))
                case .proxies:
                    guard request.node == nil else { throw HelperFailure.refused("This inspection operation does not accept a node.") }
                    delivery.send(InspectionReply(proxies: try core.proxies(allowedNames: policies.union(["PROXY", "GLOBAL", "DIRECT", "REJECT"]))))
                case .delay:
                    guard let node = request.node, nodes.contains(node) else {
                        throw HelperFailure.refused("Delay checks are limited to nodes in this validated session.")
                    }
                    delivery.send(InspectionReply(delayMilliseconds: try core.delay(node: node)))
                case .select:
                    guard let node = request.node, nodes.contains(node) else {
                        throw HelperFailure.refused("Node selection is limited to the PROXY group of this validated session.")
                    }
                    try core.select(node: node, allowedNames: policies)
                    selectedNode = node
                    self.desired?.profile.selectedNode = node
                    // A manual choice wins over automatic selection until the next apply.
                    self.desired?.profile.autoSelect.enabled = false
                    status.message = "The selected proxy node was confirmed by the core."
                    delivery.send(InspectionReply(status: status))
                }
            } catch {
                let message = safeMessage(error)
                if error is CoreSelectionFailure {
                    let restoration = restore(reason: "Node selection rollback could not be confirmed; proxying was stopped.")
                    delivery.send(InspectionReply(status: status, error: message +
                        (restoration.map { " " + $0 } ?? " Network settings were restored.")))
                } else {
                    delivery.send(InspectionReply(status: status, error: message))
                }
            }
        }
    }

    func disconnected(_ client: AuthenticatedClient) {
        worker.async { [self] in
            guard owner == client else { return }
            _ = restore(reason: "The GUI disconnected; its network session was restored.")
        }
    }

    func shutdown() {
        worker.async { [self] in
            shuttingDown = true
            cancelRestorationRetry()
            leaseTimer?.cancel()
            try? SafetyFile.helperReadiness.remove()
            _ = restore(reason: "The Helper is shutting down.")
            network.stopObserving()
            power?.stop()
            exit(status.recoveryPending ? EXIT_FAILURE : EXIT_SUCCESS)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= AppConstants.maximumMessageBytes else {
            throw HelperFailure.refused("The Helper request has an invalid size.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw HelperFailure.refused("The Helper request is malformed.") }
    }

    private func requireOwner(_ client: AuthenticatedClient) throws {
        if let owner, owner != client {
            throw HelperFailure.refused("Another authenticated GUI connection owns the current proxy session.")
        }
    }

    private func bindOwner(_ client: AuthenticatedClient) {
        owner = client
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        let source = DispatchSource.makeProcessSource(identifier: client.pid, eventMask: .exit, queue: worker)
        source.setEventHandler { [weak self] in
            guard let self, self.owner == client else { return }
            _ = self.restore(reason: "The GUI exited; its network session was restored.")
        }
        ownerExit = source
        source.resume()
    }

    private func restore(reason: String) -> String? {
        // Restoration has its own lifetime. Detach the GUI and cancel active
        // reconciliation even if the safety lock cannot currently be acquired.
        // Neither a late heartbeat nor a wake event may re-enable this session.
        desired = nil
        selectedNode = nil
        owner = nil
        ownerExit?.cancel()
        ownerExit = nil
        networkWork?.cancel()
        networkWork = nil
        reconciliationPending = false
        cancelRestorationRetry()
        let transaction: SafetyLockToken
        do { transaction = try safety.lock() }
        catch {
            finishRestorationAttempt(failures: [safeMessage(error)], reason: reason)
            return status.message
        }
        defer { transaction.release() }
        status.phase = .restoring
        var failures: [String] = []
        if recoveryBootstrapPending {
            do {
                // Reading the journal first exposes a surviving core to status
                // and keeps it serving DNS when restoration must be retried.
                try core.adoptPreviousProcess()
                unresolvedPreviousInterface = if_nametoindex(AppConstants.tunInterfaceName) != 0 && !core.ownsTUNInterface
                recoveryBootstrapPending = false
            } catch { failures.append("The previous core recovery record could not be safely loaded.") }
        }
        var restored = false
        for attempt in 0..<3 where !restored {
            do { try network.recoverIfNeeded(); restored = true }
            catch { if attempt < 2 { Thread.sleep(forTimeInterval: 0.5) } }
        }
        if !restored { failures.append("DNS or system proxy restoration is incomplete.") }
        // Keep both DNS and proxy listeners available while any owned consumers
        // still depend on them. The independent retry no longer needs a GUI.
        if network.recoveryPending && core.running {
            failures.append("Owned DNS or system proxy settings still depend on ClairRoute, so the core was kept running.")
        } else if !recoveryBootstrapPending {
            do { try core.stop() }
            catch { failures.append(safeMessage(error)) }
        }
        if unresolvedPreviousInterface {
            if if_nametoindex(AppConstants.tunInterfaceName) == 0 { unresolvedPreviousInterface = false }
            else { failures.append("A previous or conflicting TUN interface is still present; its ownership is unknown and it was not deleted.") }
        }
        if failures.isEmpty && !network.recoveryPending && !core.recoveryPending {
            do { try safety.finishOwnedTrial() }
            catch { failures.append(safeMessage(error)) }
        }
        finishRestorationAttempt(failures: failures, reason: reason)
        return status.recoveryPending ? status.message : nil
    }

    private func finishRestorationAttempt(failures: [String], reason: String) {
        let pending = recoveryBootstrapPending || network.recoveryPending || core.recoveryPending || !failures.isEmpty
        let completedMessage = network.lastRestorationNotice.map { reason + " " + $0 } ?? reason
        let pendingMessage = failures.isEmpty ? "Restoration is still pending." : failures.joined(separator: " ")
        status = ServiceStatus(phase: pending ? .needsAttention : .idle,
            tunEnabled: core.running && core.ownsTUNInterface,
            systemProxyEnabled: network.ownsSystemProxy,
            coreRunning: core.running, corePID: core.pid,
            message: pending ? pendingMessage + (shuttingDown ? " Recovery records were retained." : " Restoration will retry automatically.") : completedMessage,
            recoveryPending: pending)
        if pending { scheduleRestorationRetry() }
        else {
            restorationAttempts = 0
            if !powerReady || !network.observationAvailable {
                status.phase = .needsAttention
                status.message = completedMessage + " Proxying remains disabled until network and sleep/wake monitoring are available."
            }
        }
    }

    private func cancelRestorationRetry() {
        restorationRetry?.cancel()
        restorationRetry = nil
        restorationRetryID = nil
    }

    private func scheduleRestorationRetry(immediate: Bool = false) {
        guard status.recoveryPending, !sleeping, !shuttingDown else { return }
        if restorationRetry != nil && !immediate { return }
        cancelRestorationRetry()
        let delays: [TimeInterval] = [2, 5, 10, 20, 30]
        let delay = immediate ? 0 : delays[min(restorationAttempts, delays.count - 1)]
        restorationAttempts = min(restorationAttempts + 1, delays.count - 1)
        let id = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.restorationRetryID == id else { return }
            self.restorationRetry = nil
            self.restorationRetryID = nil
            guard self.status.recoveryPending, !self.sleeping, !self.shuttingDown else { return }
            _ = self.restore(reason: "Pending network restoration completed.")
            self.publishInstallationReadiness()
        }
        restorationRetryID = id
        restorationRetry = item
        worker.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func setActive(_ request: ApplyRequest, message: String) {
        status = ServiceStatus(phase: .active, tunEnabled: request.tunEnabled,
            systemProxyEnabled: request.systemProxyEnabled, coreRunning: core.running,
            corePID: core.pid, generation: request.generation, message: message,
            coreVersion: AppConstants.coreVersion, recoveryPending: false)
    }

    private func checkLease() {
        guard let owner, desired != nil, !sleeping,
              ProcessInfo.processInfo.systemUptime > wakeGraceUntil else { return }
        do {
            try safety.ensureNotRecovering()
            if try safety.trialNeedsRestoration() {
                _ = restore(reason: "The limited trial expired or its independent guard became unavailable; network settings were restored.")
                return
            }
        } catch {
            _ = restore(reason: "Independent recovery state requires attention.")
            return
        }
        if (try? owner.requireConsoleOwner()) == nil ||
            ProcessInfo.processInfo.systemUptime - lastHeartbeat > 25 {
            _ = restore(reason: "The GUI watchdog lease expired; network settings were restored.")
        }
    }

    private func publishInstallationReadiness() {
        guard let identity = SafetyProcessIdentity.read(.helper, pid: getpid()),
              let clock = try? SafetyClock.now() else { return }
        let ready = powerReady && network.observationAvailable && !status.recoveryPending &&
            status.phase == .idle && !core.running && desired == nil
        // A failed write cannot claim installation success: the installer requires
        // a fresh record from this exact live PID and process creation time.
        try? SafetyFile.helperReadiness.save(HelperReadiness(version: 1,
            identity: identity, clock: clock, ready: ready))
    }

    private func enqueueCoreExit() {
        worker.async { [self] in
            if status.recoveryPending {
                scheduleRestorationRetry(immediate: true)
                return
            }
            guard desired != nil, !core.running else { return }
            _ = restore(reason: "The core exited unexpectedly; network settings were restored.")
        }
    }

    private func networkDidChange() {
        worker.async { [self] in scheduleReconciliation() }
    }

    private func scheduleReconciliation() {
        if status.recoveryPending {
            scheduleRestorationRetry()
            return
        }
        guard desired != nil else { return }
        reconciliationPending = true
        guard !sleeping else { return }
        networkWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        networkWork = item
        worker.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func reconcile() {
        guard !status.recoveryPending, !shuttingDown,
              let request = desired, let configuration = core.lastConfiguration, !sleeping else { return }
        reconciliationPending = false
        do {
            let transaction = try safety.lock()
            defer { transaction.release() }
            try owner?.requireConsoleOwner()
            if request.tunEnabled, let conflict = network.conflictDescription() {
                throw HelperFailure.refused(conflict)
            }
            // A configuration reload lets the pinned core re-detect its physical egress.
            try core.reload(configuration, tunEnabled: request.tunEnabled, mode: request.profile.mode)
            try restoreSelection(in: request.profile)
            try network.apply(tunEnabled: request.tunEnabled, systemProxyEnabled: request.systemProxyEnabled)
            try core.ensureHealthy(tunEnabled: request.tunEnabled, mode: request.profile.mode)
            reconciliationAttempts = 0
            setActive(request, message: "Proxy state was reconciled after a network or wake event.")
        } catch {
            reconciliationAttempts += 1
            if reconciliationAttempts < 2 {
                status.phase = .reconfiguring
                status.message = safeMessage(error) + " A bounded recovery retry is pending."
                scheduleReconciliation()
            } else {
                _ = restore(reason: "Network recovery failed twice; proxying was stopped. " + safeMessage(error))
            }
        }
    }

    private func powerChanged(_ event: PowerEvents.Event) {
        worker.async { [self] in
            switch event {
            case .willSleep:
                sleeping = true
                networkWork?.cancel()
                cancelRestorationRetry()
            case .didWake:
                sleeping = false
                wakeGraceUntil = ProcessInfo.processInfo.systemUptime + 30
                lastHeartbeat = ProcessInfo.processInfo.systemUptime
                if status.recoveryPending { scheduleRestorationRetry(immediate: true) }
                else { scheduleReconciliation() }
            }
        }
    }

    private func safeMessage(_ error: Error) -> String {
        // Only our own errors are guaranteed not to contain user config or core output.
        if let known = error as? HelperFailure { return known.localizedDescription }
        if let known = error as? NetworkSettingsError { return known.localizedDescription }
        if let known = error as? CoreControllerError { return known.localizedDescription }
        if let known = error as? CoreSelectionFailure { return known.localizedDescription }
        if let known = error as? ConfigurationError { return known.localizedDescription }
        return "A protected network/configuration operation failed. Proxy credentials are omitted from diagnostics."
    }

    private func restoreSelection(in profile: RuntimeProfile) throws {
        let names = Set(profile.nodes.map(\.name))
        // A reload starts PROXY at the automatic group when the configuration has one.
        let policies = names.union([ConfigurationBuilder.autoPolicy])
        if !ConfigurationBuilder.autoSelectCandidates(profile).isEmpty {
            try core.select(node: ConfigurationBuilder.autoPolicy, allowedNames: policies)
            return
        }
        guard let selectedNode = profile.selectedNode ?? selectedNode else { return }
        if names.contains(selectedNode) {
            try core.select(node: selectedNode, allowedNames: policies)
            self.selectedNode = selectedNode
        }
        else { self.selectedNode = nil }
    }
}

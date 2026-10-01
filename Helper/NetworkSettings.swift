import Darwin
import Foundation
import SystemConfiguration

enum NetworkSettingsError: LocalizedError {
    case rootRequired, unsafeStateDirectory, invalidJournal, missingSession, noNetworkServices
    case systemConfiguration(String, Int32)
    case journalIO(String, Int32)
    case externalChange(String)

    var errorDescription: String? {
        switch self {
        case .rootRequired: return "Network settings require the installed privileged helper."
        case .unsafeStateDirectory: return "The recovery directory is not a private, root-owned directory."
        case .invalidJournal: return "The network recovery journal is invalid; automatic activation is blocked."
        case .missingSession: return "Prepare an authenticated session before changing network settings."
        case .noNetworkServices: return "No enabled physical network service is available."
        case let .systemConfiguration(operation, code):
            return "SystemConfiguration could not \(operation) (error \(code))."
        case let .journalIO(operation, code): return "Could not \(operation) (POSIX error \(code))."
        case let .externalChange(service):
            return "Network settings for \(service) changed outside ClairRoute. Restore and activate again to use the new baseline."
        }
    }
}

/// All public methods, except the observation callback, are called on the helper's serial worker.
final class NetworkSettingsManager {
    private let store: NetworkJournalStore
    private var journal: NetworkJournal
    private var observation: NetworkObservation?
    private(set) var lastRestorationNotice: String?

    var recoveryPending: Bool { !journal.leases.isEmpty }
    var ownsDNS: Bool { journal.leases.values.contains { $0.protocolType == "DNS" } }
    var ownsSystemProxy: Bool { journal.leases.values.contains { $0.protocolType != "DNS" } }
    var observationAvailable: Bool { observation != nil }

    init(stateDirectory: URL) throws {
        store = try NetworkJournalStore(directory: stateDirectory)
        journal = try store.load()
    }

    func recoverIfNeeded() throws {
        if recoveryPending { try restoreAll() }
    }

    func prepare(sessionID: UUID) throws {
        if let owner = journal.sessionID, owner != sessionID, recoveryPending {
            throw NetworkSettingsError.missingSession
        }
        var next = journal
        next.sessionID = sessionID
        try store.save(next)
        journal = next
    }

    func apply(tunEnabled: Bool, systemProxyEnabled: Bool) throws {
        guard journal.sessionID != nil else { throw NetworkSettingsError.missingSession }
        try transact(tunEnabled: tunEnabled, systemProxyEnabled: systemProxyEnabled, endingSession: false)
    }

    func restoreAll() throws {
        try transact(tunEnabled: false, systemProxyEnabled: false, endingSession: true)
    }

    private struct Change {
        let service: SCNetworkService
        let type: CFString
        let configuration: [String: Any]?
        let enabled: Bool
        let removeProtocol: Bool
    }

    private func transact(tunEnabled: Bool, systemProxyEnabled: Bool, endingSession: Bool) throws {
        let prefs = try preferences()
        // Another app (e.g. System Settings) may hold the lock briefly; wait up to ~3 s.
        var locked = SCPreferencesLock(prefs, false)
        for _ in 0..<30 where !locked {
            Thread.sleep(forTimeInterval: 0.1)
            SCPreferencesSynchronize(prefs)
            locked = SCPreferencesLock(prefs, false)
        }
        guard locked else { throw scError("lock network preferences") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        let allServices = (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? []
        let all = allServices.reduce(into: [String: SCNetworkService]()) { services, service in
            let id = serviceID(service)
            if !id.isEmpty { services[id] = service }
        }
        let eligible = currentPhysicalServices(prefs)
        let desiredServiceIDs = Set(eligible.map(serviceID))
        if (tunEnabled || systemProxyEnabled) && eligible.isEmpty {
            throw NetworkSettingsError.noNetworkServices
        }

        var prepared = journal
        var released = Set<String>()
        var changes: [Change] = []
        var preserved: [String] = []
        for lease in journal.leases.values.sorted(by: { $0.key < $1.key }) {
            let keep = desiredServiceIDs.contains(lease.serviceID) &&
                (lease.protocolType == "DNS" ? tunEnabled : systemProxyEnabled)
            if keep { continue }
            guard let service = all[lease.serviceID] else {
                released.insert(lease.key)
                continue
            }
            let type = lease.protocolType as CFString
            guard let proto = SCNetworkServiceCopyProtocol(service, type) else {
                released.insert(lease.key)
                continue
            }
            var configuration = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            var preservesExternalChange = false
            // A proxy's enable/server/port form one setting. Restoring only the enable flag
            // could disable a server that another application just deliberately selected.
            for group in ownershipGroups(for: lease) {
                let stillOwned = try group.allSatisfy { key in
                    try lease.installed[key]?.matches(configuration[key]) ?? false
                }
                if stillOwned {
                    for key in group { configuration[key] = try lease.previous[key]?.decoded() }
                } else {
                    let alreadyRestored = try group.allSatisfy { key in
                        try lease.previous[key]?.matches(configuration[key]) ?? false
                    }
                    if !alreadyRestored {
                        preservesExternalChange = true
                        preserved.append(lease.serviceName + ": " + group.joined(separator: "/"))
                    }
                }
            }
            let enabled = SCNetworkProtocolGetEnabled(proto)
            // If someone disabled the protocol, preserve that external change.
            let restoredEnabled = preservesExternalChange ? enabled : (enabled ? lease.originallyEnabled : false)
            let remove = !lease.originallyPresent && configuration.isEmpty && enabled
            changes.append(Change(service: service, type: type,
                                  configuration: configuration.isEmpty && lease.originalConfigurationWasNil ? nil : configuration,
                                  enabled: restoredEnabled, removeProtocol: remove))
            released.insert(lease.key)
        }

        for service in eligible {
            let wanted: [(CFString, [String: Any])] =
                (tunEnabled ? [(kSCNetworkProtocolTypeDNS, dnsValues)] : []) +
                (systemProxyEnabled ? [(kSCNetworkProtocolTypeProxies, proxyValues)] : [])
            for (type, installed) in wanted {
                let id = serviceID(service)
                let key = id + ":" + (type as String)
                let proto = SCNetworkServiceCopyProtocol(service, type)
                let current = proto.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }
                if let lease = prepared.leases[key] {
                    guard let proto, SCNetworkProtocolGetEnabled(proto) else {
                        throw NetworkSettingsError.externalChange(lease.serviceName)
                    }
                    for (field, expected) in lease.installed where try !expected.matches(current?[field]) {
                        _ = field
                        throw NetworkSettingsError.externalChange(lease.serviceName)
                    }
                } else {
                    var observedKeys = Set(installed.keys)
                    if type == kSCNetworkProtocolTypeProxies {
                        observedKeys.formUnion(["ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"])
                    }
                    let previous = try Dictionary(uniqueKeysWithValues: observedKeys.map {
                        ($0, try NetworkValue(current?[$0]))
                    })
                    let expected = try Dictionary(uniqueKeysWithValues: observedKeys.map {
                        ($0, try NetworkValue(installed[$0] ?? current?[$0]))
                    })
                    prepared.leases[key] = NetworkProtocolLease(
                        serviceID: id, serviceName: serviceName(service), protocolType: type as String,
                        originallyPresent: proto != nil,
                        originallyEnabled: proto.map(SCNetworkProtocolGetEnabled) ?? false,
                        originalConfigurationWasNil: current == nil,
                        previous: previous, installed: expected)
                }
                var merged = current ?? [:]
                installed.forEach { merged[$0.key] = $0.value }
                if proto == nil || !NSDictionary(dictionary: current ?? [:]).isEqual(to: merged) ||
                    !(proto.map(SCNetworkProtocolGetEnabled) ?? false) {
                    changes.append(Change(service: service, type: type, configuration: merged,
                                          enabled: true, removeProtocol: false))
                }
            }
        }

        // Durable intent precedes any committed system change. On any failure the journal remains.
        try store.save(prepared)
        journal = prepared
        observation?.beginOwnChange()
        defer { observation?.endOwnChange() }
        if !changes.isEmpty {
            for change in changes {
                if change.removeProtocol {
                    guard SCNetworkServiceRemoveProtocolType(change.service, change.type) else {
                        throw scError("remove an owned network protocol")
                    }
                    continue
                }
                if SCNetworkServiceCopyProtocol(change.service, change.type) == nil {
                    guard SCNetworkServiceAddProtocolType(change.service, change.type) else {
                        throw scError("add a network protocol")
                    }
                }
                guard let proto = SCNetworkServiceCopyProtocol(change.service, change.type),
                      SCNetworkProtocolSetConfiguration(proto, change.configuration as CFDictionary?),
                      SCNetworkProtocolSetEnabled(proto, change.enabled) else {
                    throw scError("stage network settings")
                }
            }
            guard SCPreferencesCommitChanges(prefs) else { throw scError("commit network settings") }
            guard SCPreferencesApplyChanges(prefs) else { throw scError("apply network settings") }
        }
        var completed = prepared
        released.forEach { completed.leases.removeValue(forKey: $0) }
        if endingSession { completed.sessionID = nil }
        try store.save(completed)
        journal = completed
        lastRestorationNotice = preserved.isEmpty ? nil :
            "Preserved settings changed by another application: " + preserved.sorted().joined(separator: ", ")
    }

    private var dnsValues: [String: Any] {
        [kSCPropNetDNSServerAddresses as String: ["127.0.0.1"]]
    }

    private var proxyValues: [String: Any] {
        [kSCPropNetProxiesHTTPEnable as String: 1,
         kSCPropNetProxiesHTTPProxy as String: "127.0.0.1",
         kSCPropNetProxiesHTTPPort as String: AppConstants.mixedPort,
         kSCPropNetProxiesHTTPSEnable as String: 1,
         kSCPropNetProxiesHTTPSProxy as String: "127.0.0.1",
         kSCPropNetProxiesHTTPSPort as String: AppConstants.mixedPort,
         kSCPropNetProxiesSOCKSEnable as String: 1,
         kSCPropNetProxiesSOCKSProxy as String: "127.0.0.1",
         kSCPropNetProxiesSOCKSPort as String: AppConstants.mixedPort,
         kSCPropNetProxiesProxyAutoConfigEnable as String: 0,
         kSCPropNetProxiesProxyAutoDiscoveryEnable as String: 0]
    }

    private func ownershipGroups(for lease: NetworkProtocolLease) -> [[String]] {
        let endpoints = [["HTTPEnable", "HTTPProxy", "HTTPPort"],
                         ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"],
                         ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"],
                         ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"]]
        var groups: [[String]] = []
        var remaining = Set(lease.installed.keys)
        if lease.protocolType == "Proxies" {
            for endpoint in endpoints where endpoint.allSatisfy({ remaining.contains($0) }) {
                groups.append(endpoint)
                remaining.subtract(endpoint)
            }
        }
        groups.append(contentsOf: remaining.sorted().map { [$0] })
        return groups
    }

    /// Checks configured VPN services in connected/connecting states and a primary tunnel path.
    /// A bare utun interface is deliberately not considered a conflict.
    func conflictDescription() -> String? {
        guard let prefs = try? preferences() else { return "Unable to inspect current VPN state." }
        let services = (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? []
        for service in services {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            guard ["PPP", "IPSec", "VPN"].contains(type) else { continue }
            if let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID(service) as CFString, nil, nil) {
                let status = SCNetworkConnectionGetStatus(connection)
                if status == .connected || status == .connecting {
                    return "Another VPN is active: " + serviceName(service) + ". Disconnect it before enabling Enhanced Mode."
                }
            }
        }
        guard let dynamicStore = SCDynamicStoreCreate(nil, "ClairRoute VPN inspection" as CFString, nil, nil) else {
            return "Unable to inspect the current primary network route."
        }
        for family in ["IPv4", "IPv6"] {
            let key = "State:/Network/Global/" + family
            guard let state = SCDynamicStoreCopyValue(dynamicStore, key as CFString) as? [String: Any],
                  let interface = state["PrimaryInterface"] as? String else { continue }
            if interface.hasPrefix("utun") || interface.hasPrefix("ppp") || interface.hasPrefix("ipsec") {
                // During our own TUN session, CoreSupervisor owns the interface/route checks.
                let isOwned = interface == AppConstants.tunInterfaceName &&
                    journal.leases.values.contains(where: { $0.protocolType == "DNS" })
                if !isOwned {
                    return "The primary \(family) network path is already a tunnel (\(interface)). Disable that VPN before enabling Enhanced Mode."
                }
            }
        }
        do {
            let ownsTunnel = journal.leases.values.contains { $0.protocolType == "DNS" }
            let competing = try TunnelRouteInspection.coveringRoutes().filter {
                !(ownsTunnel && $0.interface == AppConstants.tunInterfaceName)
            }
            if let route = competing.first {
                return "A \(route.family) /\(route.prefixLength) route already uses \(route.interface). Disconnect that VPN before enabling Enhanced Mode."
            }
        } catch {
            return "Unable to inspect competing default routes; Enhanced Mode cannot safely start."
        }
        return nil
    }

    func startObserving(onChange: @escaping @Sendable () -> Void) {
        stopObserving()
        observation = NetworkObservation(onChange: onChange)
    }

    func stopObserving() {
        observation?.stop()
        observation = nil
    }

    deinit { observation?.stop() }
}

private func preferences() throws -> SCPreferences {
    guard let prefs = SCPreferencesCreate(nil, "ClairRoute network ownership" as CFString, nil) else {
        throw scError("open network preferences")
    }
    return prefs
}

private func scError(_ operation: String) -> NetworkSettingsError {
    .systemConfiguration(operation, SCError())
}

private func serviceID(_ service: SCNetworkService) -> String {
    (SCNetworkServiceGetServiceID(service) as String?) ?? ""
}

private func serviceName(_ service: SCNetworkService) -> String {
    (SCNetworkServiceGetName(service) as String?) ?? serviceID(service)
}

private func currentPhysicalServices(_ prefs: SCPreferences) -> [SCNetworkService] {
    guard let set = SCNetworkSetCopyCurrent(prefs) else { return [] }
    let services = (SCNetworkSetCopyServices(set) as? [SCNetworkService]) ?? []
    return services.filter { service in
        guard !serviceID(service).isEmpty, SCNetworkServiceGetEnabled(service),
              let interface = SCNetworkServiceGetInterface(service),
              let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
              let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { return false }
        return !["PPP", "IPSec", "VPN", "Loopback"].contains(type) &&
            !bsdName.hasPrefix("utun") && !bsdName.hasPrefix("ppp") && !bsdName.hasPrefix("ipsec")
    }.sorted { serviceID($0) < serviceID($1) }
}

/// This object owns its callback queue. The callback only requests reconciliation; it never mutates settings.
private final class NetworkObservation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.nano.ClairRoute.network-observation")
    private let onChange: @Sendable () -> Void
    private var dynamicStore: SCDynamicStore?
    private var fingerprint: NSDictionary?
    private var pending: DispatchWorkItem?
    private var writing = false
    private var stopped = false

    init?(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "ClairRoute network observer" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkObservation>.fromOpaque(info).takeUnretainedValue().schedule()
        }, &context) else { return nil }
        dynamicStore = store
        let patterns = ["State:/Network/Service/.*/(IPv4|IPv6|DNS|Proxies)",
                        "State:/Network/Interface/.*/Link", "Setup:/Network/Service/.*",
                        "Setup:/Network/Global/IPv4", "Setup:", "State:/Network/Global/(IPv4|IPv6)"]
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else { return nil }
        queue.sync { fingerprint = snapshot() }
    }

    func beginOwnChange() {
        queue.sync {
            writing = true
            pending?.cancel()
            pending = nil
        }
    }

    func endOwnChange() {
        queue.sync {
            // SCPreferencesCommitChanges has committed Setup values synchronously.
            fingerprint = snapshot()
            writing = false
        }
    }

    private func schedule() {
        guard !stopped, !writing else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.writing else { return }
            let next = self.snapshot()
            let equal = next.map { $0.isEqual(self.fingerprint) } ?? (self.fingerprint == nil)
            guard !equal else { return }
            self.fingerprint = next
            self.onChange()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
    }

    private func snapshot() -> NSDictionary? {
        guard let dynamicStore, let prefs = try? preferences() else { return nil }
        var values: [String: Any] = [:]
        for service in currentPhysicalServices(prefs) {
            let id = serviceID(service)
            values[id + ":name"] = serviceName(service)
            if let interface = SCNetworkServiceGetInterface(service),
               let bsd = SCNetworkInterfaceGetBSDName(interface) as String? {
                let key = "State:/Network/Interface/\(bsd)/Link"
                values[key] = SCDynamicStoreCopyValue(dynamicStore, key as CFString)
            }
            for entity in ["IPv4", "IPv6"] {
                let key = "State:/Network/Service/\(id)/\(entity)"
                values[key] = SCDynamicStoreCopyValue(dynamicStore, key as CFString)
            }
            // Read persisted Setup DNS/proxy values, not the asynchronously propagated State values.
            // This observes external edits without treating our own configd propagation as a new network.
            for type in [kSCNetworkProtocolTypeDNS, kSCNetworkProtocolTypeProxies] {
                if let proto = SCNetworkServiceCopyProtocol(service, type) {
                    values[id + ":" + (type as String)] = SCNetworkProtocolGetConfiguration(proto)
                    values[id + ":" + (type as String) + ":enabled"] = SCNetworkProtocolGetEnabled(proto)
                }
            }
        }
        return values as NSDictionary
    }

    func stop() {
        if let dynamicStore { SCDynamicStoreSetDispatchQueue(dynamicStore, nil) }
        queue.sync {
            stopped = true
            pending?.cancel()
            pending = nil
        }
    }
}

/// Read-only routing-table inspection. Darwin NET_RT_DUMP2 sockaddrs use 4-byte alignment,
/// including on arm64; see Apple network_cmds/netstat.tproj/route.c.
private enum TunnelRouteInspection {
    struct CoveringRoute {
        let interface: String
        let family: String
        let prefixLength: Int
    }

    static func coveringRoutes() throws -> [CoveringRoute] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP2, 0]
        var bytes = Data()
        for attempt in 0..<3 {
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else {
                throw NetworkSettingsError.journalIO("inspect route size", errno)
            }
            guard length >= 0, length <= 16_777_216 else { throw NetworkSettingsError.invalidJournal }
            var capacity = min(length + length / 2 + 4096, 16_777_216)
            bytes = Data(count: capacity)
            let result = bytes.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &capacity, nil, 0)
            }
            if result == 0 {
                bytes.count = capacity
                break
            }
            if errno != ENOMEM || attempt == 2 {
                throw NetworkSettingsError.journalIO("inspect routes", errno)
            }
        }
        return try bytes.withUnsafeBytes { raw in
            var offset = 0
            var matches: [CoveringRoute] = []
            while offset < raw.count {
                guard raw.count - offset >= MemoryLayout<rt_msghdr2>.size else {
                    throw NetworkSettingsError.journalIO("decode route header", EINVAL)
                }
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
                let length = Int(header.rtm_msglen)
                guard length >= MemoryLayout<rt_msghdr2>.size, length <= raw.count - offset else {
                    throw NetworkSettingsError.journalIO("decode route length", EINVAL)
                }
                defer { offset += length }
                guard header.rtm_version == RTM_VERSION,
                      header.rtm_flags & RTF_UP != 0,
                      header.rtm_flags & (RTF_HOST | RTF_IFSCOPE) == 0 else { continue }
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(header.rtm_index), &name) != nil else { continue }
                let interface = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard interface.hasPrefix("utun") || interface.hasPrefix("ppp") ||
                        interface.hasPrefix("ipsec") else { continue }

                var cursor = offset + MemoryLayout<rt_msghdr2>.size
                let end = offset + length
                var addresses: [Int: [UInt8]] = [:]
                for index in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << index) != 0 {
                    guard cursor + 2 <= end else {
                        throw NetworkSettingsError.journalIO("decode route address", EINVAL)
                    }
                    let addressLength = Int(raw[cursor])
                    let padded = max(4, (addressLength + 3) & ~3)
                    guard cursor + padded <= end else {
                        throw NetworkSettingsError.journalIO("decode route address length", EINVAL)
                    }
                    addresses[index] = Array(raw[cursor..<(cursor + addressLength)])
                    cursor += padded
                }
                guard let destination = addresses[Int(RTAX_DST)], destination.count >= 2 else { continue }
                let family = Int32(destination[1])
                let addressStart: Int
                let addressCount: Int
                if family == AF_INET { addressStart = 4; addressCount = 4 }
                else if family == AF_INET6 { addressStart = 8; addressCount = 16 }
                else { continue }
                guard destination.count >= addressStart + addressCount else { continue }
                let destinationBytes = Array(destination[addressStart..<(addressStart + addressCount)])
                let encodedMask = addresses[Int(RTAX_NETMASK)] ?? []
                var mask = [UInt8](repeating: 0, count: addressCount)
                for index in 0..<addressCount where addressStart + index < encodedMask.count {
                    mask[index] = encodedMask[addressStart + index]
                }
                let isDefault = mask.allSatisfy { $0 == 0 } && destinationBytes.allSatisfy { $0 == 0 }
                let isHalf = mask[0] == 128 && mask.dropFirst().allSatisfy { $0 == 0 } &&
                    [0, 128].contains(destinationBytes[0]) && destinationBytes.dropFirst().allSatisfy { $0 == 0 }
                if isDefault || isHalf {
                    matches.append(CoveringRoute(interface: interface,
                                                 family: family == AF_INET ? "IPv4" : "IPv6",
                                                 prefixLength: isDefault ? 0 : 1))
                }
            }
            return matches.sorted { ($0.interface, $0.family, $0.prefixLength) < ($1.interface, $1.family, $1.prefixLength) }
        }
    }
}

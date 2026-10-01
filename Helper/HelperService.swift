import Foundation

private final class HelperEndpoint: NSObject, ClairRouteHelperProtocol {
    private let coordinator: SessionCoordinator
    private let client: AuthenticatedClient

    init(coordinator: SessionCoordinator, client: AuthenticatedClient) {
        self.coordinator = coordinator
        self.client = client
    }
    func apply(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        coordinator.apply(data, client: client, reply: reply)
    }
    func stop(withReply reply: @escaping (Data) -> Void) {
        coordinator.stop(client: client, reply: reply)
    }
    func readStatus(withReply reply: @escaping (Data) -> Void) {
        coordinator.readStatus(client: client, reply: reply)
    }
    func heartbeat(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        coordinator.heartbeat(data, client: client, reply: reply)
    }
    func inspect(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        coordinator.inspect(data, client: client, reply: reply)
    }
}

final class HelperService: NSObject, NSXPCListenerDelegate {
    private let coordinator: SessionCoordinator
    private let requirement: String

    init(coordinator: SessionCoordinator, requirement: String) {
        self.coordinator = coordinator
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = AuthenticatedClient(connectionID: UUID(),
            uid: connection.effectiveUserIdentifier, pid: connection.processIdentifier)
        guard (try? client.requireConsoleOwner()) != nil else { return false }
        // Listener rejects invalid signatures before this delegate. Also bind this peer.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ClairRouteHelperProtocol.self)
        connection.exportedObject = HelperEndpoint(coordinator: coordinator, client: client)
        connection.interruptionHandler = { [coordinator] in coordinator.disconnected(client) }
        connection.invalidationHandler = { [coordinator] in coordinator.disconnected(client) }
        connection.resume()
        return true
    }
}

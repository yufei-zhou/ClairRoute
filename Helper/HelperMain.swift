import Foundation
import Darwin
import os

#if !CLAIRROUTE_RECOVERY_GUARD
@main
enum ClairRouteHelperMain {
    static func main() {
        // No runtime configuration, paths, or actions are accepted as command-line arguments.
        guard CommandLine.arguments.count == 1 else { exit(EX_USAGE) }
        do {
            umask(0o077)
            signal(SIGPIPE, SIG_IGN)
            try HelperSecurity.prepareDirectories()
            let requirement = try HelperSecurity.requirement(
                key: "ClairRouteClientRequirement", identifier: AppConstants.appIdentifier)
            try HelperSecurity.verifyCode(URL(fileURLWithPath: "/Applications/ClairRoute.app"),
                requirement: requirement, directory: true)
            let coordinator = try SessionCoordinator(clientRequirement: requirement)
            let delegate = HelperService(coordinator: coordinator, requirement: requirement)
            let listener = NSXPCListener(machServiceName: AppConstants.machServiceName)
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = delegate
            coordinator.activate()
            listener.resume()
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            termination.setEventHandler { coordinator.shutdown() }
            interruption.setEventHandler { coordinator.shutdown() }
            termination.resume()
            interruption.resume()
            withExtendedLifetime((coordinator, delegate, listener, termination, interruption)) {
                CFRunLoopRun()
            }
        } catch {
            // Never put credential-bearing errors or configuration data in unified logging.
            Logger(subsystem: AppConstants.helperIdentifier, category: "startup")
                .error("Helper refused activation: signature, installation, or recovery prerequisites are not satisfied.")
            exit(EX_CONFIG)
        }
    }
}
#endif

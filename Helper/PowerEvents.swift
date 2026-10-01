import Foundation
import IOKit
import IOKit.pwr_mgt

/// Daemons do not rely on NSWorkspace notifications from a GUI login session.
final class PowerEvents: @unchecked Sendable {
    enum Event: Sendable { case willSleep, didWake }
    private let handler: @Sendable (Event) -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var source: CFRunLoopSource?

    init(handler: @escaping @Sendable (Event) -> Void) { self.handler = handler }

    func start() -> Bool {
        guard rootPort == 0 else { return true }
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let object = Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue()
            switch message {
            // IOMessage.h's function-like iokit_common_msg macro is not imported by Swift.
            // These are sys_iokit (0x38 << 26) | sub_iokit_common (0) | message.
            case 0xe0000270: // kIOMessageCanSystemSleep
                IOAllowPowerChange(object.rootPort, Int(bitPattern: argument))
            case 0xe0000280: // kIOMessageSystemWillSleep
                object.handler(.willSleep)
                // Never delay or veto sleep while waiting for networking work.
                IOAllowPowerChange(object.rootPort, Int(bitPattern: argument))
            case 0xe0000300: // kIOMessageSystemHasPoweredOn
                object.handler(.didWake)
            default: break
            }
        }, &notifier)
        if rootPort != 0, let port {
            source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue()
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                return true
            }
        }
        stop()
        return false
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if rootPort != 0 { IOServiceClose(rootPort); rootPort = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }
}

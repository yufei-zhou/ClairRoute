import AppKit
import SwiftUI

/// Keep every page below the native titlebar. The split layout owns its page header;
/// full-size window content must not place it behind the traffic-light controls.
struct WindowContentBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) { view.reserveTitlebar() }

    final class BoundaryView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reserveTitlebar()
        }
        func reserveTitlebar() {
            guard let window else { return }
            if window.styleMask.contains(.fullSizeContentView) { window.styleMask.remove(.fullSizeContentView) }
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .line
        }
    }
}

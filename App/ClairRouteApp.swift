import SwiftUI

@main struct ClairRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("ClairRoute", id: "settings") {
            MainWindowContent(model: delegate.model, delegate: delegate)
        }.defaultSize(width: 1060, height: 740)
            .windowStyle(.titleBar)
            .defaultLaunchBehavior(.presented)
    }
}
private struct MainWindowContent: View {
    @ObservedObject var model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MainView(model: model, library: model.library)
            .onAppear {
                // Retain the scene action so Spotlight can reopen a closed window.
                delegate.openMainWindow = { [openWindow] in openWindow(id: "settings") }
                model.startObserving()
            }
    }
}

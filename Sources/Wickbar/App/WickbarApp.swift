import SwiftUI
import WickbarCore

@main
struct WickbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.manager)
                .environmentObject(appDelegate.ui)
        } label: {
            MenuBarLabel(manager: appDelegate.manager)
                .modifier(OpenWindowBridge(ui: appDelegate.ui))
        }
        .menuBarExtraStyle(.window)

        Window("Wickbar", id: "main") {
            MainWindow()
                .environmentObject(appDelegate.manager)
                .environmentObject(appDelegate.ui)
        }
        .defaultSize(width: 980, height: 640)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.manager)
        }
    }
}

/// Captures SwiftUI's `openWindow` action from the always-alive menu bar label so AppKit code
/// (e.g. relaunching Wickbar from Finder/Spotlight) can open the main window.
private struct OpenWindowBridge: ViewModifier {
    let ui: UIState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            ui.openMainWindow = { openWindow(id: "main") }
        }
    }
}

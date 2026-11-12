import AppKit
import SwiftUI
import WickbarCore

/// UI state shared between the popover, main window and settings.
@MainActor
final class UIState: ObservableObject {
    @Published var selection: UUID?
    /// Non-nil while the add/edit sheet is shown.
    @Published var editorRequest: EditorRequest?
    /// Set by the menu bar label once SwiftUI is up; opens the main window.
    var openMainWindow: (() -> Void)?
}

struct EditorRequest: Identifiable {
    let id = UUID()
    /// nil = add a new command.
    let config: CommandConfig?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = ProcessManager()
    let ui = UIState()
    private var terminating = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        manager.bootstrap()
        // SwiftUI may auto-open the main Window scene at launch; Wickbar starts in the menu bar only.
        DispatchQueue.main.async {
            for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true {
                w.close()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Relaunching Wickbar (Finder, Spotlight, `open`) while it's running opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ui.openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Requests a graceful quit. `terminate` is scheduled as a run-loop block rather than called from a
    /// main-dispatch-queue block: with `.terminateLater` AppKit spins a nested run loop, and if that happens
    /// inside a main-queue block the (serial) main queue can't drain, so the @MainActor shutdown would never run.
    nonisolated static func quit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// SIGTERM / SIGINT (e.g. `kill`, `killall Wickbar`) take the same graceful path as Quit,
    /// so child processes are stopped instead of orphaned.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { AppDelegate.quit() }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await manager.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Shows a Dock icon while any Wickbar window is open; back to menu-bar-only when they all close.
@MainActor
enum WindowActivation {
    private static var openWindows = 0

    static func opened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

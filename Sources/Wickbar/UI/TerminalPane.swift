import AppKit
import SwiftTerm
import SwiftUI
import WickbarCore

/// Live SwiftTerm view attached to a command's output buffer. On attach it replays the buffer,
/// then streams new bytes; keystrokes go to the PTY and the PTY size follows the view.
struct TerminalPane: NSViewRepresentable {
    let process: ManagedProcess

    func makeCoordinator() -> Coordinator { Coordinator(process: process) }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.nativeBackgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        tv.optionAsMetaKey = true
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var process: ManagedProcess?
        private var token: UUID?
        private weak var view: TerminalView?

        init(process: ManagedProcess) {
            self.process = process
        }

        func attach(_ tv: TerminalView) {
            view = tv
            guard let process else { return }
            let sink = FeedSink(view: tv)
            token = process.output.attach { bytes in sink.feed(bytes) }
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let tv else { return }
                tv.window?.makeFirstResponder(tv)
                let dims = tv.terminalDimensions
                self?.process?.resize(cols: dims.cols, rows: dims.rows)
            }
        }

        func detach() {
            if let token { process?.output.detach(token) }
            token = nil
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            process?.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            process?.send(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
            request.openDefault()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Feeds bytes into a TerminalView from the output buffer's (background) delivery thread.
/// `TerminalView.feed(byteArray:)` is documented as safe to call from a background thread.
private final class FeedSink: @unchecked Sendable {
    private weak var view: TerminalView?
    init(view: TerminalView) { self.view = view }
    func feed(_ bytes: ArraySlice<UInt8>) {
        view?.feed(byteArray: bytes)
    }
}

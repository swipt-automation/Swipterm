import Combine
import Foundation
import GhosttyTerminal
import Observation
import UIKit

@Observable
final class TerminalExtras: NSObject,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceColorChangeDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceClipboardConfirmationDelegate,
    TerminalSurfaceSearchDelegate
{
    @ObservationIgnored let state: TerminalViewState
    @ObservationIgnored var onCommandKey: ((String, UIKeyModifierFlags) -> Bool)?
    @ObservationIgnored var onOpenURL: ((String, TerminalOpenURLKind) -> Void)?
    @ObservationIgnored var onPasteConfirmation: ((TerminalClipboardConfirmationRequest) -> Void)?
    @ObservationIgnored var onDesktopNotification: ((String, String) -> Void)?
    @ObservationIgnored var onNotificationFailure: ((any Error) -> Void)?

    private(set) var title = ""
    private(set) var backgroundColor: TerminalColor

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(state: TerminalViewState) {
        self.state = state
        backgroundColor = state.backgroundColor
        super.init()
        state.$title
            .sink { [weak self] title in
                self?.title = title
            }
            .store(in: &cancellables)
        state.$backgroundColor
            .sink { [weak self] color in
                self?.backgroundColor = color
            }
            .store(in: &cancellables)
    }

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state.terminalDidChangeFocus(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        state.terminalDidClose(processAlive: processAlive)
    }

    func terminalDidRingBell() {
        state.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
        onDesktopNotification?(title, body)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state.terminalDidChangeWorkingDirectory(path)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }

    func terminalDidChangeColor(_ change: TerminalColorChange) {
        state.terminalDidChangeColor(change)
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        onOpenURL?(url, kind)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard request.kind == .paste, let onPasteConfirmation else {
            request.respond(allow: false)
            return
        }
        onPasteConfirmation(request)
    }

    func terminalDidStartSearch(needle: String?) {
        state.terminalDidStartSearch(needle: needle)
    }

    func terminalDidEndSearch() {
        state.terminalDidEndSearch()
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        state.terminalDidUpdateSearchTotal(total)
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        state.terminalDidUpdateSearchSelected(selected)
    }
}

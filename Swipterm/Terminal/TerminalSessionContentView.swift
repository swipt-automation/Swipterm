import GhosttyTerminal
import SwiftUI

struct TerminalSessionContentView: View {
    let session: TerminalSession
    let isActive: Bool
    let isVisible: Bool
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresentingEnd = false
    @State private var isEndAcknowledged = false

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()
            TerminalSurfaceView(
                surfaceView: session.surfaceView,
                state: session.state,
                isActive: isActive,
                isVisible: isVisible
            )
            .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 4 : 0)
            if session.phase == .starting || session.phase == .running, !session.hasVisibleOutput || isEnablingJIT, !isBootFailed {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    if let startupStatus {
                        Text(startupStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .environment(\.colorScheme, overlayColorScheme)
            }
        }
        .accessibilityHidden(!isVisible)
        .alert(endTitle, isPresented: $isPresentingEnd, presenting: endReason) { reason in
            if case let .failed(message) = reason {
                Button("Copy Error") {
                    UIPasteboard.general.string = message
                }
            }
            Button("Close Session", action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: { reason in
            switch reason {
            case let .exited(code):
                Text("The session exited with status \(code).")
            case let .signaled(signal):
                Text("The session was terminated by signal \(signal).")
            case let .failed(message):
                Text(message)
            }
        }
        .onChange(of: endReason, initial: true) { _, endReason in
            if endReason == nil {
                isPresentingEnd = false
                isEndAcknowledged = false
            } else {
                isPresentingEnd = isVisible && !isEndAcknowledged
            }
        }
        .onChange(of: isVisible) { _, isVisible in
            isPresentingEnd = isVisible && endReason != nil && !isEndAcknowledged
        }
        .onChange(of: isPresentingEnd) { _, isPresentingEnd in
            if !isPresentingEnd, isVisible, endReason != nil {
                isEndAcknowledged = true
            }
        }
    }

    private var isBootFailed: Bool {
        if case .failed = session.services.system.state {
            return true
        }
        return false
    }

    private var isEnablingJIT: Bool {
        #if DEBUG || SIDELOAD
            session.services.jit.status == .enabling
        #else
            false
        #endif
    }

    private var startupStatus: LocalizedStringKey? {
        if isEnablingJIT {
            return "Enabling JIT…"
        }
        if session.services.system.state == .booting {
            return "Starting Linux…"
        }
        return nil
    }

    private var endReason: TerminalSession.EndReason? {
        guard case let .finished(reason) = session.phase, reason != .exited(code: 0) else { return nil }
        return reason
    }

    private var endTitle: Text {
        if case .finished(.failed) = session.phase {
            return Text("Couldn’t Start Session")
        }
        return Text("Session Ended")
    }

    private var backgroundColor: Color {
        if let terminalColor = session.backgroundColor {
            return Color(terminalColor)
        }
        return Color(uiColor: .systemBackground)
    }

    private var overlayColorScheme: ColorScheme {
        guard let terminalColor = session.backgroundColor else {
            return colorScheme
        }
        let luminance = 0.2126 * Double(terminalColor.red)
            + 0.7152 * Double(terminalColor.green)
            + 0.0722 * Double(terminalColor.blue)
        return luminance < 128 ? .dark : .light
    }
}

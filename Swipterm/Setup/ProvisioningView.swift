import GhosttyTerminal
import SwiftUI

struct ProvisioningView: View {
    let creation: ContainerCreation

    @Environment(AppSettings.self) private var settings
    @State private var terminal: SetupTerminal?
    @State private var isPresentingFailure = false

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()
            if let terminal {
                TerminalSurfaceView(
                    surfaceView: terminal.surfaceView,
                    state: terminal.state,
                    isActive: false,
                    isVisible: true
                )
            }
            if terminal?.hasVisibleOutput != true, creation.state == .running {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationTitle(Text(verbatim: creation.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: creation.activatesWhenFinished ? .cancellationAction : .primaryAction) {
                Button("Cancel", role: .cancel) {
                    creation.cancel()
                }
            }
            if failure != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry") {
                        creation.start()
                    }
                }
            }
        }
        .alert("Couldn’t Create Container", isPresented: $isPresentingFailure, presenting: failure) { _ in
            Button("Retry") {
                creation.start()
            }
            Button("Copy Output") {
                UIPasteboard.general.string = creation.console.text
            }
            Button("Cancel", role: .cancel) {
                creation.cancel()
            }
        } message: { failure in
            Text(failure)
        }
        .onChange(of: failure, initial: true) { _, failure in
            isPresentingFailure = failure != nil
        }
        .onAppear {
            let terminal = SetupTerminal(creation: creation, settings: settings)
            terminal.attach()
            self.terminal = terminal
        }
        .onDisappear {
            terminal?.detach()
        }
    }

    private var failure: String? {
        if case let .failed(message) = creation.state {
            return message
        }
        return nil
    }

    private var backgroundColor: Color {
        if let terminal {
            return Color(terminal.extras.backgroundColor)
        }
        return Color(uiColor: .systemBackground)
    }
}

@Observable
private final class SetupTerminal {
    let state: TerminalViewState
    let extras: TerminalExtras
    let surfaceView: TerminalSurfaceView.SurfaceView

    private(set) var hasVisibleOutput: Bool

    @ObservationIgnored private let console: ConsoleBuffer
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private var subscription: UUID?

    init(creation: ContainerCreation, settings: AppSettings) {
        console = creation.console
        hasVisibleOutput = !creation.console.chunks.isEmpty
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { viewport in
                Task { @MainActor in
                    creation.resizeTerminal(columns: viewport.columns, rows: viewport.rows)
                }
            }
        )
        state = TerminalAppearance.state(session: session, settings: settings)
        extras = TerminalExtras(state: state)
        surfaceView = TerminalSurfaceView.SurfaceView(state: state, delegate: extras)
    }

    func attach() {
        let session = session
        subscription = console.subscribe { [weak self] data in
            session.receive(data)
            if self?.hasVisibleOutput == false {
                self?.hasVisibleOutput = true
            }
        }
    }

    func detach() {
        console.unsubscribe(subscription!)
        subscription = nil
        surfaceView.setSurfaceVisible(false)
    }
}

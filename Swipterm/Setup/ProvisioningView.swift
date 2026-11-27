import Combine
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
        if let terminalColor = terminal?.backgroundColor {
            return Color(terminalColor)
        }
        return Color(uiColor: .systemBackground)
    }
}

@Observable
private final class SetupTerminal {
    let state: TerminalViewState
    let surfaceView: TerminalSurfaceView.SurfaceView

    private(set) var hasVisibleOutput: Bool
    private(set) var backgroundColor: TerminalColor?

    @ObservationIgnored private let console: ConsoleBuffer
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private let extras: TerminalExtras
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

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
        state = TerminalViewState(
            configSource: .none,
            theme: TerminalAppearance.theme(settings),
            terminalConfiguration: TerminalAppearance.fontConfiguration(settings)
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        extras = TerminalExtras(state: state)

        let view = TerminalSurfaceView.SurfaceView(frame: .zero)
        view.controller = state.controller
        view.configuration = state.configuration
        view.delegate = extras
        surfaceView = view

        state.$backgroundColor
            .sink { [weak self] color in
                self?.backgroundColor = color
            }
            .store(in: &cancellables)
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

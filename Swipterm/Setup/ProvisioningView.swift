import Combine
import GhosttyTerminal
import SwiftUI

struct ProvisioningView: View {
    let provisioning: LinuxSystem.Provisioning

    private let system = LinuxSystem.shared

    @State private var terminal = SetupTerminal()
    @State private var isPresentingFailure = false

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()
            TerminalSurfaceView(
                surfaceView: terminal.surfaceView,
                state: terminal.state,
                isActive: false,
                isVisible: true
            )
            if !terminal.hasVisibleOutput, provisioning.failure == nil {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationTitle("Swipterm Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) {
                    system.cancelSetup()
                }
            }
            if provisioning.failure != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry") {
                        system.retrySetup()
                    }
                }
            }
        }
        .alert("Couldn’t Create Container", isPresented: $isPresentingFailure, presenting: provisioning.failure) { _ in
            Button("Retry") {
                system.retrySetup()
            }
            Button("Copy Output") {
                UIPasteboard.general.string = system.consoleText
            }
            Button("Cancel", role: .cancel) {
                system.cancelSetup()
            }
        } message: { failure in
            Text(failure)
        }
        .onChange(of: provisioning.failure, initial: true) { _, failure in
            isPresentingFailure = failure != nil
        }
        .onAppear {
            terminal.attach()
        }
        .onDisappear {
            terminal.detach()
        }
    }

    private var backgroundColor: Color {
        if let terminalColor = terminal.backgroundColor {
            return Color(terminalColor)
        }
        return Color(uiColor: .systemBackground)
    }
}

@Observable
private final class SetupTerminal {
    let state: TerminalViewState
    let surfaceView: TerminalSurfaceView.SurfaceView

    private(set) var hasVisibleOutput = LinuxSystem.shared.hasConsoleOutput
    private(set) var backgroundColor: TerminalColor?

    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private let extras = TerminalExtras()
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init() {
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { viewport in
                let columns = UInt16(clamping: viewport.columns)
                let rows = UInt16(clamping: viewport.rows)
                Task { @MainActor in
                    LinuxSystem.shared.resizeSetupTerminal(columns: columns, rows: rows)
                }
            }
        )
        state = TerminalViewState(
            configSource: .none,
            theme: TerminalAppearance.theme(),
            terminalConfiguration: TerminalAppearance.fontConfiguration()
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        extras.state = state

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
        guard subscription == nil else { return }
        let session = session
        subscription = LinuxSystem.shared.subscribeConsole { [weak self] data in
            session.receive(data)
            if self?.hasVisibleOutput == false {
                self?.hasVisibleOutput = true
            }
        }
    }

    func detach() {
        if let subscription {
            LinuxSystem.shared.unsubscribeConsole(subscription)
        }
        subscription = nil
        surfaceView.setSurfaceVisible(false)
    }
}

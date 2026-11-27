import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import Observation
import SwiptermKit
import UIKit
import UserNotifications

@Observable
final class TerminalSession: Identifiable {
    enum Phase: Equatable {
        case starting
        case running
        case finished(EndReason)
    }

    enum EndReason: Equatable {
        case exited(code: Int32)
        case signaled(Int32)
        case failed(String)
    }

    let id = UUID()
    let number: Int
    let shortcut: TerminalShortcut?
    let state: TerminalViewState
    let extras: TerminalExtras
    let search: TerminalSearch
    let surfaceView: TerminalSurfaceView.SurfaceView

    private(set) var phase: Phase = .starting
    private(set) var hasVisibleOutput = false

    @ObservationIgnored var onCleanExit: (() -> Void)?

    @ObservationIgnored let services: AppServices
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private let relay: TerminalRelay
    @ObservationIgnored private let startedAt = ContinuousClock.now
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(number: Int, shortcut: TerminalShortcut?, services: AppServices) {
        self.number = number
        self.shortcut = shortcut
        self.services = services
        let relay = TerminalRelay(startupInput: shortcut?.startupInput)
        self.relay = relay
        session = InMemoryTerminalSession(
            write: { data in
                relay.sendInput(data)
            },
            resize: { viewport in
                relay.resize(columns: viewport.columns, rows: viewport.rows)
            }
        )
        session.setOutputBacklogHandler(highWater: 4 << 20, lowWater: 1 << 20) { isBacklogged in
            relay.setOutputBacklogged(isBacklogged)
        }
        state = TerminalAppearance.state(session: session, settings: services.settings)
        extras = TerminalExtras(state: state)
        search = TerminalSearch(terminal: state)

        let view = TerminalSurfaceView.SurfaceView(state: state, delegate: extras)
        view.inMemorySession = session
        view.pasteStaging = services.pasteStaging
        view.readOutputActivity = {
            relay.outputActivitySnapshot()
        }
        surfaceView = view

        extras.onDesktopNotification = { [weak self] title, body in
            self?.postSystemNotification(title: title, body: body)
        }
        NotificationCenter.default.publisher(for: AppSettings.terminalAppearanceDidChange)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
    }

    var title: String {
        let trimmed = extras.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? shortcut?.name ?? services.containers.activeContainer?.metadata.name ?? "" : trimmed
    }

    func beginStart() {
        startTask = Task {
            #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                session.receive(StoreScreenshot.loginScreen)
                phase = .running
                hasVisibleOutput = true
                surfaceView.accessibilityIdentifier = "store-screenshot-terminal"
                surfaceView.isAccessibilityElement = true
            #else
                await start()
            #endif
        }
    }

    private func start() async {
        let session = session
        let relay = relay
        let firstPtyOutput = OnceFlag()
        let system = services.system
        let console = system.console
        var consoleSubscription: UUID?
        defer {
            if let consoleSubscription {
                console.unsubscribe(consoleSubscription)
            }
        }
        do {
            if system.state != .running {
                var showedBootConsole = false
                if number == 1, system.state == .booting || system.state == .shuttingDown {
                    consoleSubscription = console.subscribe { [weak self] data in
                        guard !data.isEmpty else { return }
                        showedBootConsole = true
                        if self?.hasVisibleOutput == false {
                            self?.hasVisibleOutput = true
                        }
                        session.receive(data)
                    }
                }
                try await system.waitUntilRunning()
                if let id = consoleSubscription {
                    console.unsubscribe(id)
                    consoleSubscription = nil
                }
                if showedBootConsole {
                    session.receive(Data("\u{1B}[0m\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8))
                }
            }
            guard !isClosed else { return }
            let size = relay.size
            let handle = try await system.openSession(columns: size.columns, rows: size.rows)
            guard !isClosed else {
                handle.terminal.close()
                return
            }
            relay.attach(handle.terminal, openedWith: size)
            phase = .running

            let terminal = handle.terminal
            let process = handle.process
            let inputStream = relay.inputStream
            let inputTask = Task.detached {
                for await data in inputStream {
                    await terminal.write(data)
                }
            }
            let outputTask = Task.detached { [weak self] in
                while let data = await terminal.read() {
                    await relay.waitWhileBacklogged()
                    guard !relay.isAborted else { break }
                    if !data.isEmpty {
                        relay.recordOutput()
                    }
                    session.receive(data)
                    if firstPtyOutput.claim() {
                        Task { @MainActor [weak self] in
                            self?.hasVisibleOutput = true
                        }
                    }
                }
            }
            Task.detached { [weak self] in
                let termination = await process.termination
                terminal.close()
                relay.releaseBacklogForExit()
                await outputTask.value
                inputTask.cancel()
                await self?.didTerminate(termination)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isClosed else { return }
            phase = .finished(.failed(error.localizedDescription))
        }
    }

    func close() {
        isClosed = true
        startTask?.cancel()
        startTask = nil
        surfaceView.setSurfaceVisible(false)
        surfaceView.syncFocus(isActive: false)
        relay.abort()?.close()
    }

    private func didTerminate(_ termination: LinuxProcess.Termination) {
        guard !isClosed else { return }
        let runtime = UInt64((ContinuousClock.now - startedAt) / .milliseconds(1))
        switch termination {
        case let .exited(code):
            session.finish(exitCode: UInt32(code), runtimeMilliseconds: runtime)
            phase = .finished(.exited(code: code))
            if code == 0 {
                onCleanExit?()
            }
        case let .signaled(signal):
            session.finish(exitCode: UInt32(128 + signal.rawValue), runtimeMilliseconds: runtime)
            phase = .finished(.signaled(signal.rawValue))
        }
        _ = relay.abort()
    }

    private func applySettings() {
        state.controller.setTheme(TerminalAppearance.theme(services.settings))
        state.controller.setTerminalConfiguration(TerminalAppearance.fontConfiguration(services.settings))
    }

    private func postSystemNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(request)
            } catch {
                extras.onNotificationFailure?(error)
            }
        }
    }
}

enum TerminalAppearance {
    static func state(session: InMemoryTerminalSession, settings: AppSettings) -> TerminalViewState {
        let state = TerminalViewState(
            configSource: .none,
            theme: theme(settings),
            terminalConfiguration: fontConfiguration(settings)
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        return state
    }

    static func theme(_ settings: AppSettings) -> TerminalTheme {
        TerminalTheme(
            light: configuration(themeName: settings.lightTheme, customText: settings.lightConfig),
            dark: configuration(themeName: settings.darkTheme, customText: settings.darkConfig)
        )
    }

    private static func configuration(themeName: String, customText: String) -> TerminalConfiguration {
        guard !themeName.isEmpty else {
            return TerminalConfiguration { builder in
                for rawLine in customText.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
                    let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    builder.withCustom(key, value)
                }
            }
        }
        return GhosttyThemeCatalog.theme(named: themeName)!.toTerminalConfiguration()
    }

    static func fontConfiguration(_ settings: AppSettings) -> TerminalConfiguration {
        #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            let size = ProcessInfo.processInfo.environment["SWIPTERM_SCREENSHOT_FONT_SIZE"].flatMap(Float.init) ?? Float(settings.fontSize)
        #else
            let size = Float(settings.fontSize)
        #endif
        let family = settings.fontFamily
        return TerminalConfiguration { builder in
            if !family.isEmpty {
                builder.withFontFamily(family)
            }
            builder.withFontSize(size)
            #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                builder.withCursorStyle(.block)
                builder.withCursorStyleBlink(false)
            #endif
        }
    }
}

private final nonisolated class TerminalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTerminal: LinuxTerminal?
    private var currentSize = LinuxTerminal.Size(columns: 80, rows: 24)
    private var backlogged = false
    private var aborted = false
    private var drainingExit = false
    private var backlogWaiter: CheckedContinuation<Void, Never>?
    private var outputCount: UInt64 = 0
    private var lastOutputUptime: TimeInterval = 0
    private var lastInputUptime: TimeInterval = 0
    private var outputCountAtInputBurst: UInt64 = 0
    private var wasQuietAtInputBurst = true
    private var startupInput: Data?
    private var startupInputTimer: DispatchSourceTimer?

    let inputStream: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation

    init(startupInput: Data?) {
        self.startupInput = startupInput
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        inputStream = stream
        inputContinuation = continuation
    }

    var size: LinuxTerminal.Size {
        lock.withLock { currentSize }
    }

    var isAborted: Bool {
        lock.withLock { aborted }
    }

    func sendInput(_ data: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        let ready = lock.withLock {
            if now - lastInputUptime > 0.02 {
                wasQuietAtInputBurst = now - lastOutputUptime >= 0.2
                outputCountAtInputBurst = outputCount
            }
            lastInputUptime = now
            return currentTerminal != nil && !aborted
        }
        if ready {
            inputContinuation.yield(data)
        }
    }

    func recordOutput() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            outputCount &+= 1
            lastOutputUptime = now
            guard startupInput != nil, startupInputTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .milliseconds(300))
            timer.setEventHandler { [weak self] in
                self?.sendStartupInput()
            }
            timer.activate()
            startupInputTimer = timer
        }
    }

    private func sendStartupInput() {
        let now = ProcessInfo.processInfo.systemUptime
        let (input, timer): (Data?, DispatchSourceTimer?) = lock.withLock {
            guard let startupInput, let startupInputTimer else { return (nil, nil) }
            let remaining = 0.3 - (now - lastOutputUptime)
            if remaining > 0 {
                startupInputTimer.schedule(deadline: .now() + .nanoseconds(Int((remaining * 1_000_000_000).rounded(.up))))
                return (nil, nil)
            }
            self.startupInput = nil
            self.startupInputTimer = nil
            return (startupInput, startupInputTimer)
        }
        timer?.cancel()
        if let input {
            sendInput(input)
        }
    }

    func outputActivitySnapshot() -> TerminalSurfaceView.SurfaceView.OutputActivitySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            if now - lastInputUptime <= 0.05 {
                return .init(
                    wasQuietBeforeInput: wasQuietAtInputBurst,
                    outputCountBeforeInput: outputCountAtInputBurst,
                    currentOutputCount: outputCount
                )
            }
            return .init(
                wasQuietBeforeInput: now - lastOutputUptime >= 0.2,
                outputCountBeforeInput: outputCount,
                currentOutputCount: outputCount
            )
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        let size = LinuxTerminal.Size(columns: columns, rows: rows)
        let terminal = lock.withLock {
            currentSize = size
            return currentTerminal
        }
        terminal?.resize(size)
    }

    func setOutputBacklogged(_ isBacklogged: Bool) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            backlogged = isBacklogged
            guard !isBacklogged, let waiter = backlogWaiter else { return nil }
            backlogWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func waitWhileBacklogged() async {
        let needsWait = lock.withLock { backlogged && !aborted && !drainingExit }
        guard needsWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard backlogged, !aborted, !drainingExit else { return true }
                backlogWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func releaseBacklogForExit() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            drainingExit = true
            backlogged = false
            defer { backlogWaiter = nil }
            return backlogWaiter
        }
        waiter?.resume()
    }

    func attach(_ terminal: LinuxTerminal, openedWith size: LinuxTerminal.Size) {
        let currentSize = lock.withLock {
            currentTerminal = terminal
            return self.currentSize
        }
        if currentSize != size {
            terminal.resize(currentSize)
        }
    }

    func abort() -> LinuxTerminal? {
        inputContinuation.finish()
        let (terminal, waiter, timer) = lock.withLock {
            aborted = true
            backlogged = false
            defer {
                currentTerminal = nil
                backlogWaiter = nil
                startupInput = nil
                startupInputTimer = nil
            }
            return (currentTerminal, backlogWaiter, startupInputTimer)
        }
        waiter?.resume()
        timer?.cancel()
        return terminal
    }
}

private final nonisolated class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

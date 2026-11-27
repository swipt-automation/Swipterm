import Foundation
import Observation
import SwiptermKit
import UIKit

@Observable
final class LinuxSystem {
    enum State: Equatable {
        case checking
        case setup
        case booting
        case running
        case halted
        case failed(BootFailure)

        var runsGuest: Bool {
            self == .booting || self == .running
        }
    }

    struct BootFailure: Equatable, Identifiable {
        let id = UUID()
        let message: String
        let kernelAlternatives: [String]
    }

    struct SessionHandle: Sendable {
        let terminal: LinuxTerminal
        let process: LinuxProcess
    }

    private enum StartupError: LocalizedError {
        case halted

        var errorDescription: String? {
            "The container stopped during initialization."
        }
    }

    private static let loginTimeout = Duration.seconds(300)
    private static let haltReasonTimeout = Duration.seconds(5)
    private static let maxBootReboots = 2

    private(set) var state: State = .checking {
        didSet {
            guestActivityDidChange()
        }
    }

    private(set) var console = ConsoleBuffer()
    var pendingOpenURL: URL?
    var onWillShutdown: (() -> Void)?

    private var runtime: LinuxRuntime?
    private(set) var runtimeGPUMode: GPUMode?
    @ObservationIgnored private var auxiliaryRuntime: LinuxRuntime?
    @ObservationIgnored private var machineBusy = false
    @ObservationIgnored private var machineWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var runningWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var awaitingBootReadiness = false
    @ObservationIgnored private var bootHalt: LinuxRuntime.HaltReason?
    @ObservationIgnored private var bootHaltWaiter: (boot: UInt64, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var bootCount: UInt64 = 0
    @ObservationIgnored private var runtimeBoot: UInt64 = 0
    private var bootstrapped = false
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var pendingTeardown: Task<Void, Never>?
    private var isInBackground = false
    private var isSuspended = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []

    @ObservationIgnored private let store: ContainerStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let location: HostLocation
    @ObservationIgnored private let clipboard: HostClipboard
    @ObservationIgnored private let pasteStaging: HostPasteStaging
    @ObservationIgnored private let catalog: LinuxDistributionCatalogStore

    init(
        store: ContainerStore,
        settings: AppSettings,
        location: HostLocation,
        clipboard: HostClipboard,
        pasteStaging: HostPasteStaging,
        catalog: LinuxDistributionCatalogStore
    ) {
        self.store = store
        self.settings = settings
        self.location = location
        self.clipboard = clipboard
        self.pasteStaging = pasteStaging
        self.catalog = catalog
        #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            state = StoreScreenshot.current == .setup ? .setup : .running
        #else
            observeApplicationLifecycle()
        #endif
    }

    var guestFileSystem: LinuxFileSystem? {
        runtime?.fileSystem
    }

    #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
        /// Screenshot builds only present the in-memory terminal when Create is pressed.
        func create(_: ContainerCreation.Request) throws -> ContainerCreation? {
            state = .running
            return nil
        }
    #else
        func bootstrap() {
            guard !bootstrapped else { return }
            bootstrapped = true
            requestLocalNetworkAuthorizationIfNeeded()

            let generation = beginOperation()
            activeTask = Task {
                let jobs = await store.load()
                guard self.generation == generation else { return }
                for job in jobs {
                    let creation = ContainerCreation(job: job, name: job.metadata?.name ?? job.source!.archiveName, store: store, system: self)
                    store.add(creation)
                    creation.start()
                }
                if let container = store.activeContainer {
                    await bootInstalledRoot(container, generation: generation)
                } else {
                    state = .setup
                }
            }
        }

        func create(_ request: ContainerCreation.Request) throws -> ContainerCreation? {
            let creation = try ContainerCreation(request: request, store: store, system: self)
            store.add(creation)
            creation.start()
            return creation
        }
    #endif

    func restart(kernel: LinuxRuntime.Configuration.Kernel = .installed) {
        let generation = beginOperation()
        console = ConsoleBuffer()
        let previousRuntime = detachRuntimeForShutdown()
        guard let container = store.activeContainer else {
            tearDownInBackground(previousRuntime)
            state = .setup
            return
        }
        state = .booting
        activeTask = Task {
            if let previousRuntime {
                await shutDownRuntime(previousRuntime)
            }
            guard self.generation == generation else { return }
            await bootInstalledRoot(container, kernel: kernel, generation: generation)
        }
    }

    func activate(_ container: LinuxContainer) {
        store.activate(container.id)
        restart()
    }

    func delete(_ container: LinuxContainer) throws {
        let wasActive = container.id == store.activeContainerID
        try store.delete(container)
        if wasActive {
            store.activate(store.containers.first?.id)
            restart()
        }
        store.emptyTrash(after: pendingTeardown)
    }

    func export(_ container: LinuxContainer) async throws -> URL {
        let restarts = container.id == store.activeContainerID && state == .running
        if restarts {
            _ = beginOperation()
            console = ConsoleBuffer()
            state = .halted
            await shutDownDetachedRuntime()
        }
        defer {
            if restarts {
                restart()
            }
        }
        return try await store.export(container)
    }

    func runningRuntime() async -> LinuxRuntime? {
        if state == .booting {
            try? await waitUntilRunning()
        }
        return state == .running ? runtime : nil
    }

    func withManagedRuntime<Result>(
        root: URL,
        hostname: String,
        _ body: (LinuxRuntime) async throws -> Result
    ) async throws -> Result {
        await acquireMachine()
        defer { releaseMachine() }
        try Task.checkCancellation()
        let configuration = LinuxRuntime.Configuration(root: root, initMode: .managed, hostname: hostname)
        let managed = try await LinuxRuntime.boot(configuration) { runtime in
            try await runtime.fileSystem.writeFile("/etc/hostname", contents: Data("\(hostname)\n".utf8), permissions: 0o644)
        }
        auxiliaryRuntime = managed
        if isSuspended {
            managed.suspend()
        }
        do {
            let result = try await body(managed)
            await shutDownAuxiliaryRuntime(managed)
            return result
        } catch {
            await shutDownAuxiliaryRuntime(managed)
            throw error
        }
    }

    func guestActivityDidChange() {
        #if !SWIPTERM_STORE_SCREENSHOTS || !targetEnvironment(simulator)
            location.updateContainerActive(state.runsGuest || store.creations.contains { $0.state == .running })
        #endif
    }

    func waitUntilRunning() async throws {
        if state == .running {
            return
        }
        guard awaitsRunning else {
            throw CancellationError()
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if state == .running {
                    continuation.resume()
                } else if !awaitsRunning {
                    continuation.resume(throwing: CancellationError())
                } else {
                    runningWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.runningWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func openSession(columns: UInt16, rows: UInt16) async throws -> SessionHandle {
        guard let runtime, state == .running else {
            throw LinuxError.ESRCH
        }
        let terminal = try runtime.makeTerminal(size: LinuxTerminal.Size(columns: columns, rows: rows))
        do {
            let process = try await runtime.login(user: store.activeContainer!.metadata.defaultUser, on: terminal, environment: [
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
                "LANG": "C.UTF-8",
                "TZ": TimeZone.current.identifier,
                "BROWSER": "/run/host-bin/xdg-open",
                "WAYLAND_DISPLAY": "/run/host/wayland-0",
            ])
            return SessionHandle(terminal: terminal, process: process)
        } catch {
            terminal.close()
            throw error
        }
    }

    private var awaitsRunning: Bool {
        switch state {
        case .booting, .failed:
            true
        default:
            false
        }
    }

    private func beginOperation() -> UInt64 {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        cancelRunningWaiters()
        return generation
    }

    private func acquireMachine() async {
        if machineBusy {
            await withCheckedContinuation { machineWaiters.append($0) }
        } else {
            machineBusy = true
        }
    }

    private func releaseMachine() {
        if machineWaiters.isEmpty {
            machineBusy = false
        } else {
            machineWaiters.removeFirst().resume()
        }
    }

    private func shutDownAuxiliaryRuntime(_ managed: LinuxRuntime) async {
        auxiliaryRuntime = nil
        if isSuspended {
            managed.resume()
        }
        await Task.detached {
            managed.shutdown()
        }.value
    }

    private func cancelRunningWaiters() {
        let waiters = runningWaiters
        runningWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func completeRunningWaiters() {
        let waiters = runningWaiters
        runningWaiters.removeAll()
        console.close()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func detachRuntimeForShutdown() -> LinuxRuntime? {
        onWillShutdown?()
        let current = runtime
        runtime = nil
        runtimeGPUMode = nil
        if let current {
            store.runtimeDidStop()
            clipboard.detach(from: current)
            pasteStaging.detach(from: current)
        }
        return current
    }

    private func shutDownRuntime(_ target: LinuxRuntime) async {
        if isSuspended {
            isSuspended = false
            target.resume()
        }
        await Task.detached {
            target.shutdown()
        }.value
        releaseMachine()
    }

    private func shutDownDetachedRuntime() async {
        if let previousRuntime = detachRuntimeForShutdown() {
            await shutDownRuntime(previousRuntime)
        }
    }

    private func tearDownInBackground(_ target: LinuxRuntime?) {
        if let target {
            let previousTeardown = pendingTeardown
            pendingTeardown = Task {
                await previousTeardown?.value
                await shutDownRuntime(target)
            }
        }
        store.emptyTrash(after: pendingTeardown)
    }

    private func startRuntime(
        _ container: LinuxContainer,
        kernel: LinuxRuntime.Configuration.Kernel,
        generation: UInt64
    ) async throws -> LinuxRuntime {
        await pendingTeardown?.value
        await acquireMachine()
        guard self.generation == generation else {
            releaseMachine()
            throw CancellationError()
        }
        bootCount &+= 1
        let boot = bootCount
        let normalizer = ConsoleNewlineNormalizer()
        let metadata = container.metadata
        let gpuMode = settings.gpuMode
        let console = console
        let commands = HostCommands(system: self, store: store, settings: settings, location: location, catalog: catalog)
        let clipboard = clipboard
        let pasteStaging = pasteStaging
        let configuration = LinuxRuntime.Configuration(
            root: ContainerStore.rootURL(for: container.id),
            kernel: kernel,
            hostname: metadata.name,
            gpu: gpuMode.configuration,
            consoleOutput: { data in
                let chunk = normalizer.normalize(data)
                guard !chunk.isEmpty else { return }
                Task { @MainActor in
                    console.append(chunk)
                }
            },
            haltHandler: { reason in
                Task { @MainActor in
                    self.runtimeDidHalt(reason, generation: generation, boot: boot)
                }
            },
            clipboard: clipboard
        )
        let bootedRuntime: LinuxRuntime
        do {
            bootedRuntime = try await LinuxRuntime.boot(configuration) { runtime in
                try await runtime.fileSystem.writeFile(ContainerStore.guestMetadataPath, contents: JSONEncoder().encode(metadata))
                try HostPasteStaging.prepareHostDirectory()
                var mountedVirtioFS = false
                do {
                    try await runtime.mount(HostPasteStaging.hostDirectory, at: HostPasteStaging.guestDirectory, readOnly: true)
                    mountedVirtioFS = true
                } catch let error as LinuxError where error == .ENODEV {
                    try await runtime.fileSystem.createDirectory(
                        HostPasteStaging.guestDirectory,
                        permissions: 0o755,
                        withIntermediateDirectories: true
                    )
                }
                pasteStaging.attach(to: runtime, usesVirtioFS: mountedVirtioFS)
                do {
                    try await runtime.registerDevice(at: "/dev/clipboard", handler: ClipboardDevice(clipboard: clipboard))
                } catch let error as LinuxError where error == .ENODEV {}
                clipboard.attach(to: runtime)
                try await commands.register(on: runtime)
            }
        } catch {
            releaseMachine()
            throw error
        }
        guard self.generation == generation else {
            tearDownInBackground(bootedRuntime)
            throw CancellationError()
        }
        runtime = bootedRuntime
        runtimeGPUMode = gpuMode
        runtimeBoot = boot
        if isSuspended {
            bootedRuntime.suspend()
        }
        return bootedRuntime
    }

    private func bootInstalledRoot(
        _ container: LinuxContainer,
        kernel: LinuxRuntime.Configuration.Kernel = .installed,
        generation: UInt64
    ) async {
        console = ConsoleBuffer()
        state = .booting
        do {
            try await bootRoot(container, kernel: kernel, generation: generation)
            store.runtime = runtime
            state = .running
            completeRunningWaiters()
        } catch {
            guard self.generation == generation else { return }
            cancelRunningWaiters()
            console = ConsoleBuffer()
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            let alternatives = await Task.detached { Self.kernelAlternatives(in: container, excluding: kernel) }.value
            guard self.generation == generation else { return }
            state = .failed(BootFailure(message: Self.failureMessage(error, kernelAlternatives: alternatives), kernelAlternatives: alternatives))
        }
    }

    private func bootRoot(_ container: LinuxContainer, kernel: LinuxRuntime.Configuration.Kernel, generation: UInt64) async throws {
        var reboots = 0
        while true {
            let bootedRuntime = try await startRuntime(container, kernel: kernel, generation: generation)
            let boot = runtimeBoot

            awaitingBootReadiness = true
            bootHalt = nil
            defer {
                if self.generation == generation {
                    awaitingBootReadiness = false
                }
            }
            var halted = false
            do {
                try await bootedRuntime.waitReady(.login, timeout: Self.loginTimeout)
            } catch let error as LinuxError where error == .ESRCH {
                halted = true
                await waitForBootHalt(boot)
            }
            guard self.generation == generation else { throw CancellationError() }
            if !halted, bootHalt == nil {
                return
            }
            guard bootHalt == .reboot, reboots < Self.maxBootReboots else { throw StartupError.halted }
            reboots += 1
            await shutDownDetachedRuntime()
            guard self.generation == generation else { throw CancellationError() }
        }
    }

    private nonisolated static func failureMessage(_ error: any Error, kernelAlternatives: [String]) -> String {
        guard error is LinuxRuntime.KernelUnavailableError, kernelAlternatives.isEmpty else {
            return error.localizedDescription
        }
        let message = String(localized: "This system has no kernel that can boot on this device. Use an archive that includes a 4K- or 16K-page ARM64 kernel.")
        return message + "\n\n" + error.localizedDescription
    }

    private nonisolated static func kernelAlternatives(in container: LinuxContainer, excluding kernel: LinuxRuntime.Configuration.Kernel) -> [String] {
        guard let kernels = try? LinuxRootImage.installedKernels(at: ContainerStore.rootURL(for: container.id)) else {
            return []
        }
        let release: String? = switch kernel {
        case .installed: kernels.first
        case let .release(release): release
        }
        return kernels.filter { $0 != release }
    }

    private func waitForBootHalt(_ boot: UInt64) async {
        guard bootHalt == nil else { return }
        let timeout = Task {
            try? await Task.sleep(for: Self.haltReasonTimeout)
            resumeBootHaltWaiter(boot)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                bootHaltWaiter = (boot, continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.resumeBootHaltWaiter(boot)
            }
        }
        timeout.cancel()
    }

    private func resumeBootHaltWaiter(_ boot: UInt64) {
        guard let waiter = bootHaltWaiter, waiter.boot == boot else { return }
        bootHaltWaiter = nil
        waiter.continuation.resume()
    }

    private func runtimeDidHalt(_ reason: LinuxRuntime.HaltReason, generation: UInt64, boot: UInt64) {
        guard self.generation == generation, let runtime, runtimeBoot == boot else { return }
        if state == .booting, awaitingBootReadiness {
            bootHalt = reason
            resumeBootHaltWaiter(boot)
            return
        }
        switch reason {
        case .reboot:
            restart()
        case .powerOff, .exited:
            _ = beginOperation()
            state = .halted
            console = ConsoleBuffer()
            activeTask = shutDownHaltedRuntime(runtime)
        }
    }

    private func shutDownHaltedRuntime(_ halted: LinuxRuntime) -> Task<Void, Never> {
        onWillShutdown?()
        store.runtimeDidStop()
        clipboard.detach(from: halted)
        pasteStaging.detach(from: halted)
        return Task {
            await shutDownRuntime(halted)
            if runtime === halted {
                runtime = nil
                runtimeGPUMode = nil
            }
        }
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.handleDidEnterBackground()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.handleWillEnterForeground()
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.location.reconcile()
                }
            },
        ]
        location.onBackgroundKeepAliveChange = {
            if self.location.isKeepingBackgroundAlive {
                if self.isSuspended {
                    self.isSuspended = false
                    self.runtime?.resume()
                    self.auxiliaryRuntime?.resume()
                }
            } else if self.isInBackground, self.backgroundTaskID == .invalid {
                self.suspendRuntimeIfNeeded()
            }
        }
    }

    private func handleDidEnterBackground() {
        isInBackground = true
        LinuxRuntime.suspendGPU()
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Swipterm.LinuxRuntime") {
            MainActor.assumeIsolated {
                if !self.location.isKeepingBackgroundAlive {
                    self.suspendRuntimeIfNeeded()
                }
                self.endBackgroundTaskIfNeeded()
            }
        }
        if backgroundTaskID == .invalid, !location.isKeepingBackgroundAlive {
            suspendRuntimeIfNeeded()
        }
    }

    private func handleWillEnterForeground() {
        isInBackground = false
        endBackgroundTaskIfNeeded()
        LinuxRuntime.resumeGPU()
        if isSuspended {
            isSuspended = false
            runtime?.resume()
            auxiliaryRuntime?.resume()
        }
    }

    private func suspendRuntimeIfNeeded() {
        guard !isSuspended else { return }
        isSuspended = true
        runtime?.suspend()
        auxiliaryRuntime?.suspend()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func requestLocalNetworkAuthorizationIfNeeded() {
        URLSession.shared.dataTask(with: URL(string: "https://captive.apple.com")!) { _, _, _ in }.resume()
    }
}

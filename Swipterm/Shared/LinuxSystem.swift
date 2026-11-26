import Foundation
import Observation
import SwiptermKit
import UIKit

@Observable
final class LinuxSystem {
    enum State: Equatable {
        case checking
        case setup
        case provisioning(Provisioning)
        case booting
        case running
        case halted
        case failed(String)

        var keepsScreenAwake: Bool {
            if case let .provisioning(provisioning) = self {
                return provisioning.failure == nil
            }
            return false
        }

        var runsGuest: Bool {
            switch self {
            case let .provisioning(provisioning):
                provisioning.failure == nil
            case .booting, .running:
                true
            case .checking, .setup, .halted, .failed:
                false
            }
        }
    }

    struct Provisioning: Equatable {
        let attempt: Int
        var failure: String?
    }

    enum InstallRequest: Sendable {
        struct Creation: Sendable {
            enum Source: Sendable {
                case catalog(LinuxReleaseImage)
                case localArchive(URL)
                case remoteArchive(URL)
            }

            let source: Source
            let containerName: String
            let user: String
            let password: String?
            let software: ContainerSoftware
        }

        case create(Creation)
        case importArchive(URL)
    }

    struct SessionHandle: Sendable {
        let terminal: LinuxTerminal
        let process: LinuxProcess
    }

    private struct ConsoleProgress {
        var meter: ConsoleMeter
        var chunkIndex: Int?
        var lineLengths: [Int] = []
    }

    private enum StartupError: LocalizedError {
        case missingInit
        case exited(Int32)
        case signaled(Int32)
        case halted
        case notContainer

        var errorDescription: String? {
            switch self {
            case .notContainer:
                String(localized: "This archive isn’t a Swipterm container.")
            case .missingInit:
                "This system has no init system."
            case let .exited(code):
                "Initialization failed with exit status \(code)."
            case let .signaled(signal):
                "Initialization was terminated by signal \(signal)."
            case .halted:
                "The container stopped during initialization."
            }
        }
    }

    static let shared = LinuxSystem()

    private static let loginTimeout = Duration.seconds(300)
    private static let outputDrainTimeout = Duration.seconds(1)
    private static let haltReasonTimeout = Duration.seconds(5)
    private static let maxBootReboots = 2

    private(set) var state: State = .checking {
        didSet {
            #if !SWIPTERM_STORE_SCREENSHOTS || !targetEnvironment(simulator)
                HostLocation.shared.updateContainerActive(state.runsGuest)
            #endif
        }
    }

    private(set) var containers: [LinuxContainer] = []
    private(set) var activeContainerID: String? {
        didSet {
            if let activeContainerID {
                PreferenceStore.shared.set(activeContainerID, for: Self.activeContainerKey)
            } else {
                PreferenceStore.shared.remove(Self.activeContainerKey)
            }
        }
    }

    private(set) var exportProgress: Double?
    var pendingOpenURL: URL?
    var onWillShutdown: (() -> Void)?

    private var runtime: LinuxRuntime?
    @ObservationIgnored private var consoleChunks: [Data] = []
    @ObservationIgnored private var consoleListeners: [UUID: (Data) -> Void] = [:]
    @ObservationIgnored private var runningWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var setupTerminal: LinuxTerminal?
    @ObservationIgnored private var setupTerminalSize = LinuxTerminal.Size(columns: 40, rows: 24)
    @ObservationIgnored private var haltedDuringProvisioning = false
    @ObservationIgnored private var awaitingBootReadiness = false
    @ObservationIgnored private var bootHalt: LinuxRuntime.HaltReason?
    @ObservationIgnored private var bootHaltWaiter: (boot: UInt64, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var bootCount: UInt64 = 0
    @ObservationIgnored private var runtimeBoot: UInt64 = 0
    @ObservationIgnored private var openConsoleProgress: ConsoleProgress?
    @ObservationIgnored private var consoleProgressEpoch: UInt64 = 0
    @ObservationIgnored private var pendingInstall: InstallRequest?
    private var provisioningAttempt = 0
    private var bootstrapped = false
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var pendingTeardown: Task<Void, Never>?
    private var isInBackground = false
    private var isSuspended = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            state = StoreScreenshot.current == .setup ? .setup : .running
        #else
            observeApplicationLifecycle()
        #endif
    }

    var activeContainer: LinuxContainer? {
        containers.first { $0.id == activeContainerID }
    }

    var guestFileSystem: LinuxFileSystem? {
        runtime?.fileSystem
    }

    var consoleText: String {
        ConsoleText.plain(consoleChunks)
    }

    var hasConsoleOutput: Bool {
        !consoleChunks.isEmpty
    }

    #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
        /// Screenshot builds only present the in-memory terminal when Create is pressed.
        func install(_: InstallRequest) {
            state = .running
        }
    #else
        func bootstrap() {
            guard !bootstrapped else { return }
            bootstrapped = true
            requestLocalNetworkAuthorizationIfNeeded()

            let generation = beginOperation()
            activeTask = Task {
                let stored = await Task.detached { () -> [LinuxContainer] in
                    Self.moveToTrash(Self.downloadStagingDirectoryURL)
                    Self.moveToTrash(Self.exportDirectoryURL)
                    Self.migrateLegacyRoot()
                    return Self.loadContainers()
                }.value
                tearDownInBackground(nil)

                guard self.generation == generation else { return }
                containers = stored
                let completed = stored.filter(\.metadata.setupCompleted)
                let storedID = PreferenceStore.shared.value(String.self, for: Self.activeContainerKey)
                activeContainerID = completed.contains { $0.id == storedID } ? storedID : completed.first?.id

                if let pending = stored.first(where: { !$0.metadata.setupCompleted }) {
                    beginSetupAttempt()
                    await provision(pending, generation: generation)
                } else if let container = activeContainer {
                    await bootInstalledRoot(container, generation: generation)
                } else {
                    state = .setup
                }
            }
        }

        func install(_ request: InstallRequest) {
            let generation = beginOperation()
            pendingInstall = request
            beginSetupAttempt()
            switch request {
            case let .create(creation):
                switch creation.source {
                case .catalog, .remoteArchive:
                    appendConsoleStep("Download", generation: generation)
                case .localArchive:
                    appendConsoleStep("Copy", generation: generation)
                }
            case .importArchive:
                appendConsoleStep("Copy", generation: generation)
            }
            let previousRuntime = detachRuntimeForShutdown()

            activeTask = Task {
                if let previousRuntime {
                    await shutDownRuntime(previousRuntime)
                }
                guard self.generation == generation else { return }

                let id = UUID().uuidString
                let stagingRootURL = Self.containersDirectoryURL
                    .appending(path: Self.stagingPrefix + id, directoryHint: .isDirectory)
                var placedRoot = false
                var temporaryArchiveURL: URL?
                defer {
                    if let temporaryArchiveURL {
                        try? FileManager.default.removeItem(at: temporaryArchiveURL)
                    }
                    if !placedRoot {
                        Task.detached(priority: .utility) {
                            try? FileManager.default.removeItem(at: stagingRootURL)
                        }
                    }
                }

                do {
                    let archiveURL: URL
                    switch request {
                    case let .create(creation):
                        switch creation.source {
                        case let .catalog(release):
                            archiveURL = try await downloadArchive(from: release.archiveURL, generation: generation)
                        case let .remoteArchive(url):
                            archiveURL = try await downloadArchive(from: url, generation: generation)
                        case let .localArchive(url):
                            archiveURL = try await Task.detached {
                                try Self.stageLocalArchive(from: url)
                            }.value
                        }
                    case let .importArchive(url):
                        archiveURL = try await Task.detached {
                            try Self.stageLocalArchive(from: url)
                        }.value
                    }
                    temporaryArchiveURL = archiveURL

                    guard self.generation == generation else { return }
                    appendConsoleStep("Extract", generation: generation)
                    let builder = try LinuxRootImageBuilder(root: stagingRootURL)
                    try await unpack(nil, generation: generation) { progress in
                        try await builder.add(.archive(at: archiveURL), progress: progress)
                    }
                    guard self.generation == generation else { return }
                    try? FileManager.default.removeItem(at: archiveURL)
                    temporaryArchiveURL = nil
                    let metadata: ContainerMetadata
                    switch request {
                    case let .create(creation):
                        guard Self.hasSystemInit(in: builder) else {
                            throw StartupError.missingInit
                        }
                        if case let .catalog(release) = creation.source {
                            try await installKernel(release.distribution, into: builder, generation: generation)
                            guard self.generation == generation else { return }
                        }
                        metadata = Self.makeMetadata(for: creation)
                    case .importArchive:
                        guard let exported = try builder.contents(of: Self.guestMetadataPath) else {
                            throw StartupError.notContainer
                        }
                        metadata = try JSONDecoder().decode(ContainerMetadata.self, from: exported)
                    }
                    try await builder.finish()
                    guard self.generation == generation else { return }

                    try await Task.detached {
                        try Self.saveContainerMetadata(metadata, root: stagingRootURL)
                    }.value
                    guard self.generation == generation else { return }
                    try FileManager.default.moveItem(at: stagingRootURL, to: Self.rootURL(for: id))
                    placedRoot = true
                    let container = LinuxContainer(id: id, metadata: metadata)
                    containers.append(container)
                    pendingInstall = nil
                    if metadata.setupCompleted {
                        switchActiveContainer(to: id)
                        await bootInstalledRoot(container, generation: generation)
                    } else {
                        await provision(container, generation: generation)
                    }
                } catch is CancellationError {
                    guard self.generation == generation else { return }
                    pendingInstall = nil
                    resetConsole()
                    state = .setup
                } catch {
                    guard self.generation == generation else { return }
                    tearDownInBackground(nil)
                    endConsoleProgressLine(generation: generation)
                    appendConsole(Data("\u{1B}[1;31merror:\u{1B}[0m \(error.localizedDescription)\r\n".utf8), generation: generation)
                    state = .provisioning(Provisioning(attempt: provisioningAttempt, failure: error.localizedDescription))
                }
            }
        }

    #endif

    func retrySetup() {
        guard case let .provisioning(provisioning) = state, provisioning.failure != nil else { return }
        if let pendingInstall {
            install(pendingInstall)
        } else if let pending = containers.first(where: { !$0.metadata.setupCompleted }) {
            let generation = beginOperation()
            beginSetupAttempt()
            activeTask = Task {
                await provision(pending, generation: generation)
            }
        }
    }

    func cancelSetup() {
        pendingInstall = nil
        if let pending = containers.first(where: { !$0.metadata.setupCompleted }) {
            containers.removeAll { $0.id == pending.id }
            Self.moveToTrash(Self.rootURL(for: pending.id))
        }
        Self.moveToTrash(Self.downloadStagingDirectoryURL)
        restart()
        tearDownInBackground(nil)
    }

    func restart() {
        let generation = beginOperation()
        resetConsole()
        let previousRuntime = detachRuntimeForShutdown()
        guard let container = activeContainer else {
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
            await bootInstalledRoot(container, generation: generation)
        }
    }

    func activate(_ container: LinuxContainer) {
        switchActiveContainer(to: container.id)
        restart()
    }

    func delete(_ container: LinuxContainer) {
        containers.removeAll { $0.id == container.id }
        Self.moveToTrash(Self.rootURL(for: container.id))
        if container.id == activeContainerID {
            switchActiveContainer(to: containers.first?.id)
            restart()
        }
        tearDownInBackground(nil)
    }

    func export(_ container: LinuxContainer) async throws -> URL {
        exportProgress = 0
        defer {
            exportProgress = nil
        }
        let restarts = container.id == activeContainerID && state == .running
        if restarts {
            _ = beginOperation()
            resetConsole()
            state = .halted
            await shutDownDetachedRuntime()
        }
        defer {
            if restarts {
                restart()
            }
        }
        try FileManager.default.createDirectory(at: Self.exportDirectoryURL, withIntermediateDirectories: true)
        let archiveURL = Self.exportDirectoryURL.appending(path: "\(container.metadata.name).tar.gz")
        try await LinuxRootImage.export(from: Self.rootURL(for: container.id), to: archiveURL) { fraction in
            Task { @MainActor in
                if LinuxSystem.shared.exportProgress != nil {
                    LinuxSystem.shared.exportProgress = fraction
                }
            }
        }
        return archiveURL
    }

    func subscribeConsole(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        for chunk in consoleChunks {
            handler(chunk)
        }
        if acceptsConsoleOutput {
            consoleListeners[id] = handler
        }
        return id
    }

    func unsubscribeConsole(_ id: UUID) {
        consoleListeners.removeValue(forKey: id)
    }

    func resizeSetupTerminal(columns: UInt16, rows: UInt16) {
        let size = LinuxTerminal.Size(columns: max(columns, 1), rows: max(rows, 1))
        guard size != setupTerminalSize else { return }
        let previousColumns = setupTerminalSize.columns
        setupTerminalSize = size
        setupTerminal?.resize(size)
        guard openConsoleProgress != nil, size.columns != previousColumns else { return }
        renderConsoleProgress()
    }

    func waitUntilRunning() async throws {
        if state == .running {
            return
        }
        guard state == .booting else {
            throw CancellationError()
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if state == .running {
                    continuation.resume()
                } else if state != .booting {
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
            let process = try await runtime.login(user: activeContainer?.metadata.defaultUser ?? "root", on: terminal, environment: [
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

    private var acceptsConsoleOutput: Bool {
        switch state {
        case .booting:
            true
        case let .provisioning(provisioning):
            provisioning.failure == nil
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

    private func switchActiveContainer(to id: String?) {
        activeContainerID = id
        HostPasteStaging.removeAllFiles()
    }

    private func beginSetupAttempt() {
        provisioningAttempt += 1
        resetConsole()
        state = .provisioning(Provisioning(attempt: provisioningAttempt))
    }

    private func resetConsole() {
        consoleChunks.removeAll()
        consoleListeners.removeAll()
        openConsoleProgress = nil
        consoleProgressEpoch &+= 1
    }

    private func appendConsoleStep(_ title: String, generation: UInt64) {
        endConsoleProgressLine(generation: generation)
        appendConsole(Data("\u{1B}[1m==> \(title)\u{1B}[0m\r\n".utf8), generation: generation)
    }

    private func downloadArchive(from url: URL, generation: UInt64) async throws -> URL {
        let epoch = consoleProgressEpoch
        let start = ContinuousClock.now
        let name = url.host() ?? url.absoluteString
        return try await RootImageDownloader.download(from: url) { bytesWritten, totalBytes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LinuxSystem.shared.appendConsoleDownloadProgress(
                        bytesWritten: bytesWritten,
                        totalBytes: totalBytes,
                        name: name,
                        start: start,
                        generation: generation,
                        epoch: epoch
                    )
                }
            }
        }
    }

    private func installKernel(
        _ distribution: LinuxDistribution,
        into builder: LinuxRootImageBuilder,
        generation: UInt64
    ) async throws {
        guard let release = try Self.osRelease(in: builder) else {
            throw KernelBootstrapError.unknownRelease
        }
        appendConsoleStep("Kernel", generation: generation)
        let directory = Self.downloadStagingDirectoryURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let bootstrap = KernelBootstrap(distribution: distribution, release: release)
        let packages = try await bootstrap.packages { url in
            try await self.download(url, into: directory, generation: generation)
        }
        var files: [URL] = []
        for package in packages {
            try await files.append(download(package.url, into: directory, generation: generation))
        }
        var installed: [KernelBootstrap.Installed] = []
        for (package, file) in zip(packages, files) {
            let contents = try await unpack(package.name, generation: generation) { progress in
                try await builder.addPackage(at: file, progress: progress)
            }
            installed.append(KernelBootstrap.Installed(package: package, file: file, contents: contents))
        }
        try await bootstrap.register(installed, in: builder)
    }

    private func download(
        _ url: URL,
        into directory: URL,
        generation: UInt64
    ) async throws -> URL {
        let name = url.lastPathComponent
        let destination = directory.appending(path: "\(UUID().uuidString)-\(name)")
        let epoch = consoleProgressEpoch
        let start = ContinuousClock.now
        defer {
            endConsoleProgressLine(generation: generation)
        }
        try await HTTPClient.download(from: url, to: destination) { bytesWritten, totalBytes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LinuxSystem.shared.appendConsoleDownloadProgress(
                        bytesWritten: bytesWritten,
                        totalBytes: totalBytes,
                        name: name,
                        start: start,
                        generation: generation,
                        epoch: epoch
                    )
                }
            }
        }.requireSuccess()
        return destination
    }

    private func unpack<Result>(
        _ name: String?,
        generation: UInt64,
        _ body: (@escaping @Sendable (Double) -> Void) async throws -> Result
    ) async throws -> Result {
        let epoch = consoleProgressEpoch
        let start = ContinuousClock.now
        let result = try await body { fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LinuxSystem.shared.appendConsoleExtractionProgress(name, fraction, start: start, generation: generation, epoch: epoch)
                }
            }
        }
        appendConsoleExtractionProgress(name, 1, start: start, generation: generation, epoch: epoch)
        endConsoleProgressLine(generation: generation)
        return result
    }

    private func appendConsoleDownloadProgress(
        bytesWritten: Int64,
        totalBytes: Int64?,
        name: String,
        start: ContinuousClock.Instant,
        generation: UInt64,
        epoch: UInt64
    ) {
        var meter = DownloadMeter(start: start, name: name)
        if case let .download(current)? = openConsoleProgress?.meter {
            meter = current
        }
        meter.update(bytesWritten: bytesWritten, totalBytes: totalBytes)
        updateConsoleProgress(.download(meter), generation: generation, epoch: epoch)
    }

    private func appendConsoleExtractionProgress(
        _ name: String?,
        _ fraction: Double,
        start: ContinuousClock.Instant,
        generation: UInt64,
        epoch: UInt64
    ) {
        updateConsoleProgress(
            .extraction(name: name, fraction: fraction, elapsed: start.duration(to: .now)),
            generation: generation,
            epoch: epoch
        )
    }

    private func updateConsoleProgress(_ meter: ConsoleMeter, generation: UInt64, epoch: UInt64) {
        guard self.generation == generation, consoleProgressEpoch == epoch else { return }
        var progress = openConsoleProgress ?? ConsoleProgress(meter: meter)
        progress.meter = meter
        openConsoleProgress = progress
        renderConsoleProgress()
    }

    private func renderConsoleProgress() {
        guard var progress = openConsoleProgress else { return }
        let columns = Int(setupTerminalSize.columns)
        let lines = progress.meter.lines(width: max(columns - 1, 20))
        let snapshot = lines.joined(separator: "\r\n")
        let rows = progress.lineLengths.reduce(0) { $0 + max(($1 + columns - 1) / columns, 1) }
        let redraw = Data(("\r" + (rows > 1 ? "\u{1B}[\(rows - 1)A" : "") + "\u{1B}[J" + snapshot).utf8)
        if let chunkIndex = progress.chunkIndex {
            consoleChunks[chunkIndex] = Data(snapshot.utf8)
        } else {
            progress.chunkIndex = consoleChunks.count
            consoleChunks.append(Data(snapshot.utf8))
        }
        progress.lineLengths = lines.map(\.count)
        openConsoleProgress = progress
        for listener in consoleListeners.values {
            listener(redraw)
        }
    }

    private func endConsoleProgressLine(generation: UInt64) {
        guard self.generation == generation else { return }
        consoleProgressEpoch &+= 1
        guard openConsoleProgress != nil else { return }
        openConsoleProgress = nil
        appendConsole(Data("\r\n".utf8), generation: generation)
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
        consoleListeners.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func detachRuntimeForShutdown() -> LinuxRuntime? {
        onWillShutdown?()
        setupTerminal?.close()
        setupTerminal = nil
        let current = runtime
        runtime = nil
        if let current {
            HostClipboard.shared.detach(from: current)
            HostPasteStaging.shared.detach(from: current)
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
        let teardown = pendingTeardown
        Task.detached(priority: .utility) {
            await teardown?.value
            Self.emptyTrash()
        }
    }

    private func startRuntime(
        _ container: LinuxContainer,
        initMode: LinuxRuntime.Configuration.InitMode,
        generation: UInt64
    ) async throws -> LinuxRuntime {
        await pendingTeardown?.value
        guard self.generation == generation else { throw CancellationError() }
        bootCount &+= 1
        let boot = bootCount
        let normalizer = ConsoleNewlineNormalizer()
        let metadata = container.metadata
        let configuration = LinuxRuntime.Configuration(
            root: Self.rootURL(for: container.id),
            initMode: initMode,
            hostname: metadata.name,
            consoleOutput: { data in
                let chunk = normalizer.normalize(data)
                guard !chunk.isEmpty else { return }
                Task { @MainActor in
                    LinuxSystem.shared.appendConsole(chunk, generation: generation)
                }
            },
            haltHandler: { reason in
                Task { @MainActor in
                    LinuxSystem.shared.runtimeDidHalt(reason, generation: generation, boot: boot)
                }
            },
            clipboard: HostClipboard.shared
        )
        let bootedRuntime = try await LinuxRuntime.boot(configuration) { runtime in
            try await Self.prepareGuestEnvironment(runtime, metadata: metadata)
        }
        guard self.generation == generation else {
            tearDownInBackground(bootedRuntime)
            throw CancellationError()
        }
        runtime = bootedRuntime
        runtimeBoot = boot
        if isSuspended {
            bootedRuntime.suspend()
        }
        return bootedRuntime
    }

    private func bootInstalledRoot(_ container: LinuxContainer, generation: UInt64) async {
        consoleChunks.removeAll()
        state = .booting
        do {
            try await bootRoot(container, generation: generation)
            state = .running
            completeRunningWaiters()
        } catch is CancellationError {
            guard self.generation == generation else { return }
            cancelRunningWaiters()
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            state = .setup
        } catch {
            guard self.generation == generation else { return }
            cancelRunningWaiters()
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            state = .failed(Self.failureMessage(error))
        }
    }

    private func bootRoot(_ container: LinuxContainer, generation: UInt64) async throws {
        var reboots = 0
        while true {
            let bootedRuntime = try await startRuntime(container, initMode: .system, generation: generation)
            let boot = runtimeBoot
            appendBootedKernel(bootedRuntime.bootedKernel, generation: generation)

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
            appendConsole(Data("\r\n\u{1B}[1m==> Rebooting\u{1B}[0m\r\n".utf8), generation: generation)
        }
    }

    private func appendBootedKernel(_ kernel: LinuxRuntime.BootedKernel, generation: UInt64) {
        var log = "\u{1B}[1m==> Linux \(kernel.release)\u{1B}[0m\r\n"
        if let fallbackReason = kernel.fallbackReason {
            log += "\u{1B}[1;33mwarning:\u{1B}[0m \(fallbackReason.replacingOccurrences(of: "\n", with: "\r\n"))\r\n"
        }
        appendConsole(Data(log.utf8), generation: generation)
    }

    private nonisolated static func failureMessage(_ error: any Error) -> String {
        guard let error = error as? LinuxRuntime.KernelUnavailableError else {
            return error.localizedDescription
        }
        let message = String(localized: "This system has no kernel that can boot on this device. Use an archive that includes a 4K-page ARM64 kernel.")
        return error.reasons.isEmpty ? message : message + "\n\n" + error.reasons.joined(separator: "\n")
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

    private func provision(_ container: LinuxContainer, generation: UInt64) async {
        haltedDuringProvisioning = false
        var metadata = container.metadata
        do {
            let (runtime, release) = try await bootForProvisioning(container, generation: generation)
            if metadata.distributionID == nil {
                metadata.distributionID = release?.distribution?.rawValue
            }

            let terminal = try runtime.makeTerminal(size: setupTerminalSize)
            setupTerminal = terminal
            let output = Task.detached {
                for await chunk in terminal.output {
                    await LinuxSystem.shared.appendConsole(chunk, generation: generation)
                }
            }
            let request = ContainerProvisioner.Request(
                hostname: metadata.name,
                user: metadata.defaultUser,
                password: metadata.setup?.password,
                software: metadata.setup?.software ?? ContainerSoftware()
            )
            let termination: LinuxProcess.Termination
            do {
                let process = try await ContainerProvisioner.start(
                    on: runtime,
                    terminal: terminal,
                    request: request,
                    release: release
                )
                termination = await process.termination
            } catch {
                terminal.close()
                await output.value
                throw error
            }
            let drainDeadline = Task {
                try? await Task.sleep(for: Self.outputDrainTimeout)
                terminal.close()
            }
            await output.value
            drainDeadline.cancel()
            terminal.close()
            if setupTerminal === terminal {
                setupTerminal = nil
            }

            guard self.generation == generation else { return }
            if haltedDuringProvisioning {
                throw StartupError.halted
            }
            switch termination {
            case .exited(0):
                break
            case let .exited(code):
                throw StartupError.exited(code)
            case let .signaled(signal):
                throw StartupError.signaled(signal.rawValue)
            }

            metadata.setupCompleted = true
            metadata.setup = nil
            let completed = LinuxContainer(id: container.id, metadata: metadata)
            try await Task.detached {
                try Self.saveContainerMetadata(completed.metadata, root: Self.rootURL(for: completed.id))
            }.value
            guard self.generation == generation else { return }
            containers = containers.map { $0.id == completed.id ? completed : $0 }
            switchActiveContainer(to: completed.id)

            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            await bootInstalledRoot(completed, generation: generation)
        } catch {
            guard self.generation == generation else { return }
            await shutDownDetachedRuntime()
            guard self.generation == generation else { return }
            let message = haltedDuringProvisioning && !(error is StartupError)
                ? StartupError.halted.localizedDescription
                : Self.failureMessage(error)
            state = .provisioning(Provisioning(attempt: provisioningAttempt, failure: message))
        }
    }

    private func bootForProvisioning(_ container: LinuxContainer, generation: UInt64) async throws -> (LinuxRuntime, OSRelease?) {
        let bootedRuntime = try await startRuntime(container, initMode: .managed, generation: generation)
        appendBootedKernel(bootedRuntime.bootedKernel, generation: generation)
        do {
            try await bootedRuntime.waitReady(.login, timeout: Self.loginTimeout)
        } catch let error as LinuxError where error == .ESRCH {
            throw StartupError.halted
        }
        try Task.checkCancellation()
        return (bootedRuntime, await ContainerProvisioner.detectRelease(on: bootedRuntime))
    }

    private func appendConsole(_ chunk: Data, generation: UInt64) {
        guard self.generation == generation, acceptsConsoleOutput else { return }
        consoleChunks.append(chunk)
        for listener in consoleListeners.values {
            listener(chunk)
        }
    }

    private func runtimeDidHalt(_ reason: LinuxRuntime.HaltReason, generation: UInt64, boot: UInt64) {
        guard self.generation == generation, let runtime, runtimeBoot == boot else { return }
        if state == .booting, awaitingBootReadiness {
            bootHalt = reason
            resumeBootHaltWaiter(boot)
            return
        }
        if case .provisioning = state {
            haltedDuringProvisioning = true
            shutDownHaltedRuntime(runtime)
            return
        }
        switch reason {
        case .reboot:
            restart()
        case .powerOff, .exited:
            _ = beginOperation()
            state = .halted
            resetConsole()
            activeTask = shutDownHaltedRuntime(runtime)
        }
    }

    @discardableResult
    private func shutDownHaltedRuntime(_ halted: LinuxRuntime) -> Task<Void, Never> {
        onWillShutdown?()
        setupTerminal?.close()
        setupTerminal = nil
        HostClipboard.shared.detach(from: halted)
        HostPasteStaging.shared.detach(from: halted)
        return Task {
            await shutDownRuntime(halted)
            if runtime === halted {
                runtime = nil
            }
        }
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDidEnterBackground()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillEnterForeground()
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    HostLocation.shared.reconcile()
                }
            },
        ]
        HostLocation.shared.onBackgroundKeepAliveChange = { [weak self] in
            guard let self else { return }
            if HostLocation.shared.isKeepingBackgroundAlive {
                if self.isSuspended {
                    self.isSuspended = false
                    self.runtime?.resume()
                }
            } else if self.isInBackground, self.backgroundTaskID == .invalid {
                self.suspendRuntimeIfNeeded()
            }
        }
    }

    private func handleDidEnterBackground() {
        isInBackground = true
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Swipterm.LinuxRuntime") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !HostLocation.shared.isKeepingBackgroundAlive {
                    self.suspendRuntimeIfNeeded()
                }
                self.endBackgroundTaskIfNeeded()
            }
        }
        if backgroundTaskID == .invalid, !HostLocation.shared.isKeepingBackgroundAlive {
            suspendRuntimeIfNeeded()
        }
    }

    private func handleWillEnterForeground() {
        isInBackground = false
        endBackgroundTaskIfNeeded()
        if isSuspended {
            isSuspended = false
            runtime?.resume()
        }
    }

    private func suspendRuntimeIfNeeded() {
        guard !isSuspended else { return }
        isSuspended = true
        runtime?.suspend()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func requestLocalNetworkAuthorizationIfNeeded() {
        guard let url = URL(string: "https://captive.apple.com") else { return }
        URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
    }

    nonisolated static func dataSize(of container: LinuxContainer) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL(for: container.id),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else {
            return 0
        }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            size += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return size
    }

    private nonisolated static let activeContainerKey = "activeContainer"
    private nonisolated static let containerMetadataName = "swipterm-machine.json"
    private nonisolated static let guestMetadataPath = "/etc/swipterm-container.json"
    private nonisolated static let stagingPrefix = ".installing."
    private nonisolated static let trashPrefix = ".trash."

    private nonisolated static var containersDirectoryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Containers", directoryHint: .isDirectory)
    }

    private nonisolated static var downloadStagingDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermDownloads", directoryHint: .isDirectory)
    }

    private nonisolated static var exportDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermExports", directoryHint: .isDirectory)
    }

    private nonisolated static func rootURL(for id: String) -> URL {
        containersDirectoryURL.appending(path: id, directoryHint: .isDirectory)
    }

    private nonisolated static func migrateLegacyRoot() {
        let fm = FileManager.default
        for item in items(in: URL.applicationSupportDirectory, withPrefix: ".Root.") {
            try? fm.removeItem(at: item)
        }
        let legacyRootURL = URL.applicationSupportDirectory.appending(path: "Root", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: legacyRootURL.path(percentEncoded: false)) else { return }
        try? fm.createDirectory(at: containersDirectoryURL, withIntermediateDirectories: true)
        try? fm.moveItem(at: legacyRootURL, to: rootURL(for: UUID().uuidString))
    }

    private nonisolated static func loadContainers() -> [LinuxContainer] {
        var containers: [LinuxContainer] = []
        for url in items(in: containersDirectoryURL, withPrefix: "") where !url.lastPathComponent.hasPrefix(trashPrefix) {
            guard !url.lastPathComponent.hasPrefix(stagingPrefix),
                  LinuxRootImage.isInstalled(at: url),
                  let data = try? Data(contentsOf: url.appending(path: containerMetadataName)),
                  let metadata = try? JSONDecoder().decode(ContainerMetadata.self, from: data)
            else {
                moveToTrash(url)
                continue
            }
            containers.append(LinuxContainer(id: url.lastPathComponent, metadata: metadata))
        }
        return containers.sorted { $0.metadata.installedAt < $1.metadata.installedAt }
    }

    private nonisolated static func saveContainerMetadata(_ metadata: ContainerMetadata, root: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(
            to: root.appending(path: containerMetadataName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private nonisolated static func makeMetadata(for creation: InstallRequest.Creation) -> ContainerMetadata {
        var release: LinuxReleaseImage?
        if case let .catalog(catalogRelease) = creation.source {
            release = catalogRelease
        }
        return ContainerMetadata(
            name: creation.containerName,
            distributionID: release?.distribution.rawValue,
            installedAt: Date(),
            defaultUser: creation.user,
            setupCompleted: false,
            setup: ContainerSetup(password: creation.password, software: creation.software)
        )
    }

    private nonisolated static func stageLocalArchive(from sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let stagingDir = downloadStagingDirectoryURL
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let destination = stagingDir.appending(path: "\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        try sourceURL.withSecurityScopedAccess {
            try fm.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    private nonisolated static func moveToTrash(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let trashURL = url.deletingLastPathComponent()
            .appending(path: trashPrefix + UUID().uuidString, directoryHint: .isDirectory)
        if (try? fm.moveItem(at: url, to: trashURL)) == nil {
            try? fm.removeItem(at: url)
        }
    }

    private nonisolated static func emptyTrash() {
        for directory in [containersDirectoryURL, FileManager.default.temporaryDirectory] {
            for item in items(in: directory, withPrefix: trashPrefix) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private nonisolated static func items(in directory: URL, withPrefix prefix: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private nonisolated static func osRelease(in builder: LinuxRootImageBuilder) throws -> OSRelease? {
        for path in ["/etc/os-release", "/usr/lib/os-release"] {
            if let data = try builder.contents(of: path) {
                return OSRelease(String(decoding: data, as: UTF8.self))
            }
        }
        return nil
    }

    private nonisolated static func hasSystemInit(in builder: LinuxRootImageBuilder) -> Bool {
        guard let initBinary = try? builder.contents(of: "/sbin/init") else { return false }
        for path in ["/bin/busybox", "/usr/bin/busybox"] {
            if (try? builder.contents(of: path)) == initBinary {
                return (try? builder.contents(of: "/sbin/openrc")) != nil
                    || (try? builder.contents(of: "/usr/bin/openrc")) != nil
            }
        }
        return true
    }

    private nonisolated static func prepareGuestEnvironment(_ runtime: LinuxRuntime, metadata: ContainerMetadata) async throws {
        if metadata.setupCompleted {
            try? await runtime.fileSystem.writeFile(guestMetadataPath, contents: JSONEncoder().encode(metadata))
        } else {
            try await runtime.fileSystem.writeFile("/etc/hostname", contents: Data("\(metadata.name)\n".utf8), permissions: 0o644)
        }
        if HostPasteStaging.prepareHostDirectory() {
            var mountedVirtioFS = false
            do {
                try await runtime.mount(HostPasteStaging.hostDirectory, at: HostPasteStaging.guestDirectory, readOnly: true)
                mountedVirtioFS = true
            } catch let error as LinuxError where error == .ENODEV {
                try? await runtime.fileSystem.createDirectory(
                    HostPasteStaging.guestDirectory,
                    permissions: 0o755,
                    withIntermediateDirectories: true
                )
            }
            HostPasteStaging.shared.attach(to: runtime, usesVirtioFS: mountedVirtioFS)
        }
        do {
            try await runtime.registerDevice(at: "/dev/clipboard", handler: ClipboardDevice())
        } catch let error as LinuxError where error == .ENODEV {}
        HostClipboard.shared.attach(to: runtime)
        try await HostCommands.register(on: runtime)
    }
}

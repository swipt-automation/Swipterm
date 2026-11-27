import Foundation
import Observation
import SwiptermKit

@Observable
final class ContainerCreation: Identifiable {
    nonisolated enum Request: Sendable {
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

    nonisolated struct Job: Codable, Sendable {
        enum Source: Codable, Sendable {
            case catalog(LinuxReleaseImage)
            case remoteArchive(URL)
            case localArchive(bookmark: Data, name: String)

            var archiveName: String {
                switch self {
                case let .catalog(release):
                    release.archiveURL.lastPathComponent
                case let .remoteArchive(url):
                    url.lastPathComponent
                case let .localArchive(_, name):
                    name
                }
            }
        }

        let id: String
        let source: Source?
        let metadata: ContainerMetadata?
    }

    enum State: Equatable {
        case running
        case failed(String)
        case finished(LinuxContainer)
    }

    private nonisolated enum Failure: LocalizedError {
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

    private static let loginTimeout = Duration.seconds(300)
    private static let outputDrainTimeout = Duration.seconds(1)
    private nonisolated static let installMetadataName = "metadata.json"

    let id: String
    let name: String
    let activatesWhenFinished: Bool
    private(set) var state = State.running
    private(set) var attempt = 0
    private(set) var console = ConsoleBuffer()

    @ObservationIgnored private let job: Job
    @ObservationIgnored private let store: ContainerStore
    @ObservationIgnored private let system: LinuxSystem
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var terminal: LinuxTerminal?
    @ObservationIgnored private var terminalSize = LinuxTerminal.Size(columns: 40, rows: 24)

    init(job: Job, name: String, store: ContainerStore, system: LinuxSystem) {
        id = job.id
        self.name = name
        self.job = job
        self.store = store
        self.system = system
        activatesWhenFinished = store.containers.isEmpty
    }

    convenience init(request: Request, store: ContainerStore, system: LinuxSystem) throws {
        let source: Job.Source
        let metadata: ContainerMetadata?
        let name: String
        switch request {
        case let .create(creation):
            var release: LinuxReleaseImage?
            switch creation.source {
            case let .catalog(catalogRelease):
                source = .catalog(catalogRelease)
                release = catalogRelease
            case let .remoteArchive(url):
                source = .remoteArchive(url)
            case let .localArchive(url):
                source = try .localArchive(
                    bookmark: url.withSecurityScopedAccess { try url.bookmarkData(options: .minimalBookmark) },
                    name: url.lastPathComponent
                )
            }
            name = creation.containerName
            metadata = ContainerMetadata(
                name: creation.containerName,
                distributionID: release?.distribution.rawValue,
                installedAt: Date(),
                defaultUser: creation.user,
                setupCompleted: false,
                setup: ContainerSetup(password: creation.password, software: creation.software)
            )
        case let .importArchive(url):
            source = try .localArchive(
                bookmark: url.withSecurityScopedAccess { try url.bookmarkData(options: .minimalBookmark) },
                name: url.lastPathComponent
            )
            name = url.deletingPathExtension().lastPathComponent
            metadata = nil
        }
        let job = Job(id: UUID().uuidString, source: source, metadata: metadata)
        try ContainerStore.saveJob(job)
        self.init(job: job, name: name, store: store, system: system)
    }

    func start() {
        attempt += 1
        console = ConsoleBuffer()
        console.resize(columns: terminalSize.columns)
        state = .running
        system.guestActivityDidChange()
        let console = console
        task = Task {
            do {
                let container = try await run(console: console)
                guard !Task.isCancelled else { return }
                console.close()
                state = .finished(container)
                store.register(container)
                store.remove(self)
                if activatesWhenFinished {
                    system.activate(container)
                }
            } catch {
                guard !Task.isCancelled else { return }
                console.appendError(error.localizedDescription)
                console.close()
                state = .failed(error.localizedDescription)
            }
            system.guestActivityDidChange()
        }
    }

    func cancel() {
        let task = task
        task?.cancel()
        terminal?.close()
        console.close()
        store.remove(self)
        system.guestActivityDidChange()
        let id = id
        store.emptyTrash(after: Task {
            await task?.value
            ContainerStore.moveToTrash(ContainerStore.installDirectoryURL(for: id))
            ContainerStore.moveToTrash(ContainerStore.rootURL(for: id))
        })
    }

    func completion() async -> State {
        await task?.value
        return state
    }

    func resizeTerminal(columns: UInt16, rows: UInt16) {
        terminalSize = LinuxTerminal.Size(columns: columns, rows: rows)
        terminal?.resize(terminalSize)
        console.resize(columns: columns)
    }

    private func run(console: ConsoleBuffer) async throws -> LinuxContainer {
        let root = ContainerStore.rootURL(for: id)
        var metadata: ContainerMetadata
        if let source = job.source, !LinuxRootImage.isInstalled(at: root) {
            let directory = ContainerStore.installDirectoryURL(for: id)
            let imageURL = directory.appending(path: "root", directoryHint: .isDirectory)
            if !LinuxRootImage.isInstalled(at: imageURL) {
                try await buildImage(from: source, at: imageURL, console: console)
            }
            metadata = try await Task.detached {
                let metadata = try JSONDecoder().decode(
                    ContainerMetadata.self,
                    from: Data(contentsOf: directory.appending(path: Self.installMetadataName))
                )
                try ContainerStore.saveMetadata(metadata, root: imageURL)
                return metadata
            }.value
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: imageURL, to: root)
            ContainerStore.moveToTrash(directory)
            store.emptyTrash()
        } else {
            metadata = try await Task.detached {
                try ContainerStore.metadata(at: root)
            }.value
        }
        if !metadata.setupCompleted {
            try await provision(&metadata, console: console)
        }
        return LinuxContainer(id: id, metadata: metadata)
    }

    private func buildImage(from source: Job.Source, at imageURL: URL, console: ConsoleBuffer) async throws {
        let directory = imageURL.deletingLastPathComponent()
        let archiveURL = directory.appending(path: "archive" + Self.archiveExtension(of: source.archiveName))
        if !FileManager.default.fileExists(atPath: archiveURL.path(percentEncoded: false)) {
            try await fetchArchive(source, to: archiveURL, console: console)
            try Task.checkCancellation()
        }

        console.appendStep(String(localized: "Extracting Archive"))
        let builder = try LinuxRootImageBuilder(root: imageURL)
        try await unpack(nil, console: console) { progress in
            try await builder.add(.archive(at: archiveURL), progress: progress)
        }
        try Task.checkCancellation()
        var metadata: ContainerMetadata
        if let jobMetadata = job.metadata {
            guard try ContainerStore.hasSystemInit(read: builder.contents(of:)) else {
                throw Failure.missingInit
            }
            let release = try ContainerStore.osRelease(read: builder.contents(of:))
            metadata = jobMetadata
            if metadata.distributionID == nil {
                metadata.distributionID = release?.distribution?.rawValue
            }
            if case let .catalog(catalogRelease) = source {
                guard let release else {
                    throw KernelBootstrapError.unknownRelease
                }
                try await installKernel(catalogRelease.distribution, release: release, into: builder, directory: directory, console: console)
            } else if let release, let distribution = release.distribution, try !Self.hasKernel(in: builder) {
                try await installKernel(distribution, release: release, into: builder, directory: directory, console: console)
            }
            try Task.checkCancellation()
            var installed = metadata
            installed.setupCompleted = true
            installed.setup = nil
            try builder.write(JSONEncoder().encode(installed), to: ContainerStore.guestMetadataPath)
        } else {
            guard let exported = try builder.contents(of: ContainerStore.guestMetadataPath) else {
                throw Failure.notContainer
            }
            metadata = try JSONDecoder().decode(ContainerMetadata.self, from: exported)
        }
        try JSONEncoder().encode(metadata).write(
            to: directory.appending(path: Self.installMetadataName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )

        console.appendStep(String(localized: "Writing Disk"))
        try await builder.finish()
        try Task.checkCancellation()
    }

    private func fetchArchive(_ source: Job.Source, to destination: URL, console: ConsoleBuffer) async throws {
        switch source {
        case let .catalog(release):
            console.appendStep(String(localized: "Downloading Image"))
            let url = release.archiveURL
            try await download(url, to: destination, name: url.host()!, console: console)
        case let .remoteArchive(url):
            console.appendStep(String(localized: "Downloading Archive"))
            try await download(url, to: destination, name: url.host()!, console: console)
        case let .localArchive(bookmark, _):
            console.appendStep(String(localized: "Copying Archive"))
            try await Task.detached {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
                let partial = destination.appendingPathExtension("partial")
                try? FileManager.default.removeItem(at: partial)
                try url.withSecurityScopedAccess {
                    try FileManager.default.copyItem(at: url, to: partial)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
            }.value
        }
    }

    private func installKernel(
        _ distribution: LinuxDistribution,
        release: OSRelease,
        into builder: LinuxRootImageBuilder,
        directory: URL,
        console: ConsoleBuffer
    ) async throws {
        console.appendStep(String(localized: "Installing Kernel"))
        let packageDirectory = directory.appending(path: "kernel", directoryHint: .isDirectory)
        let indexDirectory = directory.appending(path: "kernel-index", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: indexDirectory)
        }
        let bootstrap = KernelBootstrap(distribution: distribution, release: release)
        let packages = try await bootstrap.packages { url in
            let destination = indexDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            try await self.download(url, to: destination, name: url.lastPathComponent, console: console)
            return destination
        }
        var files: [URL] = []
        for package in packages {
            let file = packageDirectory.appending(path: package.url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try await download(package.url, to: file, name: package.url.lastPathComponent, console: console)
            }
            files.append(file)
        }
        var installed: [KernelBootstrap.Installed] = []
        for (package, file) in zip(packages, files) {
            let contents = try await unpack(package.name, console: console) { progress in
                try await builder.addPackage(at: file, progress: progress)
            }
            installed.append(KernelBootstrap.Installed(package: package, file: file, contents: contents))
        }
        try await bootstrap.register(installed, in: builder)
    }

    private func download(_ url: URL, to destination: URL, name: String, console: ConsoleBuffer) async throws {
        let partial = destination.appendingPathExtension("partial")
        let epoch = console.progressEpoch
        let start = ContinuousClock.now
        defer {
            console.endProgress()
        }
        try await HTTPClient.download(from: url, to: partial) { bytesWritten, totalBytes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    console.updateDownload(bytesWritten: bytesWritten, totalBytes: totalBytes, name: name, start: start, epoch: epoch)
                }
            }
        }.requireSuccess()
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func unpack<Result>(
        _ name: String?,
        console: ConsoleBuffer,
        _ body: (@escaping @Sendable (Double) -> Void) async throws -> Result
    ) async throws -> Result {
        let epoch = console.progressEpoch
        let start = ContinuousClock.now
        let result = try await body { fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    console.updateProgress(.extraction(name: name, fraction: fraction, elapsed: start.duration(to: .now)), epoch: epoch)
                }
            }
        }
        console.updateProgress(.extraction(name: name, fraction: 1, elapsed: start.duration(to: .now)), epoch: epoch)
        console.endProgress()
        return result
    }

    private func provision(_ metadata: inout ContainerMetadata, console: ConsoleBuffer) async throws {
        let root = ContainerStore.rootURL(for: id)
        let release = try await Task.detached {
            try ContainerStore.osRelease { try LinuxRootImage.contents(of: $0, at: root) }
        }.value
        if metadata.distributionID == nil {
            metadata.distributionID = release?.distribution?.rawValue
        }
        let setup = metadata.setup!
        let request = ContainerProvisioner.Request(
            hostname: metadata.name,
            user: metadata.defaultUser,
            password: setup.password,
            software: setup.software
        )
        var installed = metadata
        installed.setupCompleted = true
        installed.setup = nil
        let completed = installed
        let guestMetadata = try JSONEncoder().encode(completed)

        if let runtime = await system.runningRuntime() {
            do {
                try await store.withDisk(id: id, name: metadata.name) { disk in
                    try await initialize(on: runtime, request: request, release: release, console: console) {
                        try await disk.spawn($0, hostname: request.hostname)
                    }
                }
            } catch {
                throw store.runtime === runtime ? error : Failure.halted
            }
        } else {
            try await system.withManagedRuntime(root: root, hostname: metadata.name) { runtime in
                console.appendStep(String(localized: "Starting Linux"))
                do {
                    try await runtime.waitReady(.login, timeout: Self.loginTimeout)
                } catch let error as LinuxError where error == .ESRCH {
                    throw Failure.halted
                }
                try await initialize(on: runtime, request: request, release: release, console: console, spawn: runtime.spawn)
                try await runtime.fileSystem.writeFile(ContainerStore.guestMetadataPath, contents: guestMetadata)
            }
        }
        try Task.checkCancellation()
        try await Task.detached {
            try ContainerStore.saveMetadata(completed, root: root)
        }.value
        metadata = completed
    }

    private func initialize(
        on runtime: LinuxRuntime,
        request: ContainerProvisioner.Request,
        release: OSRelease?,
        console: ConsoleBuffer,
        spawn: (LinuxProcess.Configuration) async throws -> LinuxProcess
    ) async throws {
        let terminal = try runtime.makeTerminal(size: terminalSize)
        self.terminal = terminal
        defer {
            terminal.close()
            if self.terminal === terminal {
                self.terminal = nil
            }
        }
        let output = Task.detached {
            var filter = ConsoleBlankLineFilter()
            for await chunk in terminal.output {
                let visible = filter.filter(chunk)
                guard !visible.isEmpty else { continue }
                await console.append(visible)
            }
        }
        let termination: LinuxProcess.Termination
        do {
            let process = try await spawn(ContainerProvisioner.configuration(terminal: terminal, request: request, release: release))
            termination = await withTaskCancellationHandler {
                await process.termination
            } onCancel: {
                try? process.send(.kill)
            }
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
        try Task.checkCancellation()
        switch termination {
        case .exited(0):
            break
        case let .exited(code):
            throw Failure.exited(code)
        case let .signaled(signal):
            throw Failure.signaled(signal.rawValue)
        }
    }

    private nonisolated static func hasKernel(in builder: LinuxRootImageBuilder) throws -> Bool {
        for directory in ["/lib/modules", "/usr/lib/modules"] {
            if try builder.contentsOfDirectory(at: directory)?.isEmpty == false {
                return true
            }
        }
        return false
    }

    private nonisolated static func archiveExtension(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".tar.xz", ".tar.zst", ".tar.gz", ".tar.bz2", ".tgz", ".txz", ".tzst", ".tbz2", ".tar"] where lower.hasSuffix(suffix) {
            return suffix
        }
        return ".tar"
    }
}

import Foundation
import Observation
import SwiptermKit

nonisolated enum ContainerOccupancy: Equatable, Sendable {
    case mounted(path: String, readOnly: Bool)
    case entered
    case exporting
}

nonisolated enum ContainerError: LocalizedError {
    case busy(String)
    case active(String)
    case readOnly(String)
    case notMounted(String)
    case noMachine
    case halted

    var errorDescription: String? {
        switch self {
        case let .busy(name):
            String(localized: "\(name) is in use.")
        case let .active(name):
            String(localized: "\(name) is the active container.")
        case let .readOnly(name):
            String(localized: "\(name) is mounted read-only; unmount it first.")
        case let .notMounted(name):
            String(localized: "\(name) isn’t mounted.")
        case .noMachine:
            String(localized: "No container is running.")
        case .halted:
            String(localized: "The container stopped unexpectedly.")
        }
    }
}

nonisolated struct ContainerReadiness: Sendable {
    let kernels: [String]
    let hasInit: Bool
    let hasDefaultUser: Bool
    let release: OSRelease?

    var isReady: Bool {
        !kernels.isEmpty && hasInit && hasDefaultUser
    }
}

nonisolated struct ContainerSetup: Codable, Equatable, Sendable {
    var password: String?
    var software: ContainerSoftware
}

nonisolated struct ContainerMetadata: Codable, Equatable, Sendable {
    let name: String
    var distributionID: String?
    let installedAt: Date
    var defaultUser: String
    var setupCompleted: Bool
    var setup: ContainerSetup?

    var distribution: LinuxDistribution? {
        distributionID.flatMap(LinuxDistribution.init(rawValue:))
    }

    var completed: ContainerMetadata {
        var metadata = self
        metadata.setupCompleted = true
        metadata.setup = nil
        return metadata
    }
}

nonisolated struct LinuxContainer: Identifiable, Equatable, Sendable {
    let id: String
    var metadata: ContainerMetadata

    static func sanitizedName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = String(raw.lowercased().map { allowed.contains($0) ? $0 : "-" })
        let collapsed = cleaned
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "linux" : String(collapsed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

@Observable
final class ContainerStore {
    private struct Attachment {
        let disk: LinuxDisk
        var mountPath: String?
        var users = 0
    }

    private(set) var containers: [LinuxContainer] = []
    private(set) var creations: [ContainerCreation] = []
    private(set) var activeContainerID: String? {
        didSet {
            if let activeContainerID {
                preferences.set(activeContainerID, for: Self.activeContainerKey)
            } else {
                preferences.remove(Self.activeContainerKey)
            }
        }
    }

    private(set) var exportProgress: [String: Double] = [:]
    private var attachments: [String: Attachment] = [:]
    private var transitions: Set<String> = []
    @ObservationIgnored var runtime: LinuxRuntime?
    @ObservationIgnored private var pendingTrashRemoval: Task<Void, Never>?
    @ObservationIgnored private let preferences: PreferenceStore

    init(preferences: PreferenceStore) {
        self.preferences = preferences
    }

    var activeContainer: LinuxContainer? {
        containers.first { $0.id == activeContainerID }
    }

    func occupancy(of id: String) -> ContainerOccupancy? {
        if exportProgress[id] != nil {
            return .exporting
        }
        guard let attachment = attachments[id] else {
            return transitions.contains(id) ? .entered : nil
        }
        if let path = attachment.mountPath {
            return .mounted(path: path, readOnly: attachment.disk.isReadOnly)
        }
        return .entered
    }

    func load() async -> [ContainerCreation.Job] {
        let (stored, jobs) = await Task.detached { () -> ([LinuxContainer], [ContainerCreation.Job]) in
            try! FileManager.default.createDirectory(at: Self.containersDirectoryURL, withIntermediateDirectories: true)
            Self.moveToTrash(Self.exportDirectoryURL)
            Self.migrateLegacyRoot()
            let stored = Self.loadContainers()
            return (stored, Self.loadJobs(excluding: stored))
        }.value
        emptyTrash()
        containers = stored.filter(\.metadata.setupCompleted)
        let storedID = preferences.value(String.self, for: Self.activeContainerKey)
        activeContainerID = containers.contains { $0.id == storedID } ? storedID : containers.first?.id
        return jobs + stored.filter { !$0.metadata.setupCompleted }.map { ContainerCreation.Job(id: $0.id, source: nil, metadata: $0.metadata) }
    }

    func activate(_ id: String?) {
        activeContainerID = id
        try! HostPasteStaging.removeAllFiles()
    }

    func add(_ creation: ContainerCreation) {
        creations.append(creation)
    }

    func remove(_ creation: ContainerCreation) {
        creations.removeAll { $0 === creation }
    }

    func register(_ container: LinuxContainer) {
        containers.append(container)
    }

    func update(_ container: LinuxContainer) async throws {
        try await Task.detached {
            try Self.saveMetadata(container.metadata, root: Self.rootURL(for: container.id))
        }.value
        containers = containers.map { $0.id == container.id ? container : $0 }
    }

    func createBlank(name: String, user: String) async throws -> LinuxContainer {
        let metadata = ContainerMetadata(name: name, distributionID: nil, installedAt: Date(), defaultUser: user, setupCompleted: true, setup: nil)
        let container = LinuxContainer(id: UUID().uuidString, metadata: metadata)
        let root = Self.rootURL(for: container.id)
        try await Task.detached {
            let builder = try LinuxRootImageBuilder(root: root)
            try builder.write(JSONEncoder().encode(metadata), to: Self.guestMetadataPath)
            try await builder.finish()
            try Self.saveMetadata(metadata, root: root)
        }.value
        containers.append(container)
        return container
    }

    func delete(_ container: LinuxContainer) throws {
        guard occupancy(of: container.id) == nil else {
            throw ContainerError.busy(container.metadata.name)
        }
        containers.removeAll { $0.id == container.id }
        Self.moveToTrash(Self.rootURL(for: container.id))
        emptyTrash()
    }

    func export(_ container: LinuxContainer, prepare: () async throws -> Void = {}) async throws -> URL {
        guard occupancy(of: container.id) == nil else {
            throw ContainerError.busy(container.metadata.name)
        }
        exportProgress[container.id] = 0
        defer {
            exportProgress[container.id] = nil
        }
        try await prepare()
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: Self.exportDirectoryURL, withIntermediateDirectories: true)
        let archiveURL = Self.exportDirectoryURL.appending(path: "\(container.metadata.name).tar.gz")
        let id = container.id
        try await LinuxRootImage.export(from: Self.rootURL(for: id), to: archiveURL) { fraction in
            Task { @MainActor in
                if self.exportProgress[id] != nil {
                    self.exportProgress[id] = fraction
                }
            }
        }
        return archiveURL
    }

    func readiness(of container: LinuxContainer) async throws -> ContainerReadiness {
        guard occupancy(of: container.id) == nil, container.id != activeContainerID else {
            throw ContainerError.busy(container.metadata.name)
        }
        let user = container.metadata.defaultUser
        return try await Task.detached {
            let root = Self.rootURL(for: container.id)
            let accounts = try LinuxRootImage.contents(of: "/etc/passwd", at: root).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return try ContainerReadiness(
                kernels: LinuxRootImage.installedKernels(at: root),
                hasInit: Self.hasSystemInit { try LinuxRootImage.contents(of: $0, at: root) },
                hasDefaultUser: accounts.split(separator: "\n").contains { $0.hasPrefix(user + ":") },
                release: Self.osRelease { try LinuxRootImage.contents(of: $0, at: root) }
            )
        }.value
    }

    func mount(_ container: LinuxContainer, at path: String, readOnly: Bool) async throws {
        try await transition(container) {
            if let attachment = attachments[container.id] {
                guard attachment.mountPath == nil else {
                    throw ContainerError.busy(container.metadata.name)
                }
                guard readOnly || !attachment.disk.isReadOnly else {
                    throw ContainerError.readOnly(container.metadata.name)
                }
                try await attachment.disk.mount(at: path)
            } else {
                let disk = try await attach(container.id, readOnly: readOnly)
                do {
                    try await disk.mount(at: path)
                } catch {
                    try? await disk.detach()
                    attachments[container.id] = nil
                    throw error
                }
            }
            attachments[container.id]?.mountPath = path
        }
    }

    func unmount(_ container: LinuxContainer) async throws {
        try await transition(container) {
            guard let attachment = attachments[container.id], let path = attachment.mountPath else {
                throw ContainerError.notMounted(container.metadata.name)
            }
            if attachment.users == 0 {
                try await attachment.disk.detach()
                attachments[container.id] = nil
            } else {
                try await attachment.disk.unmount(at: path)
                attachments[container.id]?.mountPath = nil
            }
        }
    }

    func container(mountedAt path: String) -> LinuxContainer? {
        containers.first { attachments[$0.id]?.mountPath == path }
    }

    func withDisk<Result>(
        id: String,
        name: String,
        _ body: (LinuxDisk) async throws -> Result
    ) async throws -> Result {
        guard !transitions.contains(id), exportProgress[id] == nil else {
            throw ContainerError.busy(name)
        }
        if let attachment = attachments[id] {
            guard !attachment.disk.isReadOnly else {
                throw ContainerError.readOnly(name)
            }
        } else {
            transitions.insert(id)
            defer { transitions.remove(id) }
            _ = try await attach(id, readOnly: false)
        }
        let disk = attachments[id]!.disk
        attachments[id]!.users += 1
        defer {
            if attachments[id]?.disk === disk {
                attachments[id]!.users -= 1
                if attachments[id]!.users == 0, attachments[id]!.mountPath == nil {
                    attachments[id] = nil
                    transitions.insert(id)
                    Task {
                        try? await disk.detach()
                        transitions.remove(id)
                    }
                }
            }
        }
        return try await body(disk)
    }

    func runtimeDidStop() {
        runtime = nil
        attachments.removeAll()
    }

    func emptyTrash(after teardown: Task<Void, Never>? = nil) {
        let previous = pendingTrashRemoval
        pendingTrashRemoval = Task.detached(priority: .utility) {
            await teardown?.value
            await previous?.value
            for directory in [Self.containersDirectoryURL, FileManager.default.temporaryDirectory] {
                for item in Self.items(in: directory, withPrefix: Self.trashPrefix) {
                    try! FileManager.default.removeItem(at: item)
                }
            }
        }
    }

    private func attach(_ id: String, readOnly: Bool) async throws -> LinuxDisk {
        guard let runtime else {
            throw ContainerError.noMachine
        }
        let disk = try await runtime.attachDisk(root: Self.rootURL(for: id), readOnly: readOnly)
        guard self.runtime === runtime else {
            throw ContainerError.noMachine
        }
        attachments[id] = Attachment(disk: disk)
        return disk
    }

    private func transition(_ container: LinuxContainer, _ body: () async throws -> Void) async throws {
        guard container.id != activeContainerID else {
            throw ContainerError.active(container.metadata.name)
        }
        guard !transitions.contains(container.id), exportProgress[container.id] == nil else {
            throw ContainerError.busy(container.metadata.name)
        }
        transitions.insert(container.id)
        defer { transitions.remove(container.id) }
        try await body()
    }

    nonisolated static let guestMetadataPath = "/etc/swipterm-container.json"
    private nonisolated static let activeContainerKey = "activeContainer"
    private nonisolated static let containerMetadataName = "swipterm-machine.json"
    private nonisolated static let installPrefix = ".installing."
    private nonisolated static let installJobName = "job.json"
    private nonisolated static let trashPrefix = ".trash."

    private nonisolated static var containersDirectoryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Containers", directoryHint: .isDirectory)
    }

    private nonisolated static var exportDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermExports", directoryHint: .isDirectory)
    }

    nonisolated static func rootURL(for id: String) -> URL {
        containersDirectoryURL.appending(path: id, directoryHint: .isDirectory)
    }

    nonisolated static func installDirectoryURL(for id: String) -> URL {
        containersDirectoryURL.appending(path: installPrefix + id, directoryHint: .isDirectory)
    }

    nonisolated static func dataSize(of container: LinuxContainer) -> Int64 {
        let enumerator = FileManager.default.enumerator(
            at: rootURL(for: container.id),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        )!
        var size: Int64 = 0
        for case let url as URL in enumerator {
            size += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return size
    }

    nonisolated static func metadata(at root: URL) throws -> ContainerMetadata {
        try JSONDecoder().decode(ContainerMetadata.self, from: Data(contentsOf: root.appending(path: containerMetadataName)))
    }

    nonisolated static func saveMetadata(_ metadata: ContainerMetadata, root: URL) throws {
        try JSONEncoder().encode(metadata).write(
            to: root.appending(path: containerMetadataName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    nonisolated static func saveJob(_ job: ContainerCreation.Job) throws {
        try FileManager.default.createDirectory(at: installDirectoryURL(for: job.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(
            to: installDirectoryURL(for: job.id).appending(path: installJobName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    nonisolated static func moveToTrash(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let trashURL = url.deletingLastPathComponent()
            .appending(path: trashPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try! fm.moveItem(at: url, to: trashURL)
    }

    nonisolated static func osRelease(read: (String) throws -> Data?) throws -> OSRelease? {
        for path in ["/etc/os-release", "/usr/lib/os-release"] {
            if let data = try read(path) {
                return OSRelease(String(decoding: data, as: UTF8.self))
            }
        }
        return nil
    }

    nonisolated static func hasSystemInit(read: (String) throws -> Data?) throws -> Bool {
        guard let initBinary = try read("/sbin/init") else { return false }
        for path in ["/bin/busybox", "/usr/bin/busybox"] {
            if try read(path) == initBinary {
                return try read("/sbin/openrc") != nil || read("/usr/bin/openrc") != nil
            }
        }
        return true
    }

    private nonisolated static func migrateLegacyRoot() {
        let fm = FileManager.default
        for item in items(in: URL.applicationSupportDirectory, withPrefix: ".Root.") {
            try! fm.removeItem(at: item)
        }
        let legacyRootURL = URL.applicationSupportDirectory.appending(path: "Root", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: legacyRootURL.path(percentEncoded: false)) else { return }
        try! fm.moveItem(at: legacyRootURL, to: rootURL(for: UUID().uuidString))
    }

    private nonisolated static func loadContainers() -> [LinuxContainer] {
        var containers: [LinuxContainer] = []
        for url in items(in: containersDirectoryURL, withPrefix: "")
            where !url.lastPathComponent.hasPrefix(trashPrefix) && !url.lastPathComponent.hasPrefix(installPrefix)
        {
            guard LinuxRootImage.isInstalled(at: url), let metadata = try? metadata(at: url) else {
                moveToTrash(url)
                continue
            }
            containers.append(LinuxContainer(id: url.lastPathComponent, metadata: metadata))
        }
        return containers.sorted { $0.metadata.installedAt < $1.metadata.installedAt }
    }

    private nonisolated static func loadJobs(excluding containers: [LinuxContainer]) -> [ContainerCreation.Job] {
        var jobs: [ContainerCreation.Job] = []
        for url in items(in: containersDirectoryURL, withPrefix: installPrefix) {
            if let data = try? Data(contentsOf: url.appending(path: installJobName)),
               let job = try? JSONDecoder().decode(ContainerCreation.Job.self, from: data),
               !containers.contains(where: { $0.id == job.id })
            {
                jobs.append(job)
            } else {
                moveToTrash(url)
            }
        }
        return jobs
    }

    private nonisolated static func items(in directory: URL, withPrefix prefix: String) -> [URL] {
        try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
}

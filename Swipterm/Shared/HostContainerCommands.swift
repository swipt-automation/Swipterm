import Foundation
import SwiptermKit

nonisolated extension HostCommands {
    static let containerUsage = """
    usage: swipterm container <command>

    commands:
      list                                List containers
      create <name> [options]             Create a container
      check <container>                   Check that a container can start on its own
      mount [--rw] <container> [<dir>]    Mount the disk of another container (default: /mnt/<name>)
      umount <container|dir>              Unmount the disk of another container
      chroot <container> [command...]     Run a command or a shell in another container
      delete <container>                  Delete another container

    """

    private static let createUsage = """
    usage: swipterm container create <name> [options]

    sources:
      --blank                  An empty disk to install a system on (default)
      --distribution <id>      A distribution: \(LinuxDistribution.allCases.map(\.rawValue).joined(separator: ", "))
      --version <version>      Version of the distribution (default: recommended)
      --url <url>              A root file system archive

    options:
      --user <name>            Default user (default: root)
      --password <password>    Password of the default user

    software:
      --shell <shell>          Login shell of a distribution: \(LoginShell.allCases.map(\.rawValue).joined(separator: ", ")) (default: bash)
      --tool <tool>            Install a developer tool (repeatable): \(DeveloperTool.allCases.map(\.rawValue).joined(separator: ", "))
      --agent <agent>          Install a coding agent (repeatable): \(CodingAgent.allCases.map(\.executableName).joined(separator: ", "))

    ssh:
      --ssh-port <port>        Run an SSH server on a port from \(SSHServer.ports.lowerBound) to \(SSHServer.ports.upperBound) (default: \(SSHServer.defaultPort))
      --ssh-auth <method>      \(sshAuthentications.map(\.name).joined(separator: ", ")) (default: password, or both with --ssh-key)
      --ssh-key <file>         Public key file to authorize (repeatable)

    """

    private static let sshAuthentications: [(name: String, value: SSHAuthentication)] = [
        ("password", .password),
        ("public-key", .publicKey),
        ("both", .passwordAndPublicKey),
    ]

    private static let containerPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    private struct Failure: LocalizedError {
        let message: String
        var status: Int32 = 1

        var errorDescription: String? {
            message
        }
    }

    func handleContainer(_ invocation: HostCommandInvocation, arguments: ArraySlice<String>) async throws -> Int32 {
        guard let command = arguments.first else {
            try await invocation.standardError.write(Data(Self.containerUsage.utf8))
            return 2
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "-h", "--help", "help":
                try await invocation.standardOutput.write(Data(Self.containerUsage.utf8))
                return 0
            case "list", "ls":
                try await invocation.standardOutput.write(Data(await listContainers().utf8))
                return 0
            case "create":
                return try await createContainer(invocation, arguments: rest)
            case "check":
                return try await checkContainer(invocation, arguments: rest)
            case "mount":
                try await mountContainer(invocation, arguments: rest)
                return 0
            case "umount", "unmount":
                try await unmountContainer(invocation, arguments: rest)
                return 0
            case "chroot":
                return try await enterContainer(invocation, arguments: rest)
            case "delete", "rm":
                let container = try await other(Self.single(rest, usage: "usage: swipterm container delete <container>"))
                try await MainActor.run { try system.delete(container) }
                return 0
            default:
                throw Failure(message: "unknown command: \(command)\n\(Self.containerUsage)", status: 2)
            }
        } catch let error as LinuxError where error == .EPIPE {
            return 0
        } catch is CancellationError {
            return 1
        } catch {
            let status = (error as? Failure)?.status ?? 1
            try await invocation.standardError.write(Data("swipterm container: \(Self.describe(error))\n".utf8))
            return status
        }
    }

    static func containerCompletionCandidates(for words: [String], containers: [String]) -> [(value: String, description: String)] {
        let commands: [(value: String, description: String)] = [
            ("list", "List containers"),
            ("create", "Create a container"),
            ("check", "Check that a container can start on its own"),
            ("mount", "Mount the disk of another container"),
            ("umount", "Unmount the disk of another container"),
            ("chroot", "Run a command or a shell in another container"),
            ("delete", "Delete another container"),
        ]
        let current = words[words.count - 1]
        if words.count == 1 {
            return commands.filter { $0.value.hasPrefix(current) }
        }
        let positional = words.dropFirst().dropLast().filter { !$0.hasPrefix("-") }
        switch words[0] {
        case "create":
            guard current.hasPrefix("-") else {
                let candidates: [(value: String, description: String)] = switch words[words.count - 2] {
                case "--distribution":
                    LinuxDistribution.allCases.map { ($0.rawValue, $0.displayName) }
                case "--shell":
                    LoginShell.allCases.map { ($0.rawValue, $0.displayName) }
                case "--tool":
                    DeveloperTool.allCases.map { ($0.rawValue, $0.displayName) }
                case "--agent":
                    CodingAgent.allCases.map { ($0.executableName, $0.displayName) }
                case "--ssh-auth":
                    sshAuthentications.map { ($0.name, "SSH authentication") }
                default:
                    []
                }
                return candidates.filter { $0.value.hasPrefix(current) }
            }
            return [
                ("--blank", "An empty disk to install a system on"),
                ("--distribution", "A distribution"),
                ("--version", "Version of the distribution"),
                ("--url", "A root file system archive"),
                ("--user", "Default user"),
                ("--password", "Password of the default user"),
                ("--shell", "Login shell"),
                ("--tool", "Install a developer tool"),
                ("--agent", "Install a coding agent"),
                ("--ssh-port", "Run an SSH server on a port"),
                ("--ssh-auth", "SSH authentication method"),
                ("--ssh-key", "Public key file to authorize"),
            ].filter { $0.0.hasPrefix(current) }
        case "mount" where current.hasPrefix("-"):
            return [("--rw", "Mount read-write")].filter { $0.0.hasPrefix(current) }
        case "check", "mount", "umount", "unmount", "chroot", "delete", "rm":
            guard positional.isEmpty else { return [] }
            return containers.filter { $0.hasPrefix(current) }.map { ($0, "Container") }
        default:
            return []
        }
    }

    @MainActor
    private func listContainers() -> String {
        var rows = [["NAME", "STATUS", "DISTRIBUTION", "ID"]]
        for container in store.containers {
            let status: String
            if container.id == store.activeContainerID {
                status = "active"
            } else {
                switch store.occupancy(of: container.id) {
                case let .mounted(path, readOnly):
                    status = "mounted \(readOnly ? "ro" : "rw") \(path)"
                case .entered:
                    status = "in use"
                case .exporting:
                    status = "exporting"
                case nil:
                    status = "stopped"
                }
            }
            rows.append([container.metadata.name, status, container.metadata.distributionID ?? "-", String(container.id.prefix(8))])
        }
        for creation in store.creations {
            rows.append([creation.name, creation.state == .running ? "initializing" : "failed", "-", String(creation.id.prefix(8))])
        }
        let widths = (0 ..< 4).map { column in rows.map { $0[column].count }.max()! }
        return rows.map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces) + "\n"
        }.joined()
    }

    private func createContainer(_ invocation: HostCommandInvocation, arguments: [String]) async throws -> Int32 {
        var name: String?
        var distribution: String?
        var version: String?
        var url: String?
        var user = "root"
        var password: String?
        var shell: LoginShell?
        var software = ContainerSoftware()
        var sshPort: String?
        var sshAuthentication: SSHAuthentication?
        var sshKeyFiles: [String] = []
        var index = 0
        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw Failure(message: "missing value for \(option)\n\(Self.createUsage)", status: 2)
            }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                try await invocation.standardOutput.write(Data(Self.createUsage.utf8))
                return 0
            case "--blank":
                break
            case "--distribution":
                distribution = try value(for: argument)
            case "--version":
                version = try value(for: argument)
            case "--url":
                url = try value(for: argument)
            case "--user":
                user = try value(for: argument)
            case "--password":
                password = try value(for: argument)
            case "--shell":
                let name = try value(for: argument)
                guard let loginShell = LoginShell(rawValue: name) else {
                    throw Failure(message: "unknown shell: \(name)\n\(Self.createUsage)", status: 2)
                }
                shell = loginShell
            case "--tool":
                let name = try value(for: argument)
                guard let tool = DeveloperTool(rawValue: name) else {
                    throw Failure(message: "unknown tool: \(name)\n\(Self.createUsage)", status: 2)
                }
                software.setDeveloperTool(tool, isEnabled: true)
            case "--agent":
                let name = try value(for: argument)
                guard let agent = CodingAgent.allCases.first(where: { $0.executableName == name }) else {
                    throw Failure(message: "unknown agent: \(name)\n\(Self.createUsage)", status: 2)
                }
                software.setAgent(agent, isEnabled: true)
            case "--ssh-port":
                sshPort = try value(for: argument)
            case "--ssh-auth":
                let name = try value(for: argument)
                guard let method = Self.sshAuthentications.first(where: { $0.name == name })?.value else {
                    throw Failure(message: "unknown SSH authentication: \(name)\n\(Self.createUsage)", status: 2)
                }
                sshAuthentication = method
            case "--ssh-key":
                try sshKeyFiles.append(value(for: argument))
            default:
                guard !argument.hasPrefix("-"), name == nil else {
                    throw Failure(message: "unexpected argument: \(argument)\n\(Self.createUsage)", status: 2)
                }
                name = argument
            }
            index += 1
        }
        guard let name, name == SetupView.sanitizedContainerName(name) else {
            throw Failure(
                message: "the name must consist of lowercase letters, digits and hyphens\n\(Self.createUsage)",
                status: 2
            )
        }
        guard await MainActor.run(body: { !store.containers.contains { $0.metadata.name == name } }) else {
            throw Failure(message: "a container named \(name) exists")
        }

        let hasSSH = sshPort != nil || sshAuthentication != nil || !sshKeyFiles.isEmpty
        if distribution == nil, url == nil {
            guard shell == nil, software == ContainerSoftware(), !hasSSH else {
                throw Failure(message: "software and SSH options require --distribution or --url", status: 2)
            }
            _ = try await store.createBlank(name: name, user: user)
            try await invocation.standardOutput.write(Data("""
            Created \(name) with an empty disk.
            Install a system on it with: swipterm container mount --rw \(name)
            Then check it with: swipterm container check \(name)

            """.utf8))
            return 0
        }

        let source: ContainerCreation.Request.Creation.Source
        if let distribution {
            guard url == nil else {
                throw Failure(message: "cannot combine --distribution and --url", status: 2)
            }
            guard let distribution = LinuxDistribution(rawValue: distribution) else {
                throw Failure(message: "unknown distribution: \(distribution)\n\(Self.createUsage)", status: 2)
            }
            await catalog.loadIfNeeded()
            let releases = await catalog.releases(for: distribution)
            var release = await catalog.defaultRelease(for: distribution)
            if let version {
                release = releases.first { $0.releaseKey == version || $0.displayTitle == version }
            }
            guard let release else {
                let available = releases.map(\.releaseKey).joined(separator: ", ")
                throw Failure(message: "no such version of \(distribution.rawValue); available: \(available)")
            }
            let shells = distribution.shells(for: release)
            if let shell {
                guard shells.contains(shell) else {
                    let available = shells.map(\.rawValue).joined(separator: ", ")
                    throw Failure(message: "\(shell.rawValue) isn’t available on \(distribution.rawValue); available: \(available)", status: 2)
                }
                software.shell = shell
            } else {
                software.shell = shells.contains(.bash) ? .bash : shells[0]
            }
            source = .catalog(release)
        } else {
            let url = url!
            guard version == nil else {
                throw Failure(message: "--version requires --distribution", status: 2)
            }
            guard shell == nil else {
                throw Failure(message: "--shell requires --distribution", status: 2)
            }
            guard let archive = URL(string: url), ["http", "https"].contains(archive.scheme?.lowercased()), archive.host() != nil else {
                throw Failure(message: "invalid URL: \(url)")
            }
            source = .remoteArchive(archive)
        }

        if hasSSH {
            guard let port = Int(sshPort ?? String(SSHServer.defaultPort)), SSHServer.ports.contains(port) else {
                throw Failure(message: "use an SSH port from \(SSHServer.ports.lowerBound) to \(SSHServer.ports.upperBound)", status: 2)
            }
            let authentication = sshAuthentication ?? (sshKeyFiles.isEmpty ? .password : .passwordAndPublicKey)
            if !authentication.allowsPublicKey, !sshKeyFiles.isEmpty {
                throw Failure(message: "--ssh-key requires public-key or both authentication", status: 2)
            }
            if !authentication.allowsPublicKey, password == nil {
                throw Failure(message: "set --password or allow public key authentication to sign in over SSH", status: 2)
            }
            var sshKeys: [String] = []
            if !sshKeyFiles.isEmpty {
                guard let fileSystem = await MainActor.run(body: { system.guestFileSystem }) else {
                    throw Failure(message: "no active container")
                }
                let home = invocation.environment["HOME"] ?? "/root"
                for keyFile in sshKeyFiles {
                    let expanded = keyFile == "~" ? home : keyFile.hasPrefix("~/") ? home + "/" + keyFile.dropFirst(2) : keyFile
                    let path = Self.absolutePath(expanded, in: invocation.workingDirectory)
                    let data: Data
                    do {
                        data = try await fileSystem.contents(of: path)
                    } catch {
                        throw Failure(message: "\(keyFile): \(error.localizedDescription)")
                    }
                    let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else {
                        throw Failure(message: "\(keyFile): public key file is empty")
                    }
                    sshKeys.append(key)
                }
            }
            software.ssh = SSHServer(
                port: port,
                authentication: authentication,
                authorizedKeys: sshKeys.joined(separator: "\n")
            )
        }

        let request = ContainerCreation.Request.create(ContainerCreation.Request.Creation(
            source: source,
            containerName: name,
            user: user,
            password: password,
            software: software
        ))
        let (output, continuation) = AsyncStream.makeStream(of: Data.self)
        let creation = try await MainActor.run {
            let creation = try system.create(request)!
            _ = creation.console.subscribe { continuation.yield($0) }
            return creation
        }
        let writer = Task {
            for await chunk in output {
                try? await invocation.standardOutput.write(chunk)
            }
        }
        let state = await withTaskCancellationHandler {
            await creation.completion()
        } onCancel: {
            Task { @MainActor in creation.cancel() }
        }
        continuation.finish()
        await writer.value
        if case .finished = state {
            return 0
        }
        await creation.cancel()
        return 1
    }

    private func checkContainer(_ invocation: HostCommandInvocation, arguments: [String]) async throws -> Int32 {
        var container = try await resolve(Self.single(arguments, usage: "usage: swipterm container check <container>"))
        let readiness = try await store.readiness(of: container)
        let user = container.metadata.defaultUser
        let lines = [
            readiness.kernels.isEmpty
                ? "kernel: missing; install an ARM64 kernel package with its modules"
                : "kernel: \(readiness.kernels.joined(separator: ", "))",
            readiness.hasInit ? "init: /sbin/init" : "init: /sbin/init is missing; install an init system",
            readiness.hasDefaultUser ? "user: \(user)" : "user: \(user) is missing from /etc/passwd",
            readiness.isReady ? "\(container.metadata.name) can be activated in Settings." : "\(container.metadata.name) can’t start yet.",
        ]
        if container.metadata.distributionID == nil, let distribution = readiness.release?.distribution {
            container.metadata.distributionID = distribution.rawValue
            try await store.update(container)
        }
        try await invocation.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return readiness.isReady ? 0 : 1
    }

    private func mountContainer(_ invocation: HostCommandInvocation, arguments: [String]) async throws {
        let usage = "usage: swipterm container mount [--rw] <container> [<dir>]"
        var readOnly = true
        var positional: [String] = []
        for argument in arguments {
            switch argument {
            case "--rw", "-w":
                readOnly = false
            case "--ro", "-r":
                readOnly = true
            default:
                guard !argument.hasPrefix("-") else {
                    throw Failure(message: "unknown option: \(argument)\n\(usage)", status: 2)
                }
                positional.append(argument)
            }
        }
        guard (1 ... 2).contains(positional.count) else {
            throw Failure(message: usage, status: 2)
        }
        let container = try await other(positional[0])
        let path = positional.count == 2
            ? Self.absolutePath(positional[1], in: invocation.workingDirectory)
            : "/mnt/\(container.metadata.name)"
        try await store.mount(container, at: path, readOnly: readOnly)
        try await invocation.standardOutput.write(Data("Mounted \(container.metadata.name) \(readOnly ? "read-only" : "read-write") at \(path)\n".utf8))
    }

    private func unmountContainer(_ invocation: HostCommandInvocation, arguments: [String]) async throws {
        let reference = try Self.single(arguments, usage: "usage: swipterm container umount <container|dir>")
        var container = await store.container(mountedAt: Self.absolutePath(reference, in: invocation.workingDirectory))
        if container == nil {
            container = try await other(reference)
        }
        try await store.unmount(container!)
    }

    private func enterContainer(_ invocation: HostCommandInvocation, arguments: [String]) async throws -> Int32 {
        guard let reference = arguments.first, !reference.hasPrefix("-") else {
            throw Failure(message: "usage: swipterm container chroot <container> [command...]", status: 2)
        }
        var command = Array(arguments.dropFirst())
        if command.first == "--" {
            command.removeFirst()
        }
        let container = try await other(reference)
        let name = container.metadata.name
        return try await store.withDisk(id: container.id, name: name) { disk in
            let process: LinuxProcess
            if command.isEmpty {
                process = try await disk.shell(environment: invocation.environment, hostname: name, attachedTo: invocation)
            } else {
                var environment = invocation.environment.filter { key, _ in
                    ["TERM", "COLORTERM", "LANG", "LANGUAGE", "TZ"].contains(key) || key.hasPrefix("LC_")
                }
                environment["PATH"] = Self.containerPath
                environment["HOME"] = "/root"
                process = try await disk.spawn(
                    LinuxProcess.Configuration(
                        executablePath: command[0],
                        arguments: Array(command.dropFirst()),
                        environment: environment,
                        workingDirectory: "/"
                    ),
                    hostname: name,
                    attachedTo: invocation
                )
            }
            let termination = await withTaskCancellationHandler {
                await process.termination
            } onCancel: {
                try? process.send(.kill)
            }
            switch termination {
            case let .exited(code):
                return code
            case let .signaled(signal):
                return 128 + signal.rawValue
            }
        }
    }

    @MainActor
    private func resolve(_ reference: String) throws -> LinuxContainer {
        if let container = store.containers.first(where: { $0.id == reference }) {
            return container
        }
        let named = store.containers.filter { $0.metadata.name == reference }
        let matches = named.isEmpty ? store.containers.filter { $0.id.lowercased().hasPrefix(reference.lowercased()) } : named
        guard let container = matches.first else {
            throw Failure(message: "no such container: \(reference)")
        }
        guard matches.count == 1 else {
            let ids = matches.map { String($0.id.prefix(8)) }.joined(separator: ", ")
            throw Failure(message: "\(reference) is ambiguous; use an ID: \(ids)")
        }
        return container
    }

    @MainActor
    private func other(_ reference: String) throws -> LinuxContainer {
        let container = try resolve(reference)
        guard container.id != store.activeContainerID else {
            throw ContainerError.active(container.metadata.name)
        }
        return container
    }

    private static func single(_ arguments: [String], usage: String) throws -> String {
        guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
            throw Failure(message: usage, status: 2)
        }
        return arguments[0]
    }

    private static func absolutePath(_ path: String, in directory: String) -> String {
        URL(filePath: path, relativeTo: URL(filePath: directory, directoryHint: .isDirectory)).standardizedFileURL.path(percentEncoded: false)
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? LinuxError else {
            return error.localizedDescription
        }
        switch error {
        case .EBUSY:
            return "the container or the directory is in use"
        case .ENOTEMPTY:
            return "the directory isn’t empty"
        case .ENOSPC:
            return "too many disks are attached"
        default:
            return error.localizedDescription
        }
    }
}

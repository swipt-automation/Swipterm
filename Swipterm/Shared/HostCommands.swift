import CoreLocation
import Foundation
import SwiptermKit

nonisolated struct HostCommands: Sendable {
    let system: LinuxSystem
    let store: ContainerStore
    let settings: AppSettings
    let location: HostLocation
    let catalog: LinuxDistributionCatalogStore

    private static let swiptermUsage = """
    usage: swipterm <command> [options]

    commands:
      open <url>                  Open a URL on the host
      location [options]          Read device location
      caffeinate [on|off|status]  Manage background execution
      container <command>         Manage other containers
      completion <shell>          Generate shell completion script
      help [command]              Show help for a command
    """

    private static let openUsage = "usage: swipterm open <url>\n"

    private static let locationUsage = """
    usage: swipterm location [options]

    options:
      -w, --watch             Stream location updates continuously
      -a, --accuracy <level>  Accuracy: reduced, 3km, 1km, 100m, 10m, best, nav
      -j, --json              Format output as JSON lines
      -h, --help              Show this help
    """

    private static let caffeinateUsage = "usage: swipterm caffeinate [on|off|status]\n"
    private static let completionUsage = "usage: swipterm completion <bash|zsh|fish|nushell>\n"

    private static let bashCompletionScript = #"""
    _swipterm() {
        local IFS=$'\n'
        local args=()
        local i
        for ((i = 1; i <= COMP_CWORD; i++)); do
            args+=("${COMP_WORDS[i]-}")
        done
        if [[ "${COMP_WORDS[COMP_CWORD]-}" == "=" ]]; then
            args[${#args[@]}-1]=""
        elif [[ $COMP_CWORD -ge 2 && "${COMP_WORDS[COMP_CWORD-1]-}" == "=" ]]; then
            unset 'args[${#args[@]}-2]'
        fi
        COMPREPLY=($(swipterm __complete -- "${args[@]}" 2>/dev/null))
    }
    complete -F _swipterm swipterm
    """# + "\n"

    private static let bashProfileHook = #"""
    if [ -n "${BASH_VERSION:-}" ]; then
        case $- in
        *i*) [ -r /usr/share/bash-completion/completions/swipterm ] && . /usr/share/bash-completion/completions/swipterm ;;
        esac
    fi
    """# + "\n"

    private static let zshCompletionScript = #"""
    #compdef swipterm

    _swipterm() {
        local -a completions
        local line val desc
        for line in "${(@f)$(swipterm __complete --descriptions -- "${(@)words[2,CURRENT]}" 2>/dev/null)}"; do
            [[ -n "$line" ]] || continue
            val="${line%%$'\t'*}"
            desc="${line#*$'\t'}"
            val="${val//:/\\:}"
            if [[ "$line" == *$'\t'* && -n "$desc" ]]; then
                completions+=("${val}:${desc}")
            else
                completions+=("$val")
            fi
        done
        _describe 'swipterm' completions
    }

    if [[ "$funcstack[1]" == "_swipterm" ]]; then
        _swipterm "$@"
    else
        compdef _swipterm swipterm
    fi
    """# + "\n"

    private static let zshLoginHook = "[[ -o interactive ]] && (( ! $+functions[compdef] )) && autoload -Uz compinit && compinit -C"

    private static let fishCompletionScript = #"""
    function __swipterm_complete
        set -l tokens (commandline -opc)
        set -l current (commandline -ct)
        set -e tokens[1]
        swipterm __complete --descriptions -- $tokens "$current" 2>/dev/null
    end

    complete -c swipterm -f -a '(__swipterm_complete)'
    """# + "\n"

    private static let nushellCompletionScript = #"""
    def "nu-complete swipterm" [context: string] {
        let trimmed = ($context | str trim)
        let parts = if ($trimmed | is-empty) { [] } else { $trimmed | split row -r '\s+' | skip 1 }
        let args = if ($context =~ '\s$') { $parts | append "" } else { $parts }
        ^swipterm __complete --descriptions -- ...$args
        | lines
        | where ($it | is-not-empty)
        | each {|line|
            $line | split column "\t" value description | first
        }
    }

    export extern swipterm [
        ...args: string@"nu-complete swipterm"
    ]
    """# + "\n"

    private struct LocationOptions: Sendable {
        var watch = false
        var accuracy: HostLocation.Accuracy?
        var json = false
        var help = false
    }

    private struct LocationPayload: Encodable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let altitude: Double?
        let verticalAccuracy: Double?
        let speed: Double?
        let speedAccuracy: Double?
        let course: Double?
        let courseAccuracy: Double?
        let floor: Int?
        let accuracyAuthorization: String
        let timestamp: String
    }

    func register(on runtime: LinuxRuntime) async throws {
        try await runtime.registerCommand(named: "swipterm") { invocation in
            try await handleSwipterm(invocation)
        }
        for name in ["open", "xdg-open"] {
            try await runtime.registerCommand(named: name) { invocation in
                try await handleOpen(invocation, arguments: invocation.arguments[...], commandName: name, strictHelp: false)
            }
        }
        try await Self.installShellCompletions(on: runtime.fileSystem)
    }

    private static func installShellCompletions(on fileSystem: LinuxFileSystem) async throws {
        let files: [(directory: String, path: String, contents: String)] = [
            ("/usr/share/bash-completion/completions", "/usr/share/bash-completion/completions/swipterm", bashCompletionScript),
            ("/etc/profile.d", "/etc/profile.d/zz-swipterm-completion.sh", bashProfileHook),
            ("/usr/local/share/zsh/site-functions", "/usr/local/share/zsh/site-functions/_swipterm", zshCompletionScript),
            ("/etc/fish/completions", "/etc/fish/completions/swipterm.fish", fishCompletionScript),
            ("/usr/share/nushell/vendor/autoload", "/usr/share/nushell/vendor/autoload/swipterm.nu", nushellCompletionScript),
        ]
        for file in files {
            try await fileSystem.createDirectory(file.directory, withIntermediateDirectories: true)
            try await fileSystem.writeFile(file.path, contents: Data(file.contents.utf8))
        }
        func fileType(at path: String) async throws -> LinuxFileType? {
            do {
                return try await fileSystem.stat(path).type
            } catch let error as LinuxError where error == .ENOENT {
                return nil
            }
        }
        let zloginPath: String
        if try await fileType(at: "/etc/zsh") == .directory {
            zloginPath = "/etc/zsh/zlogin"
        } else if try await fileType(at: "/bin/zsh") != nil {
            zloginPath = "/etc/zlogin"
        } else if try await fileType(at: "/usr/bin/zsh") != nil {
            zloginPath = "/etc/zlogin"
        } else {
            return
        }
        let existing: String
        do {
            existing = try await String(decoding: fileSystem.contents(of: zloginPath), as: UTF8.self)
        } catch let error as LinuxError where error == .ENOENT {
            existing = ""
        }
        if !existing.contains(zshLoginHook) {
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let updated = existing + separator + zshLoginHook + "\n"
            try await fileSystem.writeFile(zloginPath, contents: Data(updated.utf8))
        }
    }

    private func handleSwipterm(_ invocation: HostCommandInvocation) async throws -> Int32 {
        guard let subcommand = invocation.arguments.first else {
            try await invocation.standardError.write(Data((Self.swiptermUsage + "\n").utf8))
            return 2
        }
        let rest = invocation.arguments.dropFirst()
        switch subcommand {
        case "-h", "--help":
            try await invocation.standardOutput.write(Data((Self.swiptermUsage + "\n").utf8))
            return 0
        case "help":
            guard let topic = rest.first else {
                try await invocation.standardOutput.write(Data((Self.swiptermUsage + "\n").utf8))
                return 0
            }
            switch topic {
            case "open":
                try await invocation.standardOutput.write(Data(Self.openUsage.utf8))
                return 0
            case "location":
                try await invocation.standardOutput.write(Data((Self.locationUsage + "\n").utf8))
                return 0
            case "caffeinate":
                try await invocation.standardOutput.write(Data(Self.caffeinateUsage.utf8))
                return 0
            case "container":
                try await invocation.standardOutput.write(Data(Self.containerUsage.utf8))
                return 0
            case "completion":
                try await invocation.standardOutput.write(Data(Self.completionUsage.utf8))
                return 0
            default:
                try await invocation.standardError.write(Data("swipterm: unknown command: \(topic)\n".utf8))
                return 2
            }
        case "open":
            return try await handleOpen(invocation, arguments: rest, commandName: "swipterm open", strictHelp: true)
        case "location":
            return try await handleLocation(invocation, arguments: rest)
        case "caffeinate":
            return try await handleCaffeinate(invocation, arguments: rest)
        case "container":
            return try await handleContainer(invocation, arguments: rest)
        case "completion":
            return try await Self.handleCompletion(invocation, arguments: rest)
        case "__complete":
            return try await handleCompleteQuery(invocation, arguments: rest)
        default:
            try await invocation.standardError.write(Data("swipterm: unknown command: \(subcommand)\n".utf8))
            return 2
        }
    }

    private func handleOpen(
        _ invocation: HostCommandInvocation,
        arguments: ArraySlice<String>,
        commandName: String,
        strictHelp: Bool
    ) async throws -> Int32 {
        var target: String?
        var parsingOptions = true
        for argument in arguments {
            if parsingOptions, argument == "--" {
                parsingOptions = false
                continue
            }
            if parsingOptions, strictHelp, argument == "-h" || argument == "--help" {
                try await invocation.standardOutput.write(Data("usage: \(commandName) <url>\n".utf8))
                return 0
            }
            if parsingOptions, argument.hasPrefix("-") {
                continue
            }
            target = argument
            break
        }
        guard let target else {
            try await invocation.standardError.write(Data("usage: \(commandName) <url>\n".utf8))
            return 2
        }
        guard let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty else {
            try await invocation.standardError.write(Data("\(commandName): invalid URL: \(target)\n".utf8))
            return 1
        }
        await MainActor.run {
            system.pendingOpenURL = url
        }
        return 0
    }

    private func handleCaffeinate(
        _ invocation: HostCommandInvocation,
        arguments: ArraySlice<String>
    ) async throws -> Int32 {
        if arguments.count > 1 {
            try await invocation.standardError.write(Data(Self.caffeinateUsage.utf8))
            return 2
        }
        switch arguments.first {
        case nil, "on":
            do {
                try await location.enableCaffeinateFromCommand()
                return 0
            } catch is CancellationError {
                return 1
            } catch {
                try await invocation.standardError.write(Data("swipterm caffeinate: \(error.localizedDescription)\n".utf8))
                return 1
            }
        case "off":
            await location.disableCaffeinateFromCommand()
            return 0
        case "status":
            let enabled = await MainActor.run { settings.isCaffeinateEnabled }
            try await invocation.standardOutput.write(Data((enabled ? "enabled\n" : "disabled\n").utf8))
            return 0
        case "-h", "--help":
            try await invocation.standardOutput.write(Data(Self.caffeinateUsage.utf8))
            return 0
        default:
            try await invocation.standardError.write(Data(Self.caffeinateUsage.utf8))
            return 2
        }
    }

    private static func handleCompletion(
        _ invocation: HostCommandInvocation,
        arguments: ArraySlice<String>
    ) async throws -> Int32 {
        guard arguments.count == 1, let target = arguments.first else {
            try await invocation.standardError.write(Data(completionUsage.utf8))
            return 2
        }
        switch target {
        case "-h", "--help":
            try await invocation.standardOutput.write(Data(completionUsage.utf8))
            return 0
        case "bash":
            try await invocation.standardOutput.write(Data(bashCompletionScript.utf8))
            return 0
        case "zsh":
            try await invocation.standardOutput.write(Data(zshCompletionScript.utf8))
            return 0
        case "fish":
            try await invocation.standardOutput.write(Data(fishCompletionScript.utf8))
            return 0
        case "nushell", "nu":
            try await invocation.standardOutput.write(Data(nushellCompletionScript.utf8))
            return 0
        default:
            try await invocation.standardError.write(Data("swipterm completion: unsupported shell: \(target)\n\(completionUsage)".utf8))
            return 2
        }
    }

    private func handleCompleteQuery(
        _ invocation: HostCommandInvocation,
        arguments: ArraySlice<String>
    ) async throws -> Int32 {
        var descriptions = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let arg = arguments[index]
            index = arguments.index(after: index)
            if arg == "--" {
                break
            }
            if arg == "--descriptions" {
                descriptions = true
            }
        }
        let words = index < arguments.endIndex ? Array(arguments[index...]) : [""]
        let containers = await MainActor.run {
            store.containers.filter { $0.id != store.activeContainerID }.map(\.metadata.name)
        }
        let items = Self.completionCandidates(for: words, containers: containers)
        guard !items.isEmpty else {
            return 0
        }
        var output = ""
        for item in items {
            if descriptions {
                output += "\(item.value)\t\(item.description)\n"
            } else {
                output += "\(item.value)\n"
            }
        }
        try await invocation.standardOutput.write(Data(output.utf8))
        return 0
    }

    private static let accuracyCompletionItems: [(value: String, description: String)] = [
        ("reduced", "Reduced (~5 km, lowest power)"),
        ("3km", "Three kilometers"),
        ("1km", "One kilometer"),
        ("100m", "Hundred meters"),
        ("10m", "Nearest ten meters"),
        ("best", "Best accuracy"),
        ("nav", "Best for navigation"),
    ]

    private static let subcommandCompletionItems: [(value: String, description: String)] = [
        ("open", "Open a URL on the host"),
        ("location", "Read device location"),
        ("caffeinate", "Manage background execution"),
        ("container", "Manage other containers"),
        ("completion", "Generate shell completion script"),
    ]

    private static func completionCandidates(for words: [String], containers: [String]) -> [(value: String, description: String)] {
        let first = words[0]
        if words.count == 1 {
            if first.hasPrefix("-") {
                return [
                    ("-h", "Show help"),
                    ("--help", "Show help"),
                ].filter { $0.value.hasPrefix(first) }
            }
            let commands = subcommandCompletionItems + [("help", "Show help for a command")]
            return commands.filter { $0.value.hasPrefix(first) }
        }

        let current = words[words.count - 1]
        let previous = words.count >= 3 ? words[words.count - 2] : nil
        let prior = words.dropFirst().dropLast()
        if prior.contains("--") {
            return []
        }

        switch first {
        case "help":
            guard words.count == 2, !current.hasPrefix("-") else { return [] }
            return subcommandCompletionItems.filter { $0.value.hasPrefix(current) }

        case "completion":
            if current.hasPrefix("-") {
                return [("-h", "Show help"), ("--help", "Show help")].filter { $0.value.hasPrefix(current) }
            }
            guard words.count == 2 else { return [] }
            return [
                ("bash", "Bash completion script"),
                ("zsh", "Zsh completion script"),
                ("fish", "Fish completion script"),
                ("nushell", "Nushell completion script"),
            ].filter { $0.value.hasPrefix(current) }

        case "open":
            guard current.hasPrefix("-") else { return [] }
            return [("-h", "Show help"), ("--help", "Show help")].filter { $0.value.hasPrefix(current) }

        case "caffeinate":
            if current.hasPrefix("-") {
                return [("-h", "Show help"), ("--help", "Show help")].filter { $0.value.hasPrefix(current) }
            }
            guard words.count == 2 else { return [] }
            return [
                ("on", "Enable background execution"),
                ("off", "Disable background execution"),
                ("status", "Show current status"),
            ].filter { $0.value.hasPrefix(current) }

        case "container":
            return containerCompletionCandidates(for: Array(words.dropFirst()), containers: containers)

        case "location":
            if let previous, previous == "--accuracy" || isShortAccuracyOption(previous) {
                return accuracyCompletionItems.filter { $0.value.hasPrefix(current) }
            }
            if current.hasPrefix("--accuracy=") {
                let prefix = String(current.dropFirst("--accuracy=".count))
                return accuracyCompletionItems
                    .filter { $0.value.hasPrefix(prefix) }
                    .map { ("--accuracy=\($0.value)", $0.description) }
            }
            if current.hasPrefix("-a"), !current.hasPrefix("--"), current.count > 2 {
                let prefix = String(current.dropFirst(2))
                return accuracyCompletionItems
                    .filter { $0.value.hasPrefix(prefix) }
                    .map { ("-a\($0.value)", $0.description) }
            }

            func hasShortFlag(_ ch: Character) -> Bool {
                prior.contains { token in
                    guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 else { return false }
                    if let aIndex = token.dropFirst().firstIndex(of: "a") {
                        return token[token.index(after: token.startIndex) ... aIndex].contains(ch)
                    }
                    return token.dropFirst().contains(ch)
                }
            }

            let usedWatch = prior.contains("--watch") || hasShortFlag("w")
            let usedAccuracy = prior.contains("--accuracy") || prior.contains { $0.hasPrefix("--accuracy=") } || hasShortFlag("a")
            let usedJSON = prior.contains("--json") || hasShortFlag("j")
            let usedHelp = prior.contains("--help") || hasShortFlag("h")

            let includeShort = current.hasPrefix("-") && !current.hasPrefix("--")
            var flags: [(value: String, description: String)] = []
            if !usedWatch {
                if includeShort {
                    flags.append(("-w", "Stream location updates continuously"))
                }
                flags.append(("--watch", "Stream location updates continuously"))
            }
            if !usedAccuracy {
                if includeShort {
                    flags.append(("-a", "Desired location accuracy"))
                }
                flags.append(("--accuracy", "Desired location accuracy"))
            }
            if !usedJSON {
                if includeShort {
                    flags.append(("-j", "Format output as JSON lines"))
                }
                flags.append(("--json", "Format output as JSON lines"))
            }
            if !usedHelp {
                if includeShort {
                    flags.append(("-h", "Show help"))
                }
                flags.append(("--help", "Show help"))
            }
            return flags.filter { $0.value.hasPrefix(current) }

        default:
            return []
        }
    }

    private func handleLocation(
        _ invocation: HostCommandInvocation,
        arguments: ArraySlice<String>
    ) async throws -> Int32 {
        let options: LocationOptions
        switch Self.parseLocationOptions(arguments) {
        case let .success(parsed):
            options = parsed
        case let .failure(error):
            try await invocation.standardError.write(Data("swipterm location: \(error.message)\n\(Self.locationUsage)\n".utf8))
            return 2
        }
        if options.help {
            try await invocation.standardOutput.write(Data((Self.locationUsage + "\n").utf8))
            return 0
        }

        do {
            try await location.prepareAccess(accuracy: options.accuracy)
            if options.watch {
                try await streamLocations(invocation, options: options)
            } else {
                let (location, accuracyAuth) = try await location.nextLocation(accuracy: options.accuracy)
                try await Self.writeLocation(location, accuracyAuthorization: accuracyAuth, json: options.json, to: invocation.standardOutput)
            }
            return 0
        } catch let error as LinuxError where error == .EPIPE {
            return 0
        } catch is CancellationError {
            return 1
        } catch {
            try await invocation.standardError.write(Data("swipterm location: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private struct OptionError: Error {
        let message: String
    }

    private static func parseLocationOptions(_ arguments: ArraySlice<String>) -> Result<LocationOptions, OptionError> {
        var options = LocationOptions()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index = arguments.index(after: index)
            if argument == "--" {
                if index < arguments.endIndex {
                    return .failure(OptionError(message: "unexpected argument: \(arguments[index])"))
                }
                break
            }
            if argument.hasPrefix("--") {
                if let equals = argument.firstIndex(of: "=") {
                    let flag = argument[..<equals]
                    let value = String(argument[argument.index(after: equals)...])
                    guard flag == "--accuracy" else {
                        return .failure(OptionError(message: "unknown option: \(flag)"))
                    }
                    guard let accuracy = HostLocation.Accuracy(argument: value) else {
                        return .failure(OptionError(message: "invalid accuracy: \(value)"))
                    }
                    options.accuracy = accuracy
                    continue
                }
                switch argument {
                case "--watch":
                    options.watch = true
                case "--json":
                    options.json = true
                case "--help":
                    options.help = true
                case "--accuracy":
                    guard index < arguments.endIndex else {
                        return .failure(OptionError(message: "missing value for --accuracy"))
                    }
                    let value = arguments[index]
                    index = arguments.index(after: index)
                    guard let accuracy = HostLocation.Accuracy(argument: value) else {
                        return .failure(OptionError(message: "invalid accuracy: \(value)"))
                    }
                    options.accuracy = accuracy
                default:
                    return .failure(OptionError(message: "unknown option: \(argument)"))
                }
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                var chars = argument.dropFirst()[...]
                while let flag = chars.popFirst() {
                    switch flag {
                    case "w":
                        options.watch = true
                    case "j":
                        options.json = true
                    case "h":
                        options.help = true
                    case "a":
                        let value: String
                        if !chars.isEmpty {
                            value = String(chars)
                            chars = chars[chars.endIndex...]
                        } else {
                            guard index < arguments.endIndex else {
                                return .failure(OptionError(message: "missing value for -a"))
                            }
                            value = arguments[index]
                            index = arguments.index(after: index)
                        }
                        guard let accuracy = HostLocation.Accuracy(argument: value) else {
                            return .failure(OptionError(message: "invalid accuracy: \(value)"))
                        }
                        options.accuracy = accuracy
                    default:
                        return .failure(OptionError(message: "unknown option: -\(flag)"))
                    }
                }
                continue
            }
            return .failure(OptionError(message: "unexpected argument: \(argument)"))
        }
        return .success(options)
    }

    private static func isShortAccuracyOption(_ token: String) -> Bool {
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count >= 2 else { return false }
        let flags = token.dropFirst()
        guard flags.last == "a" else { return false }
        return flags.dropLast().allSatisfy { "wjh".contains($0) }
    }

    private final class StreamLeaseState: @unchecked Sendable {
        private let lock = NSLock()
        private var leaseID: UUID?
        private var terminated = false

        func attach(_ id: UUID) -> Bool {
            lock.withLock {
                guard !terminated else { return false }
                leaseID = id
                return true
            }
        }

        func terminate() -> UUID? {
            lock.withLock {
                terminated = true
                let id = leaseID
                leaseID = nil
                return id
            }
        }
    }

    private func streamLocations(
        _ invocation: HostCommandInvocation,
        options: LocationOptions
    ) async throws {
        let stream = AsyncThrowingStream<(CLLocation, CLAccuracyAuthorization), any Error> { continuation in
            let state = StreamLeaseState()
            continuation.onTermination = { _ in
                if let leaseID = state.terminate() {
                    Task { @MainActor in
                        location.removeLease(leaseID)
                    }
                }
            }
            Task { @MainActor in
                let leaseID = location.addLease(accuracy: options.accuracy) { result in
                    switch result {
                    case let .success(value):
                        continuation.yield(value)
                    case let .failure(error):
                        continuation.finish(throwing: error)
                    }
                }
                if !state.attach(leaseID) {
                    location.removeLease(leaseID)
                }
            }
        }
        for try await (location, accuracyAuth) in stream {
            try Task.checkCancellation()
            try await Self.writeLocation(location, accuracyAuthorization: accuracyAuth, json: options.json, to: invocation.standardOutput)
        }
    }

    private static func writeLocation(
        _ location: CLLocation,
        accuracyAuthorization: CLAccuracyAuthorization,
        json: Bool,
        to output: LinuxPipeWriter
    ) async throws {
        let line: Data
        if json {
            let hasVertical = location.verticalAccuracy >= 0
            let hasSpeed = location.speed >= 0
            let hasSpeedAccuracy = location.speedAccuracy >= 0
            let hasCourse = location.course >= 0
            let hasCourseAccuracy = location.courseAccuracy >= 0
            let payload = LocationPayload(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                altitude: hasVertical ? location.altitude : nil,
                verticalAccuracy: hasVertical ? location.verticalAccuracy : nil,
                speed: hasSpeed ? location.speed : nil,
                speedAccuracy: hasSpeedAccuracy ? location.speedAccuracy : nil,
                course: hasCourse ? location.course : nil,
                courseAccuracy: hasCourseAccuracy ? location.courseAccuracy : nil,
                floor: location.floor?.level,
                accuracyAuthorization: accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
                timestamp: location.timestamp.ISO8601Format()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var encoded = try encoder.encode(payload)
            encoded.append(0x0A)
            line = encoded
        } else {
            var text = String(
                format: "%.6f,%.6f ±%.1fm",
                locale: Locale(identifier: "en_US_POSIX"),
                location.coordinate.latitude,
                location.coordinate.longitude,
                location.horizontalAccuracy
            )
            if location.verticalAccuracy >= 0 {
                text += String(format: " alt %.1fm", locale: Locale(identifier: "en_US_POSIX"), location.altitude)
            }
            text += "\n"
            line = Data(text.utf8)
        }
        try await output.write(line)
    }
}

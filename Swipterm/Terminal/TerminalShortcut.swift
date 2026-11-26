import Foundation
import SwiptermKit

nonisolated struct TerminalShortcut: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var directory = ""
    var command = ""
    var icon: String?

    var symbolName: String {
        get { icon ?? "terminal" }
        set { icon = newValue }
    }

    var startupInput: Data? {
        var lines: [String] = []
        let directory = directory.trimmingCharacters(in: .whitespaces)
        if !directory.isEmpty {
            lines.append("cd " + Self.quotedPath(directory))
        }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            lines.append(contentsOf: command.components(separatedBy: .newlines))
        }
        guard !lines.isEmpty else { return nil }
        return Data(lines.map { $0 + "\r" }.joined().utf8)
    }

    private static func quotedPath(_ path: String) -> String {
        let prefix = path == "~" ? "~" : path.hasPrefix("~/") ? "~/" : ""
        let rest = path.dropFirst(prefix.count)
        guard !rest.isEmpty else { return prefix }
        return prefix + "'" + rest.replacing("'", with: "'\\''") + "'"
    }
}

extension TerminalShortcut {
    static func suggestions() async throws -> [TerminalShortcut] {
        let system = LinuxSystem.shared
        guard let fileSystem = system.guestFileSystem else { return [] }
        let user = system.activeContainer!.metadata.defaultUser
        let passwd = try await fileSystem.contents(of: "/etc/passwd")
        guard let home = String(decoding: passwd, as: UTF8.self)
            .split(separator: "\n")
            .map({ $0.split(separator: ":", omittingEmptySubsequences: false) })
            .first(where: { $0.count >= 6 && $0[0] == user })?[5]
        else { return [] }

        var suggestions: [TerminalShortcut] = []
        do {
            let config = try await fileSystem.contents(of: "\(home)/.ssh/config")
            for host in sshHosts(in: String(decoding: config, as: UTF8.self)) {
                suggestions.append(TerminalShortcut(name: "SSH \(host)", command: "ssh \(host)", icon: "network"))
            }
        } catch let error as LinuxError where error == .ENOENT {}
        let binDirectories = [
            "\(home)/.local/share/pnpm/bin",
            "\(home)/.local/share/pnpm",
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        for agent in CodingAgent.allCases {
            for directory in binDirectories {
                do {
                    _ = try await fileSystem.stat("\(directory)/\(agent.executableName)")
                } catch let error as LinuxError where error == .ENOENT {
                    continue
                }
                suggestions.append(TerminalShortcut(name: agent.displayName, command: agent.executableName, icon: "sparkles"))
                break
            }
        }
        return suggestions
    }

    private static func sshHosts(in config: String) -> [String] {
        var hosts: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1) { $0 == " " || $0 == "\t" || $0 == "=" }
            guard fields.count == 2, fields[0].lowercased() == "host" else { continue }
            for pattern in fields[1].split(whereSeparator: \.isWhitespace) {
                let host = String(pattern)
                if !host.contains(where: { "*?!#=".contains($0) }), !hosts.contains(host) {
                    hosts.append(host)
                }
            }
        }
        return hosts
    }
}

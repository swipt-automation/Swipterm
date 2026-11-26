import Foundation

nonisolated struct OSRelease: Sendable {
    let id: String
    let version: String?
    let versionID: String?
    let versionCodename: String?

    init(_ text: String) {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: separator)...])
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            fields[String(line[..<separator])] = value
        }
        id = fields["ID"]?.lowercased() ?? ""
        version = fields["VERSION"].flatMap { $0.isEmpty ? nil : $0 }
        versionID = fields["VERSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        versionCodename = fields["VERSION_CODENAME"].flatMap { $0.isEmpty ? nil : $0 }
    }

    var distribution: LinuxDistribution? {
        switch id {
        case "almalinux": .alma
        case "alpine": .alpine
        case "arch", "archarm": .arch
        case "centos": .centos
        case "debian": .debian
        case "devuan": .devuan
        case "fedora": .fedora
        case "kali": .kali
        case "openeuler": .openEuler
        case "opensuse-leap", "opensuse-tumbleweed": .openSUSE
        case "ol": .oracle
        case "rocky": .rocky
        case "ubuntu": .ubuntu
        case "void": .void
        default: nil
        }
    }

    var isTumbleweed: Bool {
        id == "opensuse-tumbleweed"
    }

    var majorVersion: String? {
        versionID.map { String($0.split(separator: ".")[0]) }
    }
}

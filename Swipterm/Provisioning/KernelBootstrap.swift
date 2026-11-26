import CryptoKit
import Foundation
import SwiptermKit

nonisolated struct KernelPackage: Sendable {
    let name: String
    let version: String
    let url: URL
    let record: Data?
    let isDependency: Bool
}

nonisolated enum KernelBootstrapError: LocalizedError {
    case unknownRelease
    case kernelUnavailable(String)
    case invalidIndex(URL)
    case invalidPackage(String)

    var errorDescription: String? {
        switch self {
        case .unknownRelease:
            "The image has no os-release."
        case let .kernelUnavailable(distribution):
            String(localized: "\(distribution) has no kernel package for this release.")
        case let .invalidIndex(url):
            "Unrecognized package index: \(url.absoluteString)"
        case let .invalidPackage(name):
            "Unrecognized package: \(name)"
        }
    }
}

nonisolated struct KernelBootstrap: Sendable {
    typealias Fetch = @Sendable (_ url: URL) async throws -> URL

    struct Installed: Sendable {
        let package: KernelPackage
        let file: URL
        let contents: LinuxPackageContents
    }

    static let stagingDirectory = "/var/lib/swipterm/kernel"

    let distribution: LinuxDistribution
    let release: OSRelease

    private var root: String {
        switch distribution {
        case .alma: "https://repo.almalinux.org/almalinux"
        case .alpine: "https://dl-cdn.alpinelinux.org/alpine"
        case .arch: "https://ca.us.mirror.archlinuxarm.org"
        case .centos: "https://mirror.stream.centos.org"
        case .debian: "https://deb.debian.org/debian"
        case .devuan: "https://pkgmaster.devuan.org/merged"
        case .fedora: "https://dl.fedoraproject.org/pub/fedora/linux"
        case .kali: "https://kali.download/kali"
        case .openEuler: "https://repo.openeuler.org"
        case .openSUSE: "https://download.opensuse.org"
        case .oracle: "https://yum.oracle.com/repo/OracleLinux"
        case .rocky: "https://dl.rockylinux.org/pub/rocky"
        case .ubuntu: "https://ports.ubuntu.com/ubuntu-ports"
        case .void: "https://repo-default.voidlinux.org"
        }
    }

    @concurrent func packages(fetch: Fetch) async throws -> [KernelPackage] {
        let codename = release.versionCodename ?? ""
        let major = release.majorVersion ?? ""
        let version = release.versionID ?? ""
        switch distribution {
        case .debian:
            return try await apt([
                AptSource(base: root, suite: codename),
                AptSource(base: "https://deb.debian.org/debian-security", suite: "\(codename)-security", optional: true),
            ], metas: ["linux-image-cloud-arm64"], fetch: fetch)
        case .devuan:
            return try await apt([
                AptSource(base: root, suite: codename),
                AptSource(base: root, suite: "\(codename)-security", optional: true),
            ], metas: ["linux-image-cloud-arm64"], fetch: fetch)
        case .ubuntu:
            return try await apt([
                AptSource(base: root, suite: codename),
                AptSource(base: root, suite: "\(codename)-updates", optional: true),
                AptSource(base: root, suite: "\(codename)-security", optional: true),
            ], metas: ["linux-image-virtual"], fetch: fetch)
        case .kali:
            return try await apt([AptSource(base: root, suite: "kali-rolling")], metas: [
                "linux-image-cloud-arm64", "linux-image-arm64",
            ], fetch: fetch)
        case .alma, .rocky:
            return try await rpm(["\(root)/\(major)/BaseOS/aarch64/os/"], kernels: [["kernel-core", "kernel-modules-core"]], fetch: fetch)
        case .centos:
            return try await rpm(["\(root)/\(major)-stream/BaseOS/aarch64/os/"], kernels: [["kernel-core", "kernel-modules-core"]], fetch: fetch)
        case .fedora:
            return try await rpm(
                ["\(root)/releases/\(version)/Everything/aarch64/os/", "\(root)/updates/\(version)/Everything/aarch64/"],
                optional: 1,
                kernels: [["kernel-core", "kernel-modules-core"]],
                fetch: fetch
            )
        case .oracle:
            if major == "9" {
                return try await rpm(["\(root)/OL9/baseos/latest/aarch64/"], kernels: [["kernel-core", "kernel-modules-core"]], fetch: fetch)
            }
            return try await rpm(["\(root)/OL\(major)/UEKR8/aarch64/"], kernels: [["kernel-uek-core", "kernel-uek-modules-core"]], fetch: fetch)
        case .openEuler:
            let directory = "\(root)/openEuler-\(release.openEulerRelease)"
            return try await rpm(["\(directory)/OS/aarch64/", "\(directory)/update/aarch64/"], optional: 1, kernels: [["kernel"]], fetch: fetch)
        case .openSUSE:
            let repository = release.isTumbleweed
                ? "\(root)/ports/aarch64/tumbleweed/repo/oss/"
                : "\(root)/distribution/leap/\(version)/repo/oss/aarch64/"
            return try await rpm([repository], kernels: [["kernel-kvmsmall"], ["kernel-default-base"]], fetch: fetch)
        case .alpine:
            let branch = version.contains("_") ? "edge" : "v" + version.split(separator: ".").prefix(2).joined(separator: ".")
            return try await apk("\(root)/\(branch)/main", name: "linux-virt", fetch: fetch)
        case .arch:
            return try await pacman("\(root)/aarch64/core", name: "linux-aarch64", fetch: fetch)
        case .void:
            return try await xbps("\(root)/current/aarch64", meta: "linux", fetch: fetch)
        }
    }

    @concurrent func register(_ installed: [Installed], in builder: LinuxRootImageBuilder) async throws {
        switch distribution {
        case .debian, .devuan, .kali, .ubuntu:
            try registerDpkg(installed, in: builder)
        case .alma, .centos, .fedora, .openEuler, .openSUSE, .oracle, .rocky:
            for item in installed {
                try builder.write(Data(contentsOf: item.file, options: .alwaysMapped), to: "\(Self.stagingDirectory)/\(item.file.lastPathComponent)")
            }
        case .alpine:
            try registerAPK(installed, in: builder)
        case .arch:
            try registerPacman(installed, in: builder)
        case .void:
            try registerXBPS(installed, in: builder)
        }
        let names = installed.map { "\($0.package.name) \($0.package.version)\n" }.joined()
        try builder.write(Data(names.utf8), to: "\(Self.stagingDirectory)/packages")
    }

    // MARK: - APT

    private struct AptSource {
        let base: String
        let suite: String
        var optional = false
    }

    private struct AptStanza {
        let base: String
        let fields: [String: String]

        var name: String {
            fields["Package"] ?? ""
        }

        var version: String {
            fields["Version"] ?? ""
        }

        var dependencies: [(name: String, version: String?)] {
            ["Pre-Depends", "Depends"].compactMap { fields[$0] }.flatMap { $0.split(separator: ",") }.compactMap { clause in
                guard let first = clause.split(separator: "|").first else { return nil }
                let parts = first.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").first else { return nil }
                var version: String?
                if parts.count == 2 {
                    let relation = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                    if relation.hasPrefix("="), !relation.hasPrefix("=>") {
                        version = relation.dropFirst().trimmingCharacters(in: .whitespaces)
                    }
                }
                return (String(name), version)
            }
        }
    }

    private func apt(_ sources: [AptSource], metas: [String], fetch: Fetch) async throws -> [KernelPackage] {
        var stanzas: [String: [AptStanza]] = [:]
        for source in sources {
            let dists = "\(source.base)/dists/\(source.suite)"
            let releaseFile: URL
            do {
                releaseFile = try await fetch(URL(string: "\(dists)/Release")!)
            } catch let error as HTTPStatusError where error.statusCode == 404 && source.optional {
                continue
            }
            let index = try Self.aptIndex(in: String(decoding: Data(contentsOf: releaseFile), as: UTF8.self))
            try? FileManager.default.removeItem(at: releaseFile)
            guard let index else {
                throw KernelBootstrapError.invalidIndex(URL(string: "\(dists)/Release")!)
            }
            let file = try await fetch(URL(string: "\(dists)/\(index)")!)
            defer { try? FileManager.default.removeItem(at: file) }
            try Self.scanAptIndex(file, base: source.base, metas: Set(metas)) { stanza in
                stanzas[stanza.name, default: []].append(stanza)
            }
        }
        func newest(_ name: String, version: String? = nil) -> AptStanza? {
            (stanzas[name] ?? []).filter { version == nil || $0.version == version }.max {
                PackageVersion.compareDebian($0.version, $1.version) < 0
            }
        }
        guard let meta = metas.lazy.compactMap({ newest($0) }).first else {
            throw KernelBootstrapError.kernelUnavailable(distribution.displayName)
        }
        var selected = [meta]
        var index = 0
        while index < selected.count {
            for dependency in selected[index].dependencies
                where Self.isKernelPackage(dependency.name) && !selected.contains(where: { $0.name == dependency.name })
            {
                if let stanza = newest(dependency.name, version: dependency.version) {
                    selected.append(stanza)
                }
            }
            index += 1
        }
        return try selected.enumerated().map { offset, stanza in
            guard let filename = stanza.fields["Filename"], let url = URL(string: "\(stanza.base)/\(filename)") else {
                throw KernelBootstrapError.invalidPackage(stanza.name)
            }
            return KernelPackage(
                name: stanza.name,
                version: stanza.version,
                url: url,
                record: nil,
                isDependency: offset > 0
            )
        }
    }

    private static func isKernelPackage(_ name: String) -> Bool {
        name.hasPrefix("linux-image-") || name.hasPrefix("linux-modules-") ||
            name.hasPrefix("linux-base-") || name.hasPrefix("linux-binary-")
    }

    private static func aptIndex(in text: String) -> String? {
        var paths: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix(" ") {
            let fields = line.split(separator: " ")
            if fields.count == 3, Int64(fields[1]) != nil {
                paths.insert(String(fields[2]))
            }
        }
        return ["main/binary-arm64/Packages.xz", "main/binary-arm64/Packages.gz", "main/binary-arm64/Packages"].first(where: paths.contains)
    }

    private static func scanAptIndex(_ file: URL, base: String, metas: Set<String>, _ body: (AptStanza) -> Void) throws {
        var lines: [String]?
        func finish() {
            guard let current = lines else { return }
            var fields: [String: String] = [:]
            var key: String?
            for line in current {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if let key {
                        fields[key, default: ""] += "\n" + line
                    }
                } else if let colon = line.firstIndex(of: ":") {
                    key = String(line[..<colon])
                    fields[key!] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            body(AptStanza(base: base, fields: fields))
            lines = nil
        }
        let prefix = Array("Package: ".utf8)
        try LineScanner.scan(file) { line in
            if line.isEmpty {
                finish()
            } else if line.count > prefix.count, line.starts(with: prefix) {
                finish()
                let name = String(decoding: UnsafeBufferPointer(rebasing: line[prefix.count...]), as: UTF8.self)
                if isKernelPackage(name) || metas.contains(name) {
                    lines = [String(decoding: line, as: UTF8.self)]
                }
            } else if lines != nil {
                lines!.append(String(decoding: line, as: UTF8.self))
            }
        }
        finish()
    }

    // MARK: - RPM

    private struct RPMRecord {
        let name: String
        let epoch: String
        let version: String
        let release: String
        let url: URL

        var evr: String {
            "\(epoch):\(version)-\(release)"
        }
    }

    private func rpm(_ repositories: [String], optional: Int = 0, kernels: [[String]], fetch: Fetch) async throws -> [KernelPackage] {
        let names = Set(kernels.flatMap(\.self))
        var records: [String: [RPMRecord]] = [:]
        for (index, repository) in repositories.enumerated() {
            let repomdURL = URL(string: "\(repository)repodata/repomd.xml")!
            let repomd: URL
            do {
                repomd = try await fetch(repomdURL)
            } catch let error as HTTPStatusError where error.statusCode == 404 && index >= repositories.count - optional {
                continue
            }
            let text = try String(decoding: Data(contentsOf: repomd), as: UTF8.self)
            try? FileManager.default.removeItem(at: repomd)
            guard let primary = Self.primaryLocation(in: text), let primaryURL = URL(string: primary, relativeTo: URL(string: repository)) else {
                throw KernelBootstrapError.invalidIndex(repomdURL)
            }
            let file = try await fetch(primaryURL.absoluteURL)
            defer { try? FileManager.default.removeItem(at: file) }
            try Self.scanPrimary(file, base: URL(string: repository)!, names: names) { record in
                records[record.name, default: []].append(record)
            }
        }
        for group in kernels {
            guard let primary = records[group[0]]?.max(by: { PackageVersion.compareEVR($0.evr, $1.evr) < 0 }) else { continue }
            let companions = group.dropFirst().compactMap { name in
                records[name]?.first { $0.evr == primary.evr }
            }
            return ([primary] + companions).map { record in
                KernelPackage(
                    name: record.name,
                    version: "\(record.version)-\(record.release)",
                    url: record.url,
                    record: nil,
                    isDependency: record.name != primary.name
                )
            }
        }
        throw KernelBootstrapError.kernelUnavailable(distribution.displayName)
    }

    private static func primaryLocation(in repomd: String) -> String? {
        guard let start = repomd.range(of: "<data type=\"primary\">"),
              let end = repomd.range(of: "</data>", range: start.upperBound ..< repomd.endIndex)
        else {
            return nil
        }
        return attribute("href", in: String(repomd[start.upperBound ..< end.lowerBound]))
    }

    private static func scanPrimary(_ file: URL, base: URL, names: Set<String>, _ body: (RPMRecord) -> Void) throws {
        var lines: [String]?
        var inPackage = false
        try LineScanner.scan(file) { line in
            let text = trimmedStart(line)
            if text.starts(with: Array("<package ".utf8)) {
                inPackage = true
                lines = nil
                return
            }
            guard inPackage else { return }
            if text.starts(with: Array("</package>".utf8)) {
                inPackage = false
                if let current = lines, let record = rpmRecord(current, base: base) {
                    body(record)
                }
                lines = nil
                return
            }
            if lines == nil, text.starts(with: Array("<name>".utf8)) {
                let name = element("name", in: String(decoding: text, as: UTF8.self)) ?? ""
                if names.contains(name) {
                    lines = [String(decoding: text, as: UTF8.self)]
                } else {
                    inPackage = false
                }
                return
            }
            lines?.append(String(decoding: text, as: UTF8.self))
        }
    }

    private static func rpmRecord(_ lines: [String], base: URL) -> RPMRecord? {
        var name: String?
        var arch: String?
        var version: (String, String, String)?
        var href: String?
        for line in lines {
            if line.hasPrefix("<name>") {
                name = element("name", in: line)
            } else if line.hasPrefix("<arch>") {
                arch = element("arch", in: line)
            } else if line.hasPrefix("<version "), let ver = attribute("ver", in: line), let rel = attribute("rel", in: line) {
                version = (attribute("epoch", in: line) ?? "0", ver, rel)
            } else if line.hasPrefix("<location ") {
                href = attribute("href", in: line)
            }
        }
        guard let name, arch == "aarch64", let version, let href, let url = URL(string: href, relativeTo: base) else {
            return nil
        }
        return RPMRecord(name: name, epoch: version.0, version: version.1, release: version.2, url: url.absoluteURL)
    }

    private static func trimmedStart(_ line: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var start = 0
        while start < line.count, line[start] == 0x20 || line[start] == 0x09 {
            start += 1
        }
        return UnsafeBufferPointer(rebasing: line[start...])
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: " \(name)=\""), let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(text[start.upperBound ..< end])
    }

    private static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)"),
              let close = text[open.upperBound...].firstIndex(of: ">"),
              let end = text.range(of: "</\(name)>", range: close ..< text.endIndex)
        else {
            return nil
        }
        return String(text[text.index(after: close) ..< end.lowerBound])
    }

    // MARK: - APK

    private func apk(_ repository: String, name: String, fetch: Fetch) async throws -> [KernelPackage] {
        let indexURL = URL(string: "\(repository)/aarch64/APKINDEX.tar.gz")!
        let file = try await fetch(indexURL)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let index = try Self.archiveFile(named: "APKINDEX", in: file) else {
            throw KernelBootstrapError.invalidIndex(indexURL)
        }
        let records = String(decoding: index, as: UTF8.self).components(separatedBy: "\n\n")
        guard let record = records.first(where: { $0.hasPrefix("P:\(name)\n") || $0.contains("\nP:\(name)\n") }) else {
            throw KernelBootstrapError.kernelUnavailable(distribution.displayName)
        }
        let fields = Self.apkFields(record)
        guard let version = fields["V"], let url = URL(string: "\(repository)/aarch64/\(name)-\(version).apk") else {
            throw KernelBootstrapError.invalidIndex(indexURL)
        }
        return [KernelPackage(
            name: name,
            version: version,
            url: url,
            record: Data(record.trimmingCharacters(in: .newlines).utf8),
            isDependency: false
        )]
    }

    private static func apkFields(_ record: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in record.split(separator: "\n") where line.count > 2 && line.dropFirst().first == ":" {
            fields[String(line.prefix(1))] = String(line.dropFirst(2))
        }
        return fields
    }

    // MARK: - pacman

    private func pacman(_ repository: String, name: String, fetch: Fetch) async throws -> [KernelPackage] {
        let databaseURL = URL(string: "\(repository)/core.db")!
        let file = try await fetch(databaseURL)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = try LinuxArchiveReader(contentsOf: file)
        while let path = try reader.next() {
            guard path.hasPrefix("\(name)-"), path.hasSuffix("/desc") else { continue }
            let desc = try Self.pacmanSections(String(decoding: reader.readToEnd(), as: UTF8.self))
            guard desc["NAME"]?.first == name else { continue }
            guard let version = desc["VERSION"]?.first, let filename = desc["FILENAME"]?.first,
                  let url = URL(string: "\(repository)/\(filename)")
            else {
                throw KernelBootstrapError.invalidIndex(databaseURL)
            }
            return [KernelPackage(
                name: name,
                version: version,
                url: url,
                record: nil,
                isDependency: false
            )]
        }
        throw KernelBootstrapError.kernelUnavailable(distribution.displayName)
    }

    private static func pacmanSections(_ text: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var key: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.count > 2, line.hasPrefix("%"), line.hasSuffix("%") {
                key = String(line.dropFirst().dropLast())
                sections[key!] = []
            } else if line.isEmpty {
                key = nil
            } else if let key {
                sections[key]!.append(String(line))
            }
        }
        return sections
    }

    // MARK: - XBPS

    private func xbps(_ repository: String, meta: String, fetch: Fetch) async throws -> [KernelPackage] {
        let indexURL = URL(string: "\(repository)/aarch64-repodata")!
        let file = try await fetch(indexURL)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let index = try Self.archiveFile(named: "index.plist", in: file) else {
            throw KernelBootstrapError.invalidIndex(indexURL)
        }
        guard let metaEntry = Self.xbpsEntry(meta, in: index) else {
            throw KernelBootstrapError.kernelUnavailable(distribution.displayName)
        }
        let series = (metaEntry["run_depends"] as? [String] ?? []).compactMap { dependency -> String? in
            let name = dependency.prefix { $0 != ">" && $0 != "<" && $0 != "=" }
            return name.wholeMatch(of: /linux[0-9]+\.[0-9]+/) != nil ? String(name) : nil
        }
        guard let kernel = series.first, let kernelEntry = Self.xbpsEntry(kernel, in: index) else {
            throw KernelBootstrapError.kernelUnavailable(distribution.displayName)
        }
        return try [(meta, metaEntry, false), (kernel, kernelEntry, true)].map { name, entry, isDependency in
            guard let pkgver = entry["pkgver"] as? String, let url = URL(string: "\(repository)/\(pkgver).aarch64.xbps") else {
                throw KernelBootstrapError.invalidIndex(indexURL)
            }
            return try KernelPackage(
                name: name,
                version: String(pkgver.dropFirst(name.count + 1)),
                url: url,
                record: PropertyListSerialization.data(fromPropertyList: entry, format: .xml, options: 0),
                isDependency: isDependency
            )
        }
    }

    private static func xbpsEntry(_ name: String, in index: Data) -> [String: Any]? {
        guard let start = index.range(of: Data("\n\t<key>\(name)</key>\n\t<dict>".utf8)),
              let end = index.range(of: Data("\n\t</dict>".utf8), in: start.upperBound ..< index.endIndex)
        else {
            return nil
        }
        var plist = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>".utf8)
        plist.append(index[start.upperBound ..< end.lowerBound])
        plist.append(Data("\n</dict>\n</plist>\n".utf8))
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }

    private static func archiveFile(named name: String, in file: URL) throws -> Data? {
        let reader = try LinuxArchiveReader(contentsOf: file)
        while let path = try reader.next() {
            if path == name || path == "./\(name)" {
                return try reader.readToEnd()
            }
        }
        return nil
    }

    // MARK: - Package databases

    private func registerDpkg(_ installed: [Installed], in builder: LinuxRootImageBuilder) throws {
        var status = try String(decoding: builder.contents(of: "/var/lib/dpkg/status") ?? Data(), as: UTF8.self)
        for item in installed {
            let metadata = item.contents.metadata
            guard let controlData = metadata["control"] else {
                throw KernelBootstrapError.invalidPackage(item.package.name)
            }
            var control = String(decoding: controlData, as: UTF8.self).trimmingCharacters(in: .newlines)
            let fields = Self.controlFields(control)
            guard let name = fields["Package"], let architecture = fields["Architecture"],
                  let packageLine = control.range(of: "Package: \(name)")
            else {
                throw KernelBootstrapError.invalidPackage(item.package.name)
            }
            control.insert(contentsOf: "\nStatus: install ok unpacked", at: packageLine.upperBound)
            let conffiles = metadata["conffiles"].map { String(decoding: $0, as: UTF8.self) }?
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
            if !conffiles.isEmpty {
                control += "\nConffiles:" + conffiles.map { "\n \($0) newconffile" }.joined()
            }
            if !status.isEmpty {
                status = status.trimmingCharacters(in: .newlines) + "\n\n"
            }
            status += control + "\n"

            let infoName = fields["Multi-Arch"] == "same" ? "\(name):\(architecture)" : name
            let info = "/var/lib/dpkg/info/\(infoName)"
            let list = (["/."] + item.contents.entries.map(\.path).filter { $0 != "/" }).joined(separator: "\n") + "\n"
            try builder.write(Data(list.utf8), to: "\(info).list")
            for (member, data) in metadata where member != "control" {
                let executable = ["preinst", "postinst", "prerm", "postrm", "config"].contains(member)
                try builder.write(data, to: "\(info).\(member)", permissions: executable ? 0o755 : 0o644)
            }
        }
        try builder.write(Data(status.utf8), to: "/var/lib/dpkg/status")
    }

    private static func controlFields(_ control: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in control.split(separator: "\n") where !line.hasPrefix(" ") {
            if let colon = line.firstIndex(of: ":") {
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }

    private func registerPacman(_ installed: [Installed], in builder: LinuxRootImageBuilder) throws {
        for item in installed {
            let metadata = item.contents.metadata
            guard let pkginfo = metadata[".PKGINFO"] else {
                throw KernelBootstrapError.invalidPackage(item.package.name)
            }
            var info: [String: [String]] = [:]
            for line in String(decoding: pkginfo, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    info[parts[0].trimmingCharacters(in: .whitespaces), default: []].append(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let name = info["pkgname"]?.first, let version = info["pkgver"]?.first else {
                throw KernelBootstrapError.invalidPackage(item.package.name)
            }
            let sections: [(String, [String]?)] = [
                ("NAME", [name]),
                ("VERSION", [version]),
                ("BASE", info["pkgbase"]),
                ("DESC", info["pkgdesc"]),
                ("URL", info["url"]),
                ("ARCH", info["arch"]),
                ("BUILDDATE", info["builddate"]),
                ("INSTALLDATE", [String(Int(Date().timeIntervalSince1970))]),
                ("PACKAGER", info["packager"]),
                ("SIZE", info["size"]),
                ("REASON", item.package.isDependency ? ["1"] : nil),
                ("GROUPS", info["group"]),
                ("LICENSE", info["license"]),
                ("VALIDATION", ["none"]),
                ("REPLACES", info["replaces"]),
                ("DEPENDS", info["depend"]),
                ("OPTDEPENDS", info["optdepend"]),
                ("CONFLICTS", info["conflict"]),
                ("PROVIDES", info["provides"]),
                ("XDATA", info["xdata"]),
            ]
            let desc = sections.compactMap { key, values -> String? in
                guard let values, !values.isEmpty else { return nil }
                return "%\(key)%\n" + values.joined(separator: "\n") + "\n\n"
            }.joined()
            let paths = item.contents.entries.filter { $0.path != "/" }.map { entry in
                String(entry.path.dropFirst()) + (entry.type == .directory ? "/" : "")
            }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let files = "%FILES%\n" + paths.map { "\($0)\n" }.joined() + "\n"
            let directory = "/var/lib/pacman/local/\(name)-\(version)"
            try builder.write(Data(desc.utf8), to: "\(directory)/desc")
            try builder.write(Data(files.utf8), to: "\(directory)/files")
            if let mtree = metadata[".MTREE"] {
                try builder.write(mtree, to: "\(directory)/mtree")
            }
            if let install = metadata[".INSTALL"] {
                try builder.write(install, to: "\(directory)/install")
            }
        }
    }

    private func registerAPK(_ installed: [Installed], in builder: LinuxRootImageBuilder) throws {
        var database = try String(decoding: builder.contents(of: "/lib/apk/db/installed") ?? Data(), as: UTF8.self)
        var world = try String(decoding: builder.contents(of: "/etc/apk/world") ?? Data(), as: UTF8.self)
        for item in installed {
            guard let record = item.package.record else {
                throw KernelBootstrapError.invalidPackage(item.package.name)
            }
            var directories: [String] = []
            var files: [String: [String]] = [:]
            func directory(_ path: String) {
                if files[path] == nil {
                    directories.append(path)
                    files[path] = []
                }
            }
            for entry in item.contents.entries where entry.path != "/" {
                let path = String(entry.path.dropFirst())
                if entry.type == .directory {
                    directory(path)
                    if entry.permissions != 0o755 {
                        files[path]!.append("M:0:0:\(String(entry.permissions, radix: 8))")
                    }
                    continue
                }
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                directory(parent)
                var lines = ["R:\(path.split(separator: "/").last ?? "")"]
                let permissions = entry.type == .symbolicLink ? 0o777 : entry.permissions
                if permissions != 0o644 {
                    lines.append("a:0:0:\(String(permissions, radix: 8))")
                }
                if let sha1 = entry.sha1 {
                    lines.append("Z:Q1\(sha1.base64EncodedString())")
                }
                files[parent]!.append(contentsOf: lines)
            }
            var entry = String(decoding: record, as: UTF8.self)
            for path in directories {
                if !path.isEmpty {
                    entry += "\nF:\(path)"
                }
                for line in files[path]! {
                    entry += "\n\(line)"
                }
            }
            database = database.trimmingCharacters(in: .newlines)
            database += (database.isEmpty ? "" : "\n\n") + entry + "\n\n"
            if !world.split(separator: "\n").contains(Substring(item.package.name)) {
                world = world.trimmingCharacters(in: .newlines)
                world += (world.isEmpty ? "" : "\n") + item.package.name + "\n"
            }
        }
        try builder.write(Data(database.utf8), to: "/lib/apk/db/installed")
        try builder.write(Data(world.utf8), to: "/etc/apk/world")
    }

    private func registerXBPS(_ installed: [Installed], in builder: LinuxRootImageBuilder) throws {
        let databasePath = "/var/db/xbps/pkgdb-0.38.plist"
        var database = try builder.contents(of: databasePath).flatMap {
            try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        let installDate = formatter.string(from: Date())
        for item in installed {
            guard let record = item.package.record,
                  var entry = try PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any]
            else {
                throw KernelBootstrapError.invalidPackage(item.package.name)
            }
            let name = item.package.name
            entry["pkgname"] = name
            entry["repository"] = "\(root)/current/aarch64"
            entry["install-date"] = installDate
            entry["state"] = "installed"
            if item.package.isDependency {
                entry["automatic-install"] = true
            }
            if let script = item.contents.metadata["INSTALL"] {
                entry["install-script"] = script
            }
            if let script = item.contents.metadata["REMOVE"] {
                entry["remove-script"] = script
            }
            if let files = item.contents.metadata["files.plist"],
               let dictionary = try PropertyListSerialization.propertyList(from: files, format: nil) as? [String: Any],
               !dictionary.isEmpty
            {
                try builder.write(files, to: "/var/db/xbps/.\(name)-files.plist")
                entry["metafile-sha256"] = SHA256.hash(data: files).map { String(format: "%02x", $0) }.joined()
            }
            database[name] = entry
        }
        try builder.write(
            PropertyListSerialization.data(fromPropertyList: database, format: .xml, options: 0),
            to: databasePath
        )
    }
}

private nonisolated extension OSRelease {
    var openEulerRelease: String {
        let versionID = versionID ?? ""
        guard let version, let open = version.firstIndex(of: "("), let close = version.lastIndex(of: ")"), open < close else {
            return versionID
        }
        return "\(versionID)-\(version[version.index(after: open) ..< close])"
    }
}

private nonisolated enum LineScanner {
    static func scan(_ file: URL, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let reader = try LinuxArchiveReader(contentsOf: file)
        guard try reader.next() != nil else { return }
        var pending = Data()
        while true {
            let chunk = try reader.read(upToCount: 1 << 20)
            if chunk.isEmpty {
                try pending.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    if !bytes.isEmpty {
                        try body(bytes)
                    }
                }
                return
            }
            pending.append(chunk)
            let consumed = try pending.withUnsafeBytes { raw -> Int in
                let bytes = raw.bindMemory(to: UInt8.self)
                guard let base = bytes.baseAddress else { return 0 }
                var start = 0
                while start < bytes.count, let newline = memchr(base + start, 0x0A, bytes.count - start) {
                    let end = UnsafePointer(newline.assumingMemoryBound(to: UInt8.self)) - base
                    var line = UnsafeBufferPointer(rebasing: bytes[start ..< end])
                    if line.last == 0x0D {
                        line = UnsafeBufferPointer(rebasing: line.dropLast())
                    }
                    try body(line)
                    start = end + 1
                }
                return start
            }
            pending.removeSubrange(0 ..< consumed)
        }
    }
}

nonisolated enum PackageVersion {
    static func compareDebian(_ a: String, _ b: String) -> Int {
        func split(_ version: String) -> (Int, [UInt8], [UInt8]) {
            var rest = Substring(version)
            var epoch = 0
            if let colon = rest.firstIndex(of: ":") {
                epoch = Int(rest[..<colon]) ?? 0
                rest = rest[rest.index(after: colon)...]
            }
            var revision = Substring("")
            if let dash = rest.lastIndex(of: "-") {
                revision = rest[rest.index(after: dash)...]
                rest = rest[..<dash]
            }
            return (epoch, Array(rest.utf8), Array(revision.utf8))
        }
        let (ea, ua, ra) = split(a)
        let (eb, ub, rb) = split(b)
        if ea != eb {
            return ea < eb ? -1 : 1
        }
        let upstream = compareDebianPart(ua, ub)
        return upstream != 0 ? upstream : compareDebianPart(ra, rb)
    }

    private static func compareDebianPart(_ a: [UInt8], _ b: [UInt8]) -> Int {
        func isDigit(_ c: UInt8) -> Bool {
            c >= 0x30 && c <= 0x39
        }
        func order(_ c: UInt8?) -> Int {
            guard let c else { return 0 }
            if isDigit(c) {
                return 0
            }
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
                return Int(c)
            }
            if c == 0x7E {
                return -1
            }
            return Int(c) + 256
        }
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let ac = order(i < a.count ? a[i] : nil)
                let bc = order(j < b.count ? b[j] : nil)
                if ac != bc {
                    return ac < bc ? -1 : 1
                }
                i += 1
                j += 1
            }
            while i < a.count, a[i] == 0x30 {
                i += 1
            }
            while j < b.count, b[j] == 0x30 {
                j += 1
            }
            var difference = 0
            while i < a.count, isDigit(a[i]), j < b.count, isDigit(b[j]) {
                if difference == 0 {
                    difference = Int(a[i]) - Int(b[j])
                }
                i += 1
                j += 1
            }
            if i < a.count, isDigit(a[i]) {
                return 1
            }
            if j < b.count, isDigit(b[j]) {
                return -1
            }
            if difference != 0 {
                return difference < 0 ? -1 : 1
            }
        }
        return 0
    }

    static func compareEVR(_ a: String, _ b: String) -> Int {
        func split(_ evr: String) -> (String, String, String) {
            let (epoch, rest) = evr.firstIndex(of: ":").map { (String(evr[..<$0]), String(evr[evr.index(after: $0)...])) } ?? ("0", evr)
            let (version, release) = rest.lastIndex(of: "-").map { (String(rest[..<$0]), String(rest[rest.index(after: $0)...])) } ?? (rest, "")
            return (epoch, version, release)
        }
        let x = split(a)
        let y = split(b)
        for (p, q) in [(x.0, y.0), (x.1, y.1), (x.2, y.2)] {
            let result = compareRPM(p, q)
            if result != 0 {
                return result
            }
        }
        return 0
    }

    static func compareRPM(_ a: String, _ b: String) -> Int {
        if a == b {
            return 0
        }
        func isAlnum(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }
        func isDigit(_ c: UInt8) -> Bool {
            c >= 0x30 && c <= 0x39
        }
        var x = ArraySlice(a.utf8)
        var y = ArraySlice(b.utf8)
        while !x.isEmpty || !y.isEmpty {
            while let c = x.first, !isAlnum(c), c != 0x7E, c != 0x5E {
                x = x.dropFirst()
            }
            while let c = y.first, !isAlnum(c), c != 0x7E, c != 0x5E {
                y = y.dropFirst()
            }
            if x.first == 0x7E || y.first == 0x7E {
                if x.first != 0x7E {
                    return 1
                }
                if y.first != 0x7E {
                    return -1
                }
                x = x.dropFirst()
                y = y.dropFirst()
                continue
            }
            if x.first == 0x5E || y.first == 0x5E {
                if x.isEmpty {
                    return -1
                }
                if y.isEmpty {
                    return 1
                }
                if x.first != 0x5E {
                    return 1
                }
                if y.first != 0x5E {
                    return -1
                }
                x = x.dropFirst()
                y = y.dropFirst()
                continue
            }
            if x.isEmpty || y.isEmpty {
                break
            }
            let numeric = isDigit(x.first!)
            let predicate: (UInt8) -> Bool = numeric ? isDigit : { isAlnum($0) && !isDigit($0) }
            var p = x.prefix(while: predicate)
            var q = y.prefix(while: predicate)
            x = x.dropFirst(p.count)
            y = y.dropFirst(q.count)
            if q.isEmpty {
                return numeric ? 1 : -1
            }
            if numeric {
                p = p.drop { $0 == 0x30 }
                q = q.drop { $0 == 0x30 }
                if p.count != q.count {
                    return p.count < q.count ? -1 : 1
                }
            }
            if p != q {
                return p.lexicographicallyPrecedes(q) ? -1 : 1
            }
        }
        if x.isEmpty, y.isEmpty {
            return 0
        }
        return x.isEmpty ? -1 : 1
    }
}

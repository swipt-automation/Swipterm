import Foundation
import Observation
import SwiptermKit

nonisolated enum LinuxDistribution: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case alma
    case alpine
    case arch
    case centos
    case debian
    case devuan
    case fedora
    case kali
    case openEuler
    case openSUSE
    case oracle
    case rocky
    case ubuntu
    case void

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .alma: "Alma"
        case .alpine: "Alpine"
        case .arch: "Arch"
        case .centos: "CentOS"
        case .debian: "Debian"
        case .devuan: "Devuan"
        case .fedora: "Fedora"
        case .kali: "Kali"
        case .openEuler: "openEuler"
        case .openSUSE: "openSUSE"
        case .oracle: "Oracle"
        case .rocky: "Rocky"
        case .ubuntu: "Ubuntu"
        case .void: "Void"
        }
    }

    var defaultContainerName: String {
        switch self {
        case .alma: "alma"
        case .alpine: "alpine"
        case .arch: "arch"
        case .centos: "centos"
        case .debian: "debian"
        case .devuan: "devuan"
        case .fedora: "fedora"
        case .kali: "kali"
        case .openEuler: "openeuler"
        case .openSUSE: "opensuse"
        case .oracle: "oracle"
        case .rocky: "rocky"
        case .ubuntu: "ubuntu"
        case .void: "void"
        }
    }

    var simplestreamsOSKey: String? {
        switch self {
        case .alma: "almalinux"
        case .alpine: "alpine"
        case .arch: "archlinux"
        case .centos: "centos"
        case .debian: "debian"
        case .devuan: "devuan"
        case .fedora: "fedora"
        case .kali: "kali"
        case .openEuler: "openeuler"
        case .openSUSE: "opensuse"
        case .oracle: "oracle"
        case .rocky: "rockylinux"
        case .ubuntu: "ubuntu"
        case .void: nil
        }
    }

    static func fromSimplestreamsOS(_ os: String) -> LinuxDistribution? {
        let normalized = os.lowercased()
        return allCases.first { $0.simplestreamsOSKey == normalized }
    }

    fileprivate var imageServerURL: URL {
        switch self {
        case .alma, .alpine, .arch, .centos, .debian, .devuan, .fedora, .kali, .openEuler, .openSUSE, .oracle, .rocky, .ubuntu:
            LinuxDistributionCatalogClient.simplestreamsServerURL
        case .void:
            LinuxDistributionCatalogClient.voidServerURL
        }
    }

    fileprivate var unsupportedReleases: Set<String> {
        switch self {
        case .alma, .oracle, .rocky: ["8"]
        default: []
        }
    }
}

nonisolated struct LinuxReleaseImage: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let distribution: LinuxDistribution
    let releaseKey: String
    let displayTitle: String
    let buildSerial: String
    let artifactPath: String
    let sortRank: Int
    let isRecommended: Bool

    var archiveURL: URL {
        distribution.imageServerURL.appending(path: artifactPath, directoryHint: .notDirectory)
    }
}

nonisolated struct ContainerSetup: Codable, Equatable, Sendable {
    var password: String?
    var software: ContainerSoftware
}

nonisolated struct ContainerMetadata: Codable, Equatable, Sendable {
    var schemaVersion = 2
    let name: String
    var distributionID: String?
    let installedAt: Date
    var defaultUser: String
    var setupCompleted: Bool
    var setup: ContainerSetup?

    var distribution: LinuxDistribution? {
        distributionID.flatMap(LinuxDistribution.init(rawValue:))
    }
}

nonisolated struct LinuxContainer: Identifiable, Equatable, Sendable {
    let id: String
    var metadata: ContainerMetadata
}

@Observable
final class LinuxDistributionCatalogStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var releasesByDistribution: [LinuxDistribution: [LinuxReleaseImage]] = [:]

    private var activeTask: Task<Void, Never>?

    private let fetchReleases: () async throws -> [LinuxDistribution: [LinuxReleaseImage]]

    init() {
        #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            let releases = [LinuxDistribution.alpine: [StoreScreenshot.alpineRelease]]
            fetchReleases = { releases }
            releasesByDistribution = releases
            loadState = .loaded
        #else
            fetchReleases = LinuxDistributionCatalogClient.fetchARM64Catalog
        #endif
    }

    func releases(for distribution: LinuxDistribution) -> [LinuxReleaseImage] {
        releasesByDistribution[distribution] ?? []
    }

    func defaultRelease(for distribution: LinuxDistribution) -> LinuxReleaseImage? {
        let releases = releases(for: distribution)
        return releases.first(where: \.isRecommended) ?? releases.first
    }

    func loadIfNeeded() async {
        switch loadState {
        case .loaded, .failed:
            return
        case .loading:
            await activeTask?.value
        case .idle:
            await refresh()
        }
    }

    func refresh() async {
        activeTask?.cancel()
        loadState = .loading
        let task = Task<Void, Never> {
            do {
                let releases = try await fetchReleases()
                guard !Task.isCancelled else { return }
                releasesByDistribution = releases
                loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                releasesByDistribution = [:]
                loadState = .failed(error.localizedDescription)
            }
            activeTask = nil
        }
        activeTask = task
        await task.value
    }
}

private nonisolated enum LinuxDistributionCatalogClient {
    static let simplestreamsServerURL = URL(string: "https://images.linuxcontainers.org")!
    static let voidServerURL = URL(string: "https://repo-fastly.voidlinux.org")!

    static func fetchARM64Catalog() async throws -> [LinuxDistribution: [LinuxReleaseImage]] {
        async let lxc = fetchLXCIndex()
        async let void = fetchVoid()

        return try await Dictionary(grouping: lxc + void, by: \.distribution).mapValues { images in
            images.sorted { lhs, rhs in
                if lhs.sortRank != rhs.sortRank {
                    return lhs.sortRank > rhs.sortRank
                }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedDescending
            }
        }
    }

    private static func fetch(_ path: String, from server: URL) async throws -> String {
        let (data, response) = try await HTTPClient.data(from: server.appending(path: path, directoryHint: .notDirectory))
        try response.requireSuccess()
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    private static func fetchLXCIndex() async throws -> [LinuxReleaseImage] {
        let index = try await fetch("meta/1.0/index-system", from: simplestreamsServerURL)
        var latestByID: [String: LinuxReleaseImage] = [:]
        for line in index.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 6,
                  fields[2] == "arm64",
                  fields[3] == "default"
            else {
                continue
            }
            let os = String(fields[0])
            let release = String(fields[1])
            let serial = String(fields[4])
            let directory = fields[5].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let distribution = LinuxDistribution.fromSimplestreamsOS(os),
                  !distribution.unsupportedReleases.contains(release),
                  !serial.isEmpty,
                  !directory.isEmpty
            else {
                continue
            }
            let id = "\(os):\(release):arm64:default"
            if let existing = latestByID[id], existing.buildSerial >= serial {
                continue
            }
            let label = formatReleaseLabel(distribution: distribution, release: release)
            latestByID[id] = LinuxReleaseImage(
                id: id,
                distribution: distribution,
                releaseKey: release,
                displayTitle: label.title,
                buildSerial: serial,
                artifactPath: "\(directory)/rootfs.tar.xz",
                sortRank: label.rank,
                isRecommended: distribution == .ubuntu && release.lowercased() == "noble"
            )
        }
        if latestByID.isEmpty {
            throw URLError(.cannotParseResponse)
        }
        return Array(latestByID.values)
    }

    private static func fetchVoid() async throws -> [LinuxReleaseImage] {
        let checksums = try await fetch("live/current/sha256sum.txt", from: voidServerURL)
        let prefix = "void-aarch64-ROOTFS-"
        for line in checksums.split(whereSeparator: \.isNewline) {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let file = String(line[line.index(after: open) ..< close])
            guard file.hasPrefix(prefix), file.hasSuffix(".tar.xz") else { continue }
            let serial = String(file.dropFirst(prefix.count).dropLast(".tar.xz".count))
            guard !serial.isEmpty, serial.allSatisfy(\.isNumber) else { continue }
            return [LinuxReleaseImage(
                id: "void:rootfs:arm64:glibc",
                distribution: .void,
                releaseKey: "current",
                displayTitle: "Rolling",
                buildSerial: serial,
                artifactPath: "live/\(serial)/\(file)",
                sortRank: 1000,
                isRecommended: true
            )]
        }
        throw URLError(.cannotParseResponse)
    }

    private static func formatReleaseLabel(
        distribution: LinuxDistribution,
        release: String
    ) -> (title: String, rank: Int) {
        let lowered = release.lowercased()
        switch distribution {
        case .ubuntu:
            switch lowered {
            case "resolute": return ("26.04 LTS (Resolute)", 26040)
            case "stonking": return ("26.10 (Stonking)", 26030)
            case "noble": return ("24.04 LTS (Noble)", 24040)
            case "jammy": return ("22.04 LTS (Jammy)", 22040)
            case "focal": return ("20.04 LTS (Focal)", 20040)
            default: return (release.capitalized, numericRank(release))
            }
        case .debian:
            switch lowered {
            case "trixie": return ("13 (Trixie)", 1300)
            case "bookworm": return ("12 (Bookworm)", 1200)
            case "bullseye": return ("11 (Bullseye)", 1100)
            case "forky": return ("Forky (Testing)", 1250)
            case "sid": return ("Sid (Unstable)", 1240)
            default: return (release.capitalized, numericRank(release))
            }
        case .devuan:
            switch lowered {
            case "excalibur": return ("6 (Excalibur)", 600)
            case "daedalus": return ("5 (Daedalus)", 500)
            case "chimaera": return ("4 (Chimaera)", 400)
            default: return (release.capitalized, numericRank(release))
            }
        case .alpine:
            if lowered == "edge" {
                return ("Edge", 100)
            }
            return (release, numericRank(release) + 1000)
        case .centos:
            if lowered.hasSuffix("-stream") {
                let major = release.replacingOccurrences(of: "-Stream", with: "", options: .caseInsensitive)
                return ("Stream \(major)", numericRank(major) + 1000)
            }
            return (release, numericRank(release))
        case .openSUSE:
            if lowered == "tumbleweed" {
                return ("Tumbleweed", 2000)
            }
            return ("Leap \(release)", numericRank(release) + 1000)
        case .arch, .kali:
            if lowered == "current" {
                return ("Rolling", 1000)
            }
            return (release, numericRank(release))
        case .openEuler:
            if lowered == "24.03" {
                return ("24.03 LTS", 24030)
            }
            return (release, numericRank(release))
        case .alma, .fedora, .oracle, .rocky, .void:
            return (release, numericRank(release))
        }
    }

    private static func numericRank(_ text: String) -> Int {
        let parts = text
            .split { !$0.isNumber }
            .compactMap { Int($0) }
        guard let major = parts.first else { return 0 }
        let minor = parts.count > 1 ? parts[1] : 0
        return major * 100 + minor
    }
}

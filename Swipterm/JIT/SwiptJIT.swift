#if DEBUG || SIDELOAD
    import Darwin
    import Foundation
    import Network
    import Observation
    import QuartzCore
    import SwiptermKit

    @Observable
    final class SwiptJIT {
        enum Status: Equatable {
            case searching
            case notFound
            case connecting
            case unauthenticated
            case connected
            case enabling
            case unreachable
        }

        private enum Key {
            static let isEnabled = "jitEnabled"
            static let token = "swiptToken"
        }

        private static let serviceType = "_swipt._tcp"
        private static let framesBeforeHandshake = 2
        private static let framesTimeout = Duration.milliseconds(500)

        private(set) var isPrepared = LinuxRuntime.isJITPrepared
        private(set) var isEnabled: Bool
        private(set) var token: String
        private(set) var status = Status.searching
        private(set) var requiresToken = false
        private(set) var errorMessage: String?

        var isActive: Bool {
            isPrepared && isEnabled
        }

        var isConnected: Bool {
            status == .connected || status == .enabling
        }

        @ObservationIgnored private let store: PreferenceStore
        @ObservationIgnored private var browser: NWBrowser?
        @ObservationIgnored private var candidates: [NWBrowser.Result] = []
        @ObservationIgnored private var server: URL?
        @ObservationIgnored private var serverName: String?
        @ObservationIgnored private var pendingReconnect = false
        @ObservationIgnored private var pendingUserInitiated = false
        @ObservationIgnored private var connection: Task<Void, Never>?
        @ObservationIgnored private var enableTask: Task<Void, Never>?
        @ObservationIgnored private var generation: UInt64 = 0

        init(store: PreferenceStore) {
            self.store = store
            let enabled = store.value(Bool.self, for: Key.isEnabled) ?? true
            isEnabled = enabled
            token = store.value(String.self, for: Key.token) ?? ""
            LinuxRuntime.isJITEnabled = enabled
        }

        func dismissError() {
            errorMessage = nil
        }

        func setEnabled(_ enabled: Bool) {
            isEnabled = enabled
            store.set(enabled, for: Key.isEnabled)
            LinuxRuntime.isJITEnabled = enabled
            if enabled {
                scheduleEnable()
            }
        }

        func updateToken(_ newToken: String) {
            token = newToken
            store.set(newToken, for: Key.token)
            connect(userInitiated: true)
        }

        func start() {
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                MainActor.assumeIsolated { self.browserChanged(state) }
            }
            browser.browseResultsChangedHandler = { results, _ in
                MainActor.assumeIsolated { self.resultsChanged(results) }
            }
            browser.start(queue: .main)
            self.browser = browser
        }

        private func browserChanged(_ state: NWBrowser.State) {
            switch state {
            case .failed:
                browser?.cancel()
                browser = nil
                generation &+= 1
                candidates = []
                server = nil
                serverName = nil
                connection?.cancel()
                status = .unreachable
            case .waiting:
                generation &+= 1
                candidates = []
                server = nil
                serverName = nil
                connection?.cancel()
                status = .unreachable
            case .ready:
                if let browser, !browser.browseResults.isEmpty {
                    resultsChanged(browser.browseResults)
                } else if status == .searching || status == .unreachable {
                    status = .notFound
                }
            default:
                break
            }
        }

        private func resultsChanged(_ results: Set<NWBrowser.Result>) {
            let sorted = results
                .filter { Self.txtRecord($0)["udid"] == nil }
                .sorted { Self.name($0) < Self.name($1) }
            guard sorted != candidates else { return }
            candidates = sorted
            if status == .connected, sorted.contains(where: {
                Self.name($0) == serverName && (Self.txtRecord($0)["auth"] == "1") == requiresToken
            }) {
                return
            }
            connect(userInitiated: false)
        }

        private static func name(_ result: NWBrowser.Result) -> String {
            guard case let .service(name, _, _, _) = result.endpoint else { preconditionFailure() }
            return name
        }

        private static func txtRecord(_ result: NWBrowser.Result) -> NWTXTRecord {
            guard case let .bonjour(record) = result.metadata else { return NWTXTRecord() }
            return record
        }

        private func connect(userInitiated: Bool) {
            guard enableTask == nil else {
                pendingReconnect = true
                if userInitiated {
                    pendingUserInitiated = true
                }
                return
            }
            pendingReconnect = false
            pendingUserInitiated = false
            generation &+= 1
            let generation = self.generation
            connection?.cancel()
            server = nil
            serverName = nil
            if userInitiated {
                errorMessage = nil
            }
            guard !candidates.isEmpty else {
                requiresToken = false
                status = .notFound
                return
            }
            let snapshot = candidates
            let currentToken = token
            status = .connecting
            connection = Task {
                var lastFailure: String?

                for candidate in snapshot {
                    if Task.isCancelled || self.generation != generation {
                        return
                    }
                    let candidateRequiresToken = Self.txtRecord(candidate)["auth"] == "1"

                    do {
                        let resolved = try await Self.resolve(candidate.endpoint)
                        if Task.isCancelled || self.generation != generation {
                            return
                        }
                        guard try Self.localIPv4Addresses().contains(resolved.host) else { continue }
                        let url = URL(string: "http://127.0.0.1:\(resolved.port)")!
                        try await SwiptClient(server: url, token: candidateRequiresToken ? currentToken : nil).checkConnection()
                        if Task.isCancelled || self.generation != generation {
                            return
                        }
                        server = url
                        serverName = Self.name(candidate)
                        requiresToken = candidateRequiresToken
                        status = .connected
                        scheduleEnable()
                        return
                    } catch is CancellationError {
                        return
                    } catch let error as SwiptClient.StatusError where error.code == SwiptClient.StatusError.unauthenticated {
                        guard !Task.isCancelled, self.generation == generation else { return }
                        requiresToken = true
                        status = .unauthenticated
                        if userInitiated, !currentToken.isEmpty {
                            let detail = error.localizedDescription
                            errorMessage = detail.isEmpty ? String(localized: "Incorrect Token") : detail
                        }
                        return
                    } catch {
                        lastFailure = Self.describe(error)
                    }
                }

                guard self.generation == generation else { return }
                if let lastFailure {
                    requiresToken = false
                    status = .unreachable
                    if userInitiated {
                        errorMessage = lastFailure
                    }
                } else {
                    requiresToken = false
                    status = .notFound
                }
            }
        }

        private func scheduleEnable() {
            guard isEnabled, !isPrepared, status == .connected, enableTask == nil else { return }
            let client = SwiptClient(server: server!, token: requiresToken ? token : nil)
            errorMessage = nil
            status = .enabling
            enableTask = Task {
                var failure: (any Error)?
                do {
                    await Self.waitForFrames(Self.framesBeforeHandshake)
                    if isEnabled {
                        try await client.enableJIT(bundleID: Bundle.main.bundleIdentifier!, pid: UInt64(getpid()))
                        try await Self.prepareMemory()
                    }
                } catch {
                    failure = error
                }
                isPrepared = LinuxRuntime.isJITPrepared
                enableTask = nil
                if let failure {
                    errorMessage = Self.describe(failure)
                }
                if pendingReconnect {
                    let userInitiated = pendingUserInitiated
                    connect(userInitiated: userInitiated)
                } else if status == .enabling, candidates.contains(where: {
                    Self.name($0) == serverName && (Self.txtRecord($0)["auth"] == "1") == requiresToken
                }) {
                    status = .connected
                } else if status == .enabling || !candidates.isEmpty {
                    connect(userInitiated: false)
                }
            }
        }

        private static func waitForFrames(_ count: Int) async {
            await withCheckedContinuation { continuation in
                let counter = FrameCounter(remaining: count, continuation: continuation)
                let link = CADisplayLink(target: counter, selector: #selector(FrameCounter.step))
                link.add(to: .main, forMode: .common)
                Task {
                    try? await Task.sleep(for: framesTimeout)
                    counter.finish(link)
                }
            }
        }

        private static func describe(_ error: any Error) -> String {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                return message
            }
            let bridged = error as NSError
            return "\(bridged.domain) (\(bridged.code))"
        }

        private nonisolated static let prepareQueue = DispatchQueue(label: "io.nekohasekai.swipterm.jit-prepare")

        private static func prepareMemory() async throws {
            try await withCheckedThrowingContinuation { continuation in
                prepareQueue.async {
                    continuation.resume(with: Result { try LinuxRuntime.prepareJIT() })
                }
            }
        }

        private static func localIPv4Addresses() throws -> Set<String> {
            var addresses: Set = ["127.0.0.1"]
            var first: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&first) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno)!)
            }
            let head = first!
            defer { freeifaddrs(head) }
            var pointer: UnsafeMutablePointer<ifaddrs>? = head
            while let current = pointer {
                if let sa = current.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    addresses.insert(String(cString: inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))!))
                }
                pointer = current.pointee.ifa_next
            }
            return addresses
        }

        private static func resolve(_ endpoint: NWEndpoint) async throws -> (host: String, port: UInt16) {
            let parameters = NWParameters.tcp
            (parameters.defaultProtocolStack.internetProtocol as! NWProtocolIP.Options).version = .v4
            let connection = NWConnection(to: endpoint, using: parameters)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        connection.cancel()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    connection.stateUpdateHandler = { state in
                        let result: Result<(host: String, port: UInt16), any Error>
                        switch state {
                        case .ready:
                            guard case let .hostPort(.ipv4(address), port) = connection.currentPath?.remoteEndpoint else {
                                result = .failure(URLError(.cannotFindHost))
                                break
                            }
                            let host = address.rawValue.map(String.init).joined(separator: ".")
                            result = .success((host, port.rawValue))
                        case let .failed(error), let .waiting(error):
                            result = .failure(error)
                        case .cancelled:
                            result = .failure(CancellationError())
                        default:
                            return
                        }
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(with: result)
                    }
                    connection.start(queue: .main)
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    private final class FrameCounter: NSObject {
        private var remaining: Int
        private var continuation: CheckedContinuation<Void, Never>?

        init(remaining: Int, continuation: CheckedContinuation<Void, Never>) {
            self.remaining = remaining
            self.continuation = continuation
        }

        @objc func step(_ link: CADisplayLink) {
            remaining -= 1
            if remaining == 0 {
                finish(link)
            }
        }

        func finish(_ link: CADisplayLink) {
            link.invalidate()
            continuation?.resume()
            continuation = nil
        }
    }
#endif

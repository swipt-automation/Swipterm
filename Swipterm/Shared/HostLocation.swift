import CoreLocation
import Foundation
import Observation
import UIKit

@Observable
final class HostLocation: NSObject {
    nonisolated enum Accuracy: String, CaseIterable, Comparable, Sendable {
        case reduced
        case threeKilometers = "3km"
        case kilometer = "1km"
        case hundredMeters = "100m"
        case tenMeters = "10m"
        case best
        case navigation = "nav"

        init?(argument: String) {
            if argument == "navigation" {
                self = .navigation
                return
            }
            self.init(rawValue: argument)
        }

        private var rank: Int {
            switch self {
            case .reduced: 0
            case .threeKilometers: 1
            case .kilometer: 2
            case .hundredMeters: 3
            case .tenMeters: 4
            case .best: 5
            case .navigation: 6
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rank < rhs.rank
        }

        var coreLocationValue: CLLocationAccuracy {
            switch self {
            case .reduced: kCLLocationAccuracyReduced
            case .threeKilometers: kCLLocationAccuracyThreeKilometers
            case .kilometer: kCLLocationAccuracyKilometer
            case .hundredMeters: kCLLocationAccuracyHundredMeters
            case .tenMeters: kCLLocationAccuracyNearestTenMeters
            case .best: kCLLocationAccuracyBest
            case .navigation: kCLLocationAccuracyBestForNavigation
            }
        }

        var requiresFullAccuracy: Bool {
            self >= .tenMeters
        }

        var targetHorizontalAccuracy: CLLocationAccuracy? {
            switch self {
            case .reduced, .threeKilometers: nil
            case .kilometer: 1500
            case .hundredMeters: 250
            case .tenMeters, .best, .navigation: 100
            }
        }
    }

    nonisolated enum Failure: LocalizedError, Sendable {
        case authorizationDenied
        case foregroundRequired
        case alwaysAuthorizationRequired
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                "location access is denied"
            case .foregroundRequired:
                "location authorization must be granted while Swipterm is in the foreground"
            case .alwaysAuthorizationRequired:
                "starting location updates in the background requires Always authorization"
            case .timedOut:
                "timed out waiting for location"
            case let .failed(message):
                message
            }
        }
    }

    private struct Lease {
        let accuracy: Accuracy?
        let startedAt: Date
        let handler: (Result<(CLLocation, CLAccuracyAuthorization), Failure>) -> Void
    }

    private final class SingleRequest {
        var leaseID: UUID?
        var fallbackTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var bestCandidate: (CLLocation, CLAccuracyAuthorization)?
        var continuation: CheckedContinuation<(CLLocation, CLAccuracyAuthorization), any Error>?
    }

    static let shared = HostLocation()
    private static let precisePurposeKey = "PreciseLocation"
    private static let recentFixAge: TimeInterval = 10
    private static let refinementTimeout = Duration.seconds(5)
    private static let requestTimeout = Duration.seconds(15)

    private(set) var authorization: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var isKeepingBackgroundAlive = false {
        didSet {
            guard isKeepingBackgroundAlive != oldValue else { return }
            onBackgroundKeepAliveChange?()
        }
    }

    var isPresentingDeniedAlert = false
    @ObservationIgnored var isSettingsVisible = false
    @ObservationIgnored var onBackgroundKeepAliveChange: (() -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private var isContainerActive = false
    @ObservationIgnored private var requestedAlwaysUpgrade = false
    @ObservationIgnored private var pendingUICaffeinateAuthorization = false
    @ObservationIgnored private var authorizationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var leases: [UUID: Lease] = [:]
    @ObservationIgnored private var singleRequests: [UUID: SingleRequest] = [:]

    override private init() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.delegate = self
    }

    func updateContainerActive(_ isActive: Bool) {
        guard isContainerActive != isActive else { return }
        isContainerActive = isActive
        reconcile()
    }

    func setCaffeinateEnabled(_ isEnabled: Bool) {
        let settings = AppSettings.shared
        guard isEnabled else {
            pendingUICaffeinateAuthorization = false
            settings.isCaffeinateEnabled = false
            reconcile()
            return
        }
        if authorization == .denied || authorization == .restricted {
            settings.isCaffeinateEnabled = false
            isPresentingDeniedAlert = true
            reconcile()
            return
        }
        pendingUICaffeinateAuthorization = authorization == .notDetermined
        settings.isCaffeinateEnabled = true
        reconcile()
    }

    func enableCaffeinateFromCommand() async throws {
        let settings = AppSettings.shared
        settings.isCaffeinateAvailable = true
        if authorization == .notDetermined {
            guard UIApplication.shared.applicationState != .background else {
                throw Failure.foregroundRequired
            }
            await waitForAuthorization()
            try Task.checkCancellation()
        }
        switch authorization {
        case .authorizedAlways:
            break
        case .authorizedWhenInUse:
            if UIApplication.shared.applicationState == .background, !isKeepingBackgroundAlive {
                settings.isCaffeinateEnabled = false
                reconcile()
                throw Failure.alwaysAuthorizationRequired
            }
        default:
            settings.isCaffeinateEnabled = false
            reconcile()
            throw Failure.authorizationDenied
        }
        settings.isCaffeinateEnabled = true
        reconcile()
    }

    func disableCaffeinateFromCommand() {
        pendingUICaffeinateAuthorization = false
        AppSettings.shared.isCaffeinateEnabled = false
        reconcile()
    }

    func prepareAccess(accuracy: Accuracy?) async throws {
        if authorization == .notDetermined {
            guard UIApplication.shared.applicationState != .background else {
                throw Failure.foregroundRequired
            }
            await waitForAuthorization()
            try Task.checkCancellation()
        }
        switch authorization {
        case .authorizedAlways:
            break
        case .authorizedWhenInUse:
            if UIApplication.shared.applicationState == .background, !isKeepingBackgroundAlive {
                throw Failure.alwaysAuthorizationRequired
            }
            if UIApplication.shared.applicationState != .background {
                requestAlwaysIfNeeded()
            }
        default:
            throw Failure.authorizationDenied
        }
        if let accuracy,
           accuracy.requiresFullAccuracy,
           accuracyAuthorization == .reducedAccuracy,
           UIApplication.shared.applicationState != .background
        {
            try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.precisePurposeKey)
            accuracyAuthorization = manager.accuracyAuthorization
        }
    }

    func addLease(
        accuracy: Accuracy?,
        handler: @escaping (Result<(CLLocation, CLAccuracyAuthorization), Failure>) -> Void
    ) -> UUID {
        let id = UUID()
        let startedAt = Date()
        leases[id] = Lease(
            accuracy: accuracy,
            startedAt: startedAt,
            handler: handler
        )
        reconcile()
        if let cached = manager.location,
           cached.horizontalAccuracy >= 0,
           abs(cached.timestamp.timeIntervalSince(startedAt)) <= Self.recentFixAge
        {
            handler(.success((cached, accuracyAuthorization)))
        }
        return id
    }

    func removeLease(_ id: UUID) {
        guard leases.removeValue(forKey: id) != nil else { return }
        reconcile()
    }

    func nextLocation(accuracy: Accuracy?) async throws -> (CLLocation, CLAccuracyAuthorization) {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = SingleRequest()
                request.continuation = continuation
                request.timeoutTask = Task {
                    try? await Task.sleep(for: Self.requestTimeout)
                    guard !Task.isCancelled else { return }
                    if let candidate = singleRequests[requestID]!.bestCandidate {
                        completeSingleRequest(requestID, with: .success(candidate))
                    } else {
                        completeSingleRequest(requestID, with: .failure(Failure.timedOut))
                    }
                }
                singleRequests[requestID] = request
                let leaseID = addLease(accuracy: accuracy) { result in
                    switch result {
                    case let .success((location, accuracyAuth)):
                        if self.satisfiesTargetAccuracy(location, requested: accuracy) {
                            self.completeSingleRequest(requestID, with: .success((location, accuracyAuth)))
                            return
                        }
                        let active = self.singleRequests[requestID]!
                        if let current = active.bestCandidate {
                            if location.horizontalAccuracy < current.0.horizontalAccuracy {
                                active.bestCandidate = (location, accuracyAuth)
                            }
                        } else {
                            active.bestCandidate = (location, accuracyAuth)
                            active.fallbackTask = Task {
                                try? await Task.sleep(for: Self.refinementTimeout)
                                guard !Task.isCancelled else { return }
                                self.completeSingleRequest(requestID, with: .success(self.singleRequests[requestID]!.bestCandidate!))
                            }
                        }
                    case let .failure(error):
                        self.completeSingleRequest(requestID, with: .failure(error))
                    }
                }
                if let active = singleRequests[requestID] {
                    active.leaseID = leaseID
                } else {
                    removeLease(leaseID)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.completeSingleRequest(requestID, with: .failure(CancellationError()))
            }
        }
    }

    private func completeSingleRequest(
        _ id: UUID,
        with result: Result<(CLLocation, CLAccuracyAuthorization), any Error>
    ) {
        guard let request = singleRequests.removeValue(forKey: id) else { return }
        request.fallbackTask?.cancel()
        request.timeoutTask?.cancel()
        if let leaseID = request.leaseID {
            removeLease(leaseID)
        }
        request.continuation!.resume(with: result)
    }

    func satisfiesTargetAccuracy(_ location: CLLocation, requested: Accuracy?) -> Bool {
        guard accuracyAuthorization == .fullAccuracy else {
            return true
        }
        let effective = requested ?? .best
        guard let target = effective.targetHorizontalAccuracy else {
            return true
        }
        return location.horizontalAccuracy <= target
    }

    func reconcile() {
        let settings = AppSettings.shared
        let inBackground = UIApplication.shared.applicationState == .background
        if settings.isCaffeinateEnabled {
            switch authorization {
            case .notDetermined where !inBackground:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse where !inBackground:
                requestAlwaysIfNeeded()
            case .denied, .restricted:
                settings.isCaffeinateEnabled = false
                if pendingUICaffeinateAuthorization {
                    pendingUICaffeinateAuthorization = false
                    if isSettingsVisible {
                        isPresentingDeniedAlert = true
                    }
                }
            default:
                break
            }
        }

        let caffeinateWantsUpdate = settings.isCaffeinateEnabled && isContainerActive
        let wantsUpdate = caffeinateWantsUpdate || !leases.isEmpty
        let hasAuthorization = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        let canStart = hasAuthorization && (authorization == .authorizedAlways || isKeepingBackgroundAlive || !inBackground)

        guard wantsUpdate, canStart else {
            if isUpdating {
                manager.stopUpdatingLocation()
                isUpdating = false
            }
            if manager.allowsBackgroundLocationUpdates {
                manager.allowsBackgroundLocationUpdates = false
            }
            isKeepingBackgroundAlive = false
            return
        }

        var accuracies: [Accuracy] = leases.values.map { lease in
            lease.accuracy ?? (accuracyAuthorization == .fullAccuracy ? .best : .reduced)
        }
        if caffeinateWantsUpdate {
            accuracies.append(.threeKilometers)
        }
        let accuracyValue = accuracies.max()!.coreLocationValue
        let distanceFilter: CLLocationDistance = leases.isEmpty ? CLLocationDistanceMax : kCLDistanceFilterNone

        if manager.desiredAccuracy != accuracyValue {
            manager.desiredAccuracy = accuracyValue
        }
        if manager.distanceFilter != distanceFilter {
            manager.distanceFilter = distanceFilter
        }
        if !manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = true
        }
        if !isUpdating {
            manager.startUpdatingLocation()
            isUpdating = true
        }
        isKeepingBackgroundAlive = isUpdating
    }

    private func requestAlwaysIfNeeded() {
        guard !requestedAlwaysUpgrade else { return }
        requestedAlwaysUpgrade = true
        manager.requestAlwaysAuthorization()
    }

    private func waitForAuthorization() async {
        manager.requestWhenInUseAuthorization()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                authorizationWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.authorizationWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func handleAuthorizationUpdate() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if authorization != .notDetermined {
            let waiters = authorizationWaiters
            authorizationWaiters.removeAll()
            for waiter in waiters.values {
                waiter.resume()
            }
        }
        if authorization == .denied || authorization == .restricted {
            let activeLeases = Array(leases.values)
            leases.removeAll()
            for lease in activeLeases {
                lease.handler(.failure(.authorizationDenied))
            }
        } else {
            pendingUICaffeinateAuthorization = false
        }
        reconcile()
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard !leases.isEmpty else { return }
        let currentAccuracyAuth = manager.accuracyAuthorization
        accuracyAuthorization = currentAccuracyAuth
        for location in locations where location.horizontalAccuracy >= 0 {
            let snapshot = leases
            for (_, lease) in snapshot where location.timestamp.timeIntervalSince(lease.startedAt) >= -Self.recentFixAge {
                lease.handler(.success((location, currentAccuracyAuth)))
            }
        }
    }

    private func handleError(_ error: any Error) {
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                return
            case .denied:
                let activeLeases = Array(leases.values)
                leases.removeAll()
                for lease in activeLeases {
                    lease.handler(.failure(.authorizationDenied))
                }
                reconcile()
                return
            default:
                break
            }
        }
        let activeLeases = Array(leases.values)
        leases.removeAll()
        for lease in activeLeases {
            lease.handler(.failure(.failed(error.localizedDescription)))
        }
        reconcile()
    }
}

extension HostLocation: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        MainActor.assumeIsolated {
            handleAuthorizationUpdate()
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            handleLocations(locations)
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            handleError(error)
        }
    }
}

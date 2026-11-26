import UIKit

final class TransferProgressAlert {
    private let progress: Progress
    private let alert: ProgressAlert
    private var observation: NSKeyValueObservation?
    private var presentation: Task<Void, Never>?

    init(progress: Progress) {
        self.progress = progress
        alert = ProgressAlert(title: String(localized: "Receiving…")) {
            progress.cancel()
        }
        observation = progress.observe(\.fractionCompleted, options: .initial) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self?.alert.update(fraction)
            }
        }
    }

    func present(from view: UIView) {
        presentation = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard var presenter = view.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            await withCheckedContinuation { continuation in
                presenter.present(alert.controller, animated: true) {
                    continuation.resume()
                }
            }
        }
    }

    func dismiss() async {
        presentation?.cancel()
        await presentation?.value
        observation?.invalidate()
        guard !progress.isCancelled, alert.controller.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            alert.controller.dismiss(animated: true) {
                continuation.resume()
            }
        }
    }
}

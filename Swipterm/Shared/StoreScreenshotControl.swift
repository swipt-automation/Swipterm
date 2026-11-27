#if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
    import notify
    import SwiftUI
    import UIKit

    struct StoreScreenshotControl: UIViewRepresentable {
        let name: String
        let index: Int
        let direction: LayoutDirection
        let onRequest: @MainActor @Sendable (Int) -> Void

        func makeUIView(context _: Context) -> ControlView {
            ControlView(name: name, onRequest: onRequest)
        }

        func updateUIView(_ view: ControlView, context _: Context) {
            view.update(index: index, direction: direction)
        }

        final class ControlView: UIView {
            private let name: String
            private let token: Int32
            private var index: Int?
            private var direction = LayoutDirection.leftToRight
            private var scheduledIndex: Int?

            init(name: String, onRequest: @escaping @MainActor (Int) -> Void) {
                self.name = name
                var token: Int32 = 0
                let status = notify_register_dispatch(name, &token, .main) { token in
                    var state: UInt64 = 0
                    let status = notify_get_state(token, &state)
                    precondition(status == NOTIFY_STATUS_OK, "Could not read \(name): \(status)")
                    MainActor.assumeIsolated { onRequest(Int(state)) }
                }
                precondition(status == NOTIFY_STATUS_OK, "Could not subscribe to \(name): \(status)")
                self.token = token
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError()
            }

            deinit {
                notify_cancel(token)
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                scheduledIndex = nil
                scheduleAcknowledgment()
            }

            func update(index: Int, direction: LayoutDirection) {
                self.index = index
                self.direction = direction
                scheduleAcknowledgment()
            }

            private func scheduleAcknowledgment() {
                guard let window, let index, scheduledIndex != index else { return }
                scheduledIndex = index
                window.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window === window, self.index == index else { return }
                    window.layoutIfNeeded()
                    CATransaction.flush()
                    let status = notify_post("\(name).ready.\(index)")
                    precondition(status == NOTIFY_STATUS_OK, "Could not acknowledge screenshot request \(index): \(status)")
                }
            }
        }
    }
#endif

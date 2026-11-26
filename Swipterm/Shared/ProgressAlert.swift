import UIKit

final class ProgressAlert {
    let controller: UIAlertController

    private let progressView = UIProgressView(progressViewStyle: .default)
    private let embedsProgressBar: Bool

    init(title: String, onCancel: @escaping () -> Void) {
        controller = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
            onCancel()
        }
        controller.addAction(cancelAction)
        controller.preferredAction = cancelAction
        controller.view.tintColor = .systemBlue
        // UIAlertController embeds a custom view controller below its message through the private `contentViewController` key.
        embedsProgressBar = controller.responds(to: Selector(("setContentViewController:")))
        if embedsProgressBar {
            let content = UIViewController()
            progressView.translatesAutoresizingMaskIntoConstraints = false
            progressView.progressTintColor = .systemBlue
            progressView.layer.cornerRadius = 10
            progressView.clipsToBounds = true
            content.view.addSubview(progressView)
            NSLayoutConstraint.activate([
                progressView.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 20),
                progressView.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -20),
                progressView.topAnchor.constraint(equalTo: content.view.topAnchor, constant: 2),
                progressView.heightAnchor.constraint(equalToConstant: 20),
            ])
            content.preferredContentSize.height = 30
            controller.setValue(content, forKey: "contentViewController")
        }
    }

    func update(_ fraction: Double) {
        if embedsProgressBar {
            progressView.setProgress(Float(fraction), animated: controller.viewIfLoaded?.window != nil)
        } else {
            controller.message = fraction.formatted(.percent.precision(.fractionLength(0)))
        }
    }
}

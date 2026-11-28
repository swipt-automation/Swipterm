import SwiftUI

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    let textStyle: UIFont.TextStyle

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        let baseSize = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        view.font = UIFontMetrics(forTextStyle: textStyle)
            .scaledFont(for: .monospacedSystemFont(ofSize: baseSize, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text {
            view.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }
    }
}

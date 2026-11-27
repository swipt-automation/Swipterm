import SwiftUI
import UIKit

struct FindDock: View {
    let search: TerminalSearch
    let isFloating: Bool

    private static let controlSize: CGFloat = 44
    private static let floatingWidthShare: CGFloat = 0.6
    private static let floatingWidthRange: ClosedRange<CGFloat> = 560 ... 840

    var body: some View {
        ZStack {
            if search.isPresented {
                placed
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            }
        }
        .animation(isFloating ? .snappy : nil, value: search.isPresented)
    }

    @ViewBuilder
    private var placed: some View {
        if isFloating {
            GeometryReader { proxy in
                controls
                    .frame(maxWidth: Self.floatingWidth(in: proxy.size.width))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        } else {
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private static func floatingWidth(in columnWidth: CGFloat) -> CGFloat {
        let share = columnWidth * floatingWidthShare
        return min(max(share, floatingWidthRange.lowerBound), floatingWidthRange.upperBound)
    }

    private var controls: some View {
        FindGlassContainer {
            HStack(spacing: 8) {
                Button(action: search.dismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                        .findGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Close")
                HStack(spacing: 0) {
                    FindHistoryMenu(search: search)
                        .frame(height: Self.controlSize)
                    FindField(search: search)
                        .frame(height: Self.controlSize)
                    FindStatus(search: search)
                }
                .padding(.trailing, 8)
                .findGlass(in: Capsule(), interactive: false)
                HStack(spacing: 0) {
                    FindStepper(search: search, controlSize: Self.controlSize - 4)
                }
                .frame(height: Self.controlSize)
                .padding(.horizontal, 4)
                .findGlass(in: Capsule(), interactive: false)
            }
        }
    }
}

private struct FindGlassContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8, content: content)
        } else {
            content()
        }
    }
}

private extension View {
    @ViewBuilder
    func findGlass(in shape: some Shape, interactive: Bool) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

private struct FindHistoryMenu: View {
    let search: TerminalSearch
    private let history = FindHistory.shared

    var body: some View {
        Menu {
            if history.queries.isEmpty {
                Button("No Recent Searches") {}
                    .disabled(true)
            } else {
                Section("Recent Searches") {
                    ForEach(history.queries, id: \.self) { query in
                        Button {
                            search.search(for: query)
                        } label: {
                            Text(verbatim: query)
                        }
                    }
                }
                Button(role: .destructive, action: history.removeAll) {
                    Label("Clear Recent Searches", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Recent Searches")
    }
}

private struct FindStatus: View {
    let search: TerminalSearch

    var body: some View {
        if let text {
            text
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
        }
    }

    private var text: Text? {
        if search.showsNoResults {
            return Text("No Results")
        }
        guard let total = search.total, total > 0 else { return nil }
        guard let selected = search.selected else { return Text(total, format: .number) }
        return Text(
            "\(selected + 1, format: .number)/\(total, format: .number)",
            comment: "Find bar match position: the first value is the selected match, the second is the number of matches"
        )
    }
}

private struct FindStepper: View {
    let search: TerminalSearch
    let controlSize: CGFloat

    var body: some View {
        Group {
            FindBarButton(symbol: "chevron.up", label: "Find Next", size: controlSize) {
                search.navigate(.older)
            }
            FindBarButton(symbol: "chevron.down", label: "Find Previous", size: controlSize) {
                search.navigate(.newer)
            }
        }
        .disabled(search.query.isEmpty)
    }
}

private struct FindBarButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

private struct FindField: UIViewRepresentable {
    let search: TerminalSearch

    func makeUIView(context: Context) -> Field {
        let field = Field(frame: .zero)
        field.borderStyle = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.clearButtonMode = .whileEditing
        field.focusEffect = nil
        field.placeholder = String(localized: "Find (field)")
        field.accessibilityLabel = String(localized: "Find (field)")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.owner = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.search = search
        _ = search.focusRequest
        if field.markedTextRange == nil, field.text != search.query {
            field.text = search.query
        }
        if search.takeFieldFocusRequest() {
            field.takeFocus()
        }
    }

    static func dismantleUIView(_: Field, coordinator: Coordinator) {
        coordinator.search.isEditing = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(search: search)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var search: TerminalSearch

        init(search: TerminalSearch) {
            self.search = search
        }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            search.edit(field.text ?? "")
        }

        func textFieldDidBeginEditing(_: UITextField) {
            search.isEditing = true
        }

        func textFieldDidEndEditing(_: UITextField) {
            search.isEditing = false
        }

        func textFieldShouldReturn(_: UITextField) -> Bool {
            search.navigate(.older)
            return false
        }
    }

    final class Field: UITextField {
        weak var owner: Coordinator?
        private var wantsFocus = false

        func takeFocus() {
            guard window != nil else {
                wantsFocus = true
                return
            }
            wantsFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, becomeFirstResponder() else { return }
                selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, wantsFocus {
                takeFocus()
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            guard markedTextRange == nil else { return [] }
            return [
                command("\r", .shift, #selector(findNewer(_:))),
                command(UIKeyCommand.inputEscape, [], #selector(cancel(_:))),
            ]
        }

        private func command(_ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        @objc private func findNewer(_: Any?) {
            owner?.search.navigate(.newer)
        }

        @objc private func cancel(_: Any?) {
            owner?.search.dismiss()
        }
    }
}

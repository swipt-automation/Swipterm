import GameController
import GhosttyTerminal
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TerminalSurfaceView: View {
    let surfaceView: SurfaceView
    let state: TerminalViewState
    let isActive: Bool
    let isVisible: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Representable(
            surfaceView: surfaceView,
            isActive: isActive,
            isVisible: isVisible
        )
        .onChange(of: colorScheme, initial: true) {
            state.adopt(colorScheme: colorScheme)
        }
    }

    private struct Representable: UIViewRepresentable {
        let surfaceView: SurfaceView
        let isActive: Bool
        let isVisible: Bool

        func makeUIView(context _: Context) -> HostContainerView {
            let host = HostContainerView()
            host.attach(surfaceView)
            return host
        }

        func updateUIView(_ host: HostContainerView, context _: Context) {
            host.attach(surfaceView)
            surfaceView.setSurfaceVisible(isVisible)
            surfaceView.syncFocus(isActive: isActive && isVisible)
        }

        static func dismantleUIView(_ host: HostContainerView, coordinator _: ()) {
            host.detachIfOwned()
        }
    }

    final class HostContainerView: UIView {
        private weak var attachedSurface: SurfaceView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        func attach(_ surface: SurfaceView) {
            guard surface.superview !== self else {
                attachedSurface = surface
                return
            }
            surface.removeFromSuperview()
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor),
                surface.topAnchor.constraint(equalTo: topAnchor),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            attachedSurface = surface
        }

        func detachIfOwned() {
            guard let surface = attachedSurface else { return }
            if surface.superview === self {
                surface.setSurfaceVisible(false)
                surface.removeFromSuperview()
            }
            attachedSurface = nil
        }
    }

    final class SurfaceView: UITerminalView {
        struct OutputActivitySnapshot: Sendable {
            let wasQuietBeforeInput: Bool
            let outputCountBeforeInput: UInt64
            let currentOutputCount: UInt64
        }

        private static let accessoryPasteActionID = UIAction.Identifier("swipterm.accessory.paste")
        private static let accessoryPreKeyActionID = UIAction.Identifier("swipterm.accessory.preKey")
        private static let accessoryPostKeyActionID = UIAction.Identifier("swipterm.accessory.postKey")
        private static let touchPasteActionID = UIAction.Identifier("terminal.paste")
        private static let documentAnchorLength = 1
        private static let modifierKeyCodes: Set<UIKeyboardHIDUsage> = [
            .keyboardLeftControl, .keyboardRightControl,
            .keyboardLeftShift, .keyboardRightShift,
            .keyboardLeftAlt, .keyboardRightAlt,
            .keyboardLeftGUI, .keyboardRightGUI,
            .keyboardCapsLock,
        ]
        private static let modifierAccessoryLabels: Set<String> = Set([
            TerminalInputAccessoryItem.ctrl.title,
            TerminalInputAccessoryItem.alt.title,
            TerminalInputAccessoryItem.command.title,
        ].compactMap(\.self))

        var inMemorySession: InMemoryTerminalSession?
        var readOutputActivity: (() -> OutputActivitySnapshot)?
        var onPasteFailure: ((any Error) -> Void)?

        private var interceptedPresses: Set<UIPress> = []
        private var wantsFocus = false
        private var needsFocusSync = false
        private var lastDirectTapPoint: CGPoint?
        private var pendingKeyboardToggleTask: Task<Void, Never>?
        private lazy var dropHandler = SurfaceDropDelegate(surfaceView: self)

        private weak var systemInputDelegate: (any UITextInputDelegate)?
        private let superInputDelegate = SuperInputDelegate()
        private var isRoutingToSuperInput = false
        private var document = "\n"
        private var markedRange: NSRange?
        private var selection = NSRange(location: 1, length: 0)
        private var typedText = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            _ = SoftwareKeyboardTracker.shared
            for interaction in interactions where interaction is UIDropInteraction {
                removeInteraction(interaction)
            }
            addInteraction(UIDropInteraction(delegate: dropHandler))
            NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidChange), name: .GCKeyboardDidConnect, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidChange), name: .GCKeyboardDidDisconnect, object: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        func syncFocus(isActive: Bool) {
            let changed = wantsFocus != isActive
            wantsFocus = isActive
            if !isActive {
                pendingKeyboardToggleTask?.cancel()
                pendingKeyboardToggleTask = nil
            }
            guard changed else { return }
            needsFocusSync = true
            guard window != nil else { return }
            applyPendingFocusSync()
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil, wantsFocus, isFirstResponder {
                needsFocusSync = true
            }
            super.willMove(toWindow: newWindow)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, needsFocusSync {
                applyPendingFocusSync()
            }
        }

        private func applyPendingFocusSync() {
            // A keyboard hide posted while SwiftUI is updating the hosting view leaves that view laid out
            // with the old keyboard height as a fixed bottom edge, which ignoresSafeArea cannot extend past.
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, needsFocusSync else { return }
                needsFocusSync = false
                guard wantsFocus != isFirstResponder else { return }
                _ = wantsFocus ? becomeFirstResponder() : resignFirstResponder()
            }
        }

        override var canBecomeFirstResponder: Bool {
            wantsFocus && super.canBecomeFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                dropTypedText()
            }
            return resigned
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            pendingKeyboardToggleTask?.cancel()
            pendingKeyboardToggleTask = nil
            if touches.contains(where: { $0.type == .indirectPointer }) {
                forgetTypedText()
            }
            if (event?.touches(for: self) ?? touches).count == 1,
               let touch = touches.first,
               touch.type == .direct
            {
                lastDirectTapPoint = touch.location(in: self)
            } else {
                lastDirectTapPoint = nil
            }
            super.touchesBegan(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if (event?.touches(for: self) ?? touches).count == 1,
               let touch = touches.first,
               touch.type == .direct
            {
                lastDirectTapPoint = touch.location(in: self)
            }
            super.touchesEnded(touches, with: event)
        }

        override func toggleSoftwareKeyboard() {
            guard wantsFocus else { return }
            forgetTypedText()
            guard isMouseCaptured else {
                super.toggleSoftwareKeyboard()
                return
            }
            guard let tapPoint = lastDirectTapPoint else { return }
            lastDirectTapPoint = nil
            let isKeyboardVisible = isFirstResponder && SoftwareKeyboardTracker.shared.isOnScreen
            let caretBefore = caretRect(for: beginningOfDocument)
            if isPointNearCaretRow(tapPoint, caret: caretBefore, rowPadding: 1) {
                if !isKeyboardVisible, !isFirstResponder {
                    _ = becomeFirstResponder()
                }
                return
            }
            let initialActivity = readOutputActivity?()
            let wasQuiet = initialActivity?.wasQuietBeforeInput == true
            let blankSliceBefore = wasQuiet ? nil : blankViewportContext(at: tapPoint)
            guard wasQuiet || blankSliceBefore != nil || !isKeyboardVisible else { return }
            pendingKeyboardToggleTask?.cancel()
            pendingKeyboardToggleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled,
                      let self,
                      wantsFocus,
                      window != nil,
                      isMouseCaptured
                else { return }
                let reactedEarly = wasQuiet
                    && initialActivity != nil
                    && readOutputActivity?().currentOutputCount != initialActivity?.outputCountBeforeInput
                if !reactedEarly {
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled,
                          wantsFocus,
                          window != nil,
                          isMouseCaptured
                    else { return }
                    if wasQuiet,
                       let initialActivity,
                       readOutputActivity?().currentOutputCount == initialActivity.outputCountBeforeInput
                    {
                        toggleSoftwareKeyboardState()
                        return
                    }
                    if let blankSliceBefore,
                       blankViewportContext(at: tapPoint) == blankSliceBefore
                    {
                        toggleSoftwareKeyboardState()
                        return
                    }
                }
                guard !(isFirstResponder && SoftwareKeyboardTracker.shared.isOnScreen) else { return }
                let caretAfter = caretRect(for: beginningOfDocument)
                let caretMoved = abs(caretAfter.minX - caretBefore.minX) > 1
                    || abs(caretAfter.minY - caretBefore.minY) > 1
                if caretMoved, isPointNearCaretRow(tapPoint, caret: caretAfter, rowPadding: 0.5) {
                    if !isFirstResponder {
                        _ = becomeFirstResponder()
                    }
                }
            }
        }

        private func toggleSoftwareKeyboardState() {
            if isFirstResponder, SoftwareKeyboardTracker.shared.isOnScreen {
                _ = resignFirstResponder()
            } else if !isFirstResponder {
                _ = becomeFirstResponder()
            } else {
                super.toggleSoftwareKeyboard()
            }
        }

        private func isPointNearCaretRow(_ point: CGPoint, caret: CGRect, rowPadding: CGFloat) -> Bool {
            guard caret.height > 0 else { return false }
            let margin = caret.height * rowPadding
            return point.y >= caret.minY - margin && point.y <= caret.maxY + margin
        }

        private func blankViewportContext(at point: CGPoint) -> [String]? {
            guard let cell = viewportCell(at: point),
                  let viewportText = inMemorySession?.readViewportText()
            else { return nil }
            let lines = viewportText.split(separator: "\n", omittingEmptySubsequences: false)
            guard cell.row >= 0, cell.row < lines.count else { return nil }
            let line = lines[cell.row]
            if !line.isEmpty {
                let minCol = max(0, cell.column - 1)
                let maxCol = cell.column + 1
                var col = 0
                for character in line {
                    let width = Self.terminalColumnWidth(of: character)
                    let nextCol = col + width
                    if nextCol > minCol, col <= maxCol, !character.isWhitespace {
                        return nil
                    }
                    col = nextCol
                    if col > maxCol {
                        break
                    }
                }
            }
            let lower = max(0, cell.row - 3)
            let upper = min(lines.count - 1, cell.row + 3)
            return lines[lower ... upper].map(String.init)
        }

        private static func terminalColumnWidth(of character: Character) -> Int {
            if character.unicodeScalars.contains(where: { $0.value == 0xFE0F || $0.properties.isEmojiPresentation }) {
                return 2
            }
            switch character.unicodeScalars.first!.value {
            case 0x1100 ... 0x115F,
                 0x2329 ... 0x232A,
                 0x2E80 ... 0x303E,
                 0x3040 ... 0x3247,
                 0x3250 ... 0x4DBF,
                 0x4E00 ... 0xA4C6,
                 0xA960 ... 0xA97C,
                 0xAC00 ... 0xD7A3,
                 0xF900 ... 0xFAFF,
                 0xFE10 ... 0xFE19,
                 0xFE30 ... 0xFE6B,
                 0xFF01 ... 0xFF60,
                 0xFFE0 ... 0xFFE6,
                 0x1F000 ... 0x1FAFF,
                 0x20000 ... 0x3FFFD:
                return 2
            default:
                return 1
            }
        }

        override var inputAccessoryItems: [TerminalInputAccessoryItem] {
            didSet {
                if let bar = super.inputAccessoryView {
                    rebindAccessoryButtons(in: bar)
                }
            }
        }

        override var inputAccessoryView: UIView? {
            if GCKeyboard.coalesced != nil {
                return nil
            }
            let bar = super.inputAccessoryView
            if let bar {
                rebindAccessoryButtons(in: bar)
            }
            return bar
        }

        @objc private func hardwareKeyboardDidChange() {
            reloadInputViews()
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) {
                return HostPasteStaging.hasPasteboardContent()
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_: Any?) {
            if markedTextRange != nil {
                unmarkText()
            }
            forgetTypedText()
            let pasteboard = UIPasteboard.general
            let fileURLs = HostPasteStaging.fileURLs(in: pasteboard)
            if !fileURLs.isEmpty {
                HostPasteStaging.shared.stageFileURLs(fileURLs) { [weak self] result in
                    guard let self else { return }
                    do {
                        guard let paths = try result.get() else { return }
                        _ = paste(text: paths)
                    } catch {
                        onPasteFailure?(error)
                    }
                }
                return
            }

            if pasteboard.hasStrings,
               let text = HostPasteStaging.plainText(
                   string: pasteboard.string,
                   urls: pasteboard.hasURLs ? (pasteboard.urls ?? []) : []
               )
            {
                _ = pasteWithProtection(text: text)
                return
            }

            let providerItems = pasteboard.itemProviders.compactMap { provider in
                HostPasteStaging.stageableType(among: provider.registeredTypeIdentifiers)
                    .map { HostPasteStaging.ProviderItem(provider: provider, type: $0) }
            }
            if !providerItems.isEmpty {
                HostPasteStaging.shared.stageProviders(providerItems) { [weak self] result in
                    guard let self else { return }
                    do {
                        guard let paths = try result.get() else { return }
                        _ = paste(text: paths)
                    } catch {
                        onPasteFailure?(error)
                    }
                }
                return
            }

            if pasteboard.hasURLs, let text = HostPasteStaging.plainText(string: nil, urls: pasteboard.urls ?? []) {
                _ = pasteWithProtection(text: text)
            }
        }

        override func touchMenuItems(for context: TerminalTouchMenuContext) -> [UIMenuElement] {
            rewireTouchPasteMenu(super.touchMenuItems(for: context))
        }

        override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
            rewireTouchPasteMenu(super.touchSelectionMenuItems(for: context))
        }

        private func rewireTouchPasteMenu(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.map { element in
                if let action = element as? UIAction, action.identifier == Self.touchPasteActionID {
                    return UIAction(
                        title: action.title,
                        image: action.image,
                        identifier: action.identifier,
                        attributes: action.attributes
                    ) { [weak self] _ in
                        self?.paste(nil)
                    }
                }
                if let menu = element as? UIMenu {
                    return menu.replacingChildren(rewireTouchPasteMenu(menu.children))
                }
                return element
            }
        }

        private func rebindAccessoryButtons(in root: UIView) {
            if let button = root as? UIButton {
                let label = button.accessibilityLabel
                if label == TerminalInputAccessoryItem.paste.title {
                    var hasCustomAction = false
                    var existingActions: [UIAction] = []
                    button.enumerateEventHandlers { action, _, event, _ in
                        guard let action, event.contains(.touchUpInside) else { return }
                        if action.identifier == Self.accessoryPasteActionID {
                            hasCustomAction = true
                        } else {
                            existingActions.append(action)
                        }
                    }
                    if !hasCustomAction {
                        for action in existingActions {
                            button.removeAction(action, for: .touchUpInside)
                        }
                        button.addAction(UIAction(identifier: Self.accessoryPasteActionID) { [weak self] _ in
                            guard let self else { return }
                            for modifier in [TerminalPublicStickyModifier.ctrl, .alt, .command]
                                where stickyActivation(for: modifier) == .armed
                            {
                                resetStickyModifiers()
                                break
                            }
                            paste(nil)
                        }, for: .touchUpInside)
                    }
                } else if let label, !Self.modifierAccessoryLabels.contains(label) {
                    var hasWrappedActions = false
                    var existingActions: [UIAction] = []
                    button.enumerateEventHandlers { action, _, event, _ in
                        guard let action, event.contains(.touchUpInside) else { return }
                        if action.identifier == Self.accessoryPreKeyActionID || action.identifier == Self.accessoryPostKeyActionID {
                            hasWrappedActions = true
                        } else {
                            existingActions.append(action)
                        }
                    }
                    if !hasWrappedActions, !existingActions.isEmpty {
                        for action in existingActions {
                            button.removeAction(action, for: .touchUpInside)
                        }
                        button.addAction(UIAction(identifier: Self.accessoryPreKeyActionID) { [weak self] _ in
                            guard let self else { return }
                            if markedRange != nil {
                                unmarkText()
                            }
                            isRoutingToSuperInput = true
                        }, for: .touchUpInside)
                        for action in existingActions {
                            button.addAction(action, for: .touchUpInside)
                        }
                        button.addAction(UIAction(identifier: Self.accessoryPostKeyActionID) { [weak self] _ in
                            guard let self else { return }
                            isRoutingToSuperInput = false
                            forgetTypedText()
                        }, for: .touchUpInside)
                    }
                }
            }
            for subview in root.subviews {
                rebindAccessoryButtons(in: subview)
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var remaining = presses
            let onCommandKey = (delegate as? TerminalExtras)?.onCommandKey
            for press in presses {
                guard let key = press.key else { continue }
                let modifiers = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
                guard modifiers == .command || modifiers == [.command, .shift] else { continue }
                let character = key.charactersIgnoringModifiers.lowercased()
                if modifiers == .command, character == "v" || (key.keyCode == .keyboardV && !character.allSatisfy(\.isASCII)) {
                    paste(nil)
                    interceptedPresses.insert(press)
                    remaining.remove(press)
                    continue
                }
                if onCommandKey?(character, modifiers) == true {
                    forgetTypedText()
                    interceptedPresses.insert(press)
                    remaining.remove(press)
                }
            }
            if !remaining.isEmpty {
                let sendsDirectHardwareKey = remaining.contains { press in
                    guard let key = press.key, !Self.modifierKeyCodes.contains(key.keyCode) else { return false }
                    return !shouldDeferHardwareKeyToInputMethod(key)
                }
                if sendsDirectHardwareKey {
                    if markedRange != nil {
                        unmarkText()
                    }
                    forgetTypedText()
                }
                super.pressesBegan(remaining, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(interceptedPresses)
            interceptedPresses.subtract(presses)
            if !remaining.isEmpty {
                let endedDirectHardwareKey = markedRange == nil && remaining.contains { press in
                    guard let key = press.key, !Self.modifierKeyCodes.contains(key.keyCode) else { return false }
                    return !shouldDeferHardwareKeyToInputMethod(key)
                }
                if endedDirectHardwareKey {
                    forgetTypedText()
                }
                super.pressesEnded(remaining, with: event)
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = presses.subtracting(interceptedPresses)
            interceptedPresses.subtract(presses)
            if !remaining.isEmpty {
                super.pressesCancelled(remaining, with: event)
            }
        }

        private func shouldDeferHardwareKeyToInputMethod(_ key: UIKey) -> Bool {
            guard key.modifierFlags.isDisjoint(with: [.control, .command]) else { return false }
            if markedRange != nil {
                return true
            }
            guard let language = textInputMode?.primaryLanguage?.lowercased(),
                  language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
            else { return false }
            let characters = key.characters
            guard !characters.isEmpty, !characters.hasPrefix("UIKeyInput") else { return false }
            if characters.count == 1,
               let scalar = characters.unicodeScalars.first,
               scalar.value >= 0xF700, scalar.value <= 0xF8FF
            {
                return false
            }
            return !characters.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }

        override var inputDelegate: (any UITextInputDelegate)? {
            get { isRoutingToSuperInput ? superInputDelegate : systemInputDelegate }
            set { systemInputDelegate = newValue }
        }

        @available(iOS 18.0, *)
        var writingToolsBehavior: UIWritingToolsBehavior {
            get { .none }
            set {}
        }

        override func insertText(_ text: String) {
            if markedRange == nil, text == "\n" || text == "\r" {
                _ = withSuperInput { super.insertText(text) }
                forgetTypedText()
                return
            }
            if hasActiveStickyModifiers {
                if super.markedTextRange != nil {
                    _ = withSuperInput { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
                }
                _ = withSuperInput { super.insertText(text) }
                markedRange = nil
                forgetTypedText()
                return
            }
            if markedRange == nil, selection == NSRange(location: documentLength, length: 0) {
                let sentAsText = withSuperInput { super.insertText(text) }
                guard sentAsText else {
                    forgetTypedText()
                    return
                }
                document += text
                selection = NSRange(location: documentLength, length: 0)
                typedText += text
                return
            }
            if super.markedTextRange != nil {
                _ = withSuperInput { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
            }
            let range = markedRange ?? selection
            document = (document as NSString).replacingCharacters(in: range, with: text)
            markedRange = nil
            selection = NSRange(location: range.location + (text as NSString).length, length: 0)
            syncTypedText()
        }

        override func deleteBackward() {
            if markedRange == nil, hasActiveStickyModifiers {
                _ = withSuperInput { super.deleteBackward() }
                forgetTypedText()
                return
            }
            var deleted = selection
            if deleted.length == 0 {
                guard deleted.location > Self.documentAnchorLength else {
                    if markedRange == nil {
                        if typedText.isEmpty {
                            _ = withSuperInput { super.deleteBackward() }
                        } else {
                            deleteBeforeTypedText()
                        }
                    }
                    return
                }
                deleted = (document as NSString).rangeOfComposedCharacterSequence(at: deleted.location - 1)
            }
            if let marked = markedRange {
                deleted = NSIntersectionRange(deleted, marked)
                guard deleted.length > 0 else { return }
                markedRange = marked.length > deleted.length
                    ? NSRange(location: marked.location, length: marked.length - deleted.length)
                    : nil
            }
            document = (document as NSString).replacingCharacters(in: deleted, with: "")
            selection = NSRange(location: deleted.location, length: 0)
            if let marked = markedRange {
                let markedText = (document as NSString).substring(with: marked)
                let markedSelection = NSRange(
                    location: min(max(selection.location - marked.location, 0), marked.length),
                    length: 0
                )
                _ = withSuperInput { super.setMarkedText(markedText, selectedRange: markedSelection) }
            } else if super.markedTextRange != nil {
                _ = withSuperInput { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
            }
            syncTypedText()
        }

        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            let text = markedText ?? ""
            if !text.isEmpty, hasActiveStickyModifiers {
                _ = withSuperInput { super.setMarkedText(text, selectedRange: selectedRange) }
                if super.markedTextRange == nil {
                    markedRange = nil
                    forgetTypedText()
                    return
                }
            }
            let range = markedRange ?? selection
            let length = (text as NSString).length
            document = (document as NSString).replacingCharacters(in: range, with: text)
            markedRange = length > 0 ? NSRange(location: range.location, length: length) : nil
            let clampedLocation = min(max(selectedRange.location, 0), length)
            let clampedLength = min(max(selectedRange.length, 0), length - clampedLocation)
            selection = NSRange(location: range.location + clampedLocation, length: clampedLength)
            if super.markedTextRange != nil {
                _ = withSuperInput { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
            }
            syncTypedText()
            if length > 0 {
                _ = withSuperInput {
                    super.setMarkedText(text, selectedRange: NSRange(location: clampedLocation, length: clampedLength))
                }
            }
        }

        override func unmarkText() {
            guard markedRange != nil else { return }
            markedRange = nil
            if super.markedTextRange != nil {
                _ = withSuperInput { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
            }
            syncTypedText()
        }

        override func replace(_ range: UITextRange, withText text: String) {
            guard let rawRange = nsRange(range) else { return }
            if NSMaxRange(rawRange) <= Self.documentAnchorLength {
                if rawRange.length > 0, text.isEmpty {
                    if typedText.isEmpty {
                        _ = withSuperInput { super.deleteBackward() }
                    } else {
                        deleteBeforeTypedText()
                    }
                }
                return
            }
            let editableRange: NSRange
            let replacement: String
            if rawRange.location < Self.documentAnchorLength {
                let start = Self.documentAnchorLength
                let end = max(NSMaxRange(rawRange), start)
                editableRange = NSRange(location: start, length: end - start)
                replacement = text.hasPrefix("\n") ? String(text.dropFirst()) : text
            } else {
                editableRange = rawRange
                replacement = text
            }
            if markedRange == nil,
               selection == NSRange(location: NSMaxRange(editableRange), length: 0),
               (document as NSString).substring(with: editableRange) == " ",
               replacement == "." || replacement == "。"
            {
                return
            }
            if super.markedTextRange != nil {
                _ = withSuperInput { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
            }
            if hasActiveStickyModifiers {
                _ = withSuperInput { super.insertText(replacement) }
                markedRange = nil
                forgetTypedText()
                return
            }
            let length = (replacement as NSString).length
            document = (document as NSString).replacingCharacters(in: editableRange, with: replacement)
            markedRange = nil
            if NSMaxRange(editableRange) <= selection.location {
                selection.location += length - editableRange.length
            } else if editableRange.location < NSMaxRange(selection) {
                selection = NSRange(location: editableRange.location + length, length: 0)
            }
            selection = clampedEditableRange(selection)
            syncTypedText()
        }

        override func text(in range: UITextRange) -> String? {
            nsRange(range).map { (document as NSString).substring(with: $0) }
        }

        override var markedTextRange: UITextRange? {
            markedRange.map(SurfaceTextRange.init)
        }

        override var selectedTextRange: UITextRange? {
            get { SurfaceTextRange(selection) }
            set {
                if let range = newValue.flatMap(nsRange) {
                    selection = clampedEditableRange(range)
                } else {
                    selection = NSRange(location: documentLength, length: 0)
                }
            }
        }

        override var beginningOfDocument: UITextPosition {
            SurfaceTextPosition(0)
        }

        override var endOfDocument: UITextPosition {
            SurfaceTextPosition(documentLength)
        }

        override func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            guard let from = fromPosition as? SurfaceTextPosition,
                  let to = toPosition as? SurfaceTextPosition
            else { return nil }
            return SurfaceTextRange(
                NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset))
            )
        }

        override func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            guard let position = position as? SurfaceTextPosition else { return nil }
            let next = position.offset + offset
            return (0 ... documentLength).contains(next) ? SurfaceTextPosition(next) : nil
        }

        override func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
            switch direction {
            case .left, .up: self.position(from: position, offset: -offset)
            default: self.position(from: position, offset: offset)
            }
        }

        override func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
            let delta = offset(from: other, to: position)
            return delta < 0 ? .orderedAscending : delta > 0 ? .orderedDescending : .orderedSame
        }

        override func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
            guard let from = from as? SurfaceTextPosition,
                  let to = toPosition as? SurfaceTextPosition
            else { return 0 }
            return to.offset - from.offset
        }

        override func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
            switch direction {
            case .left, .up: range.start
            default: range.end
            }
        }

        override func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
            switch direction {
            case .left, .up: textRange(from: beginningOfDocument, to: position)
            default: textRange(from: position, to: endOfDocument)
            }
        }

        override func firstRect(for range: UITextRange) -> CGRect {
            let baseRect = super.caretRect(for: super.beginningOfDocument)
            guard let marked = markedRange,
                  marked.length > 0,
                  let range = nsRange(range)
            else { return baseRect }
            let start = min(max(range.location - marked.location, 0), marked.length)
            let end = min(max(NSMaxRange(range) - marked.location, start), marked.length)
            let width = max(CGFloat(end - start) * baseRect.width, 2)
            return CGRect(
                x: baseRect.minX + CGFloat(start) * baseRect.width,
                y: baseRect.minY,
                width: width,
                height: baseRect.height
            )
        }

        override func caretRect(for position: UITextPosition) -> CGRect {
            let baseRect = super.caretRect(for: super.beginningOfDocument)
            guard let marked = markedRange,
                  marked.length > 0,
                  let position = position as? SurfaceTextPosition
            else { return baseRect }
            let markedOffset = min(max(position.offset - marked.location, 0), marked.length)
            return CGRect(
                x: baseRect.minX + CGFloat(markedOffset) * baseRect.width,
                y: baseRect.minY,
                width: baseRect.width,
                height: baseRect.height
            )
        }

        override func closestPosition(to point: CGPoint) -> UITextPosition? {
            guard let marked = markedRange, marked.length > 0 else { return endOfDocument }
            let baseRect = super.caretRect(for: super.beginningOfDocument)
            guard baseRect.width > 0 else { return SurfaceTextPosition(marked.location) }
            let rawIndex = Int(((point.x - baseRect.minX) / baseRect.width).rounded(.down))
            let clamped = min(max(rawIndex, 0), marked.length)
            return SurfaceTextPosition(marked.location + clamped)
        }

        override func closestPosition(to _: CGPoint, within range: UITextRange) -> UITextPosition? {
            range.end
        }

        override func characterRange(at _: CGPoint) -> UITextRange? {
            nil
        }

        fileprivate func forgetTypedText() {
            guard !typedText.isEmpty else { return }
            guard markedRange == nil else {
                dropTypedText()
                return
            }
            systemInputDelegate?.selectionWillChange(self)
            systemInputDelegate?.textWillChange(self)
            dropTypedText()
            systemInputDelegate?.textDidChange(self)
            systemInputDelegate?.selectionDidChange(self)
        }

        private func dropTypedText() {
            typedText = ""
            guard let marked = markedRange else {
                document = "\n"
                selection = NSRange(location: Self.documentAnchorLength, length: 0)
                return
            }
            document = "\n" + (document as NSString).substring(with: marked)
            markedRange = NSRange(location: Self.documentAnchorLength, length: marked.length)
            selection = clampedEditableRange(
                NSRange(
                    location: Self.documentAnchorLength + selection.location - marked.location,
                    length: selection.length
                )
            )
        }

        private func deleteBeforeTypedText() {
            let count = typedText.count + 1
            for _ in 0 ..< count {
                _ = sendKey(.backspace)
            }
            if typedText.contains(where: \.isNewline) {
                _ = paste(text: typedText)
            } else if !withSuperInput({ super.insertText(typedText) }) {
                dropTypedText()
            }
        }

        private func syncTypedText() {
            let text = committedDocumentText()
            guard text != typedText else { return }
            let kept = zip(typedText, text).prefix { $0 == $1 }.count
            let deleting = typedText.count - kept
            let inserted = String(text.dropFirst(kept))
            typedText = text
            for _ in 0 ..< deleting {
                _ = sendKey(.backspace)
            }
            guard !inserted.isEmpty else { return }
            if inserted.contains(where: \.isNewline) {
                _ = paste(text: inserted)
            } else if !withSuperInput({ super.insertText(inserted) }) {
                dropTypedText()
            }
        }

        private func committedDocumentText() -> String {
            let withoutMarked = markedRange.map { (document as NSString).replacingCharacters(in: $0, with: "") } ?? document
            return String(withoutMarked.dropFirst())
        }

        @discardableResult
        private func withSuperInput(_ body: () -> Void) -> Bool {
            let previous = isRoutingToSuperInput
            isRoutingToSuperInput = true
            superInputDelegate.didMutateText = false
            body()
            isRoutingToSuperInput = previous
            return superInputDelegate.didMutateText
        }

        private var documentLength: Int {
            (document as NSString).length
        }

        private func clampedDocumentRange(_ range: NSRange) -> NSRange {
            let location = min(max(range.location, 0), documentLength)
            return NSRange(location: location, length: min(max(range.length, 0), documentLength - location))
        }

        private func clampedEditableRange(_ range: NSRange) -> NSRange {
            let location = min(max(range.location, Self.documentAnchorLength), documentLength)
            return NSRange(location: location, length: min(max(range.length, 0), documentLength - location))
        }

        private func nsRange(_ range: UITextRange) -> NSRange? {
            guard let range = range as? SurfaceTextRange else { return nil }
            return clampedDocumentRange(range.range)
        }
    }

    private final class SurfaceDropDelegate: NSObject, UIDropInteractionDelegate {
        weak var surfaceView: SurfaceView?

        init(surfaceView: SurfaceView) {
            self.surfaceView = surfaceView
        }

        func dropInteraction(_: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            session.items.contains { item in
                HostPasteStaging.stageableType(among: item.itemProvider.registeredTypeIdentifiers) != nil
            }
                || session.canLoadObjects(ofClass: NSURL.self)
                || session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: any UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_: UIDropInteraction, performDrop session: any UIDropSession) {
            let providerItems = session.items.compactMap { item in
                HostPasteStaging.stageableType(among: item.itemProvider.registeredTypeIdentifiers)
                    .map { HostPasteStaging.ProviderItem(provider: item.itemProvider, type: $0) }
            }
            if !providerItems.isEmpty {
                HostPasteStaging.shared.stageProviders(providerItems) { [weak surfaceView] result in
                    guard let surfaceView else { return }
                    do {
                        guard let paths = try result.get() else { return }
                        surfaceView.forgetTypedText()
                        _ = surfaceView.paste(text: paths)
                    } catch {
                        surfaceView.onPasteFailure?(error)
                    }
                }
                return
            }

            if session.canLoadObjects(ofClass: NSURL.self) {
                let hasText = session.canLoadObjects(ofClass: NSString.self)
                _ = session.loadObjects(ofClass: NSURL.self) { [weak surfaceView] objects in
                    let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
                    let fileURLs = urls.filter(\.isFileURL)
                    if !fileURLs.isEmpty {
                        HostPasteStaging.shared.stageFileURLs(fileURLs) { [weak surfaceView] result in
                            guard let surfaceView else { return }
                            do {
                                guard let paths = try result.get() else { return }
                                surfaceView.forgetTypedText()
                                _ = surfaceView.paste(text: paths)
                            } catch {
                                surfaceView.onPasteFailure?(error)
                            }
                        }
                        return
                    }
                    let deliver: @Sendable (String?) -> Void = { string in
                        Task { @MainActor in
                            guard let surfaceView,
                                  let text = HostPasteStaging.plainText(string: string, urls: urls)
                            else { return }
                            surfaceView.forgetTypedText()
                            _ = surfaceView.pasteWithProtection(text: text)
                        }
                    }
                    guard hasText else {
                        deliver(nil)
                        return
                    }
                    _ = session.loadObjects(ofClass: NSString.self) { strings in
                        let joined = strings.compactMap { ($0 as? NSString).map { $0 as String } }.joined()
                        deliver(joined)
                    }
                }
                return
            }

            if session.canLoadObjects(ofClass: NSString.self) {
                _ = session.loadObjects(ofClass: NSString.self) { [weak surfaceView] objects in
                    let text = objects.compactMap { ($0 as? NSString).map { $0 as String } }.joined()
                    guard !text.isEmpty else { return }
                    Task { @MainActor in
                        guard let surfaceView else { return }
                        surfaceView.forgetTypedText()
                        _ = surfaceView.pasteWithProtection(text: text)
                    }
                }
            }
        }
    }
}

private final nonisolated class SuperInputDelegate: NSObject, UITextInputDelegate, @unchecked Sendable {
    var didMutateText = false

    func selectionWillChange(_: (any UITextInput)?) {}
    func selectionDidChange(_: (any UITextInput)?) {}
    func textWillChange(_: (any UITextInput)?) {
        didMutateText = true
    }

    func textDidChange(_: (any UITextInput)?) {
        didMutateText = true
    }

    @available(iOS 18.4, *)
    func conversationContext(_: UIConversationContext?, didChange _: (any UITextInput)?) {}
}

private final class SurfaceTextPosition: UITextPosition {
    nonisolated let offset: Int

    init(_ offset: Int) {
        self.offset = offset
        super.init()
    }

    override nonisolated func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SurfaceTextPosition else { return false }
        return offset == other.offset
    }

    override nonisolated var hash: Int {
        offset.hashValue
    }
}

private final class SurfaceTextRange: UITextRange {
    nonisolated let range: NSRange

    init(_ range: NSRange) {
        self.range = range
        super.init()
    }

    override var start: UITextPosition {
        SurfaceTextPosition(range.location)
    }

    override var end: UITextPosition {
        SurfaceTextPosition(NSMaxRange(range))
    }

    override var isEmpty: Bool {
        range.length == 0
    }

    override nonisolated func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SurfaceTextRange else { return false }
        return range == other.range
    }

    override nonisolated var hash: Int {
        var hasher = Hasher()
        hasher.combine(range.location)
        hasher.combine(range.length)
        return hasher.finalize()
    }
}

private final class SoftwareKeyboardTracker {
    static let shared = SoftwareKeyboardTracker()
    private(set) var isOnScreen = false

    private init() {
        let center = NotificationCenter.default
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ] {
            center.addObserver(self, selector: #selector(keyboardFrameDidChange(_:)), name: name, object: nil)
        }
    }

    @objc private func keyboardFrameDidChange(_ notification: Notification) {
        let frame = notification.userInfo![UIResponder.keyboardFrameEndUserInfoKey] as! CGRect
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let screenBounds = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen.bounds else {
            isOnScreen = false
            return
        }
        isOnScreen = frame.height > 0 && frame.intersects(screenBounds)
    }
}

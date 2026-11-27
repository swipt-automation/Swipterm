import GhosttyTerminal
import Observation
import SwiftUI
import UIKit

struct TerminalContainerView: View {
    let sessionManager: TerminalSessionManager

    @Binding var showSettings: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var splitState = TerminalSplitPresentationState()
    @State private var pendingPaste: TerminalClipboardConfirmationRequest?
    @State private var pasteFailure: String?
    @State private var notificationFailure: String?

    var body: some View {
        let isRunning = sessionManager.services.system.state == .running
        TerminalSplitViewRepresentable(
            sessionManager: sessionManager,
            splitState: splitState,
            actualHorizontalSizeClass: horizontalSizeClass,
            isRunning: isRunning,
            onOpenSettings: { showSettings = true },
            onSetupCallbacks: setupCallbacks
        )
        .ignoresSafeArea()
        .modifier(HorizontalBarsOnlyModifier())
        .background {
            if isRunning {
                TerminalKeyboardShortcuts(
                    onNewSession: { sessionManager.addSession() },
                    onCloseSession: {
                        if let id = sessionManager.activeSessionID {
                            sessionManager.closeSession(id: id)
                        }
                    },
                    onPreviousSession: { sessionManager.selectAdjacentSession(offset: -1) },
                    onNextSession: { sessionManager.selectAdjacentSession(offset: 1) },
                    onOpenSettings: { showSettings = true },
                    onFind: { sessionManager.activeSession?.search.present() },
                    onFindNext: { sessionManager.activeSession?.search.navigate(.older) },
                    onFindPrevious: { sessionManager.activeSession?.search.navigate(.newer) }
                )
            }
        }
        .alert(
            "Paste Potentially Unsafe Text?",
            isPresented: Binding {
                pendingPaste != nil
            } set: { isPresented in
                if !isPresented {
                    pendingPaste = nil
                }
            },
            presenting: pendingPaste
        ) { request in
            Button("Paste") {
                request.respond(allow: true)
            }
            Button("Cancel", role: .cancel) {
                request.respond(allow: false)
            }
        } message: { _ in
            Text("This text contains line breaks and may run commands as soon as it is pasted.")
        }
        .alert("Couldn’t Paste", isPresented: Binding {
            pasteFailure != nil
        } set: { presented in
            if !presented {
                pasteFailure = nil
            }
        }, presenting: pasteFailure) { _ in
        } message: { failure in
            Text(failure)
        }
        .alert("Couldn’t Show Notification", isPresented: Binding {
            notificationFailure != nil
        } set: { presented in
            if !presented {
                notificationFailure = nil
            }
        }, presenting: notificationFailure) { _ in
        } message: { failure in
            Text(failure)
        }
        .onChange(of: showSettings, initial: true) { _, isPresented in
            splitState.isSettingsPresented = isPresented
        }
        .onChange(of: sessionManager.sessions.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            switch sessionManager.services.system.state {
            case .booting, .running, .failed:
                sessionManager.ensureInitialSession()
            default:
                break
            }
        }
        .onAppear {
            sessionManager.ensureInitialSession()
        }
    }

    private func setupCallbacks(for session: TerminalSession) {
        let system = sessionManager.services.system
        session.extras.onOpenURL = { urlString, _ in
            guard let url = URL(string: urlString) else { return }
            system.pendingOpenURL = url
        }
        session.extras.onPasteConfirmation = { request in
            pendingPaste = request
        }
        session.extras.onNotificationFailure = { error in
            notificationFailure = error.localizedDescription
        }
        session.surfaceView.onPasteFailure = { error in
            pasteFailure = error.localizedDescription
        }
        session.extras.onCommandKey = { key, modifiers in
            guard system.state == .running else { return false }
            if modifiers == [.command, .shift] {
                guard key == "g" else { return false }
                session.search.navigate(.newer)
                return true
            }
            switch key {
            case "n", "t":
                sessionManager.addSession()
                return true
            case "w":
                sessionManager.closeSession(id: session.id)
                return true
            case ",":
                showSettings = true
                return true
            case "f":
                session.search.present()
                return true
            case "g":
                session.search.navigate(.older)
                return true
            case "e":
                return session.state.performBindingAction("search_selection")
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                sessionManager.selectSession(at: Int(key)! - 1)
                return true
            default:
                return false
            }
        }
    }
}

@Observable
private final class TerminalSplitPresentationState {
    var isSidebarOverlayVisible = false
    var isSidebarVisible = false
    var isSettingsPresented = false
    var isShortcutsPresented = false

    var isTerminalInputActive: Bool {
        !isSidebarOverlayVisible && !isSettingsPresented && !isShortcutsPresented
    }
}

private struct TerminalSplitViewRepresentable: UIViewControllerRepresentable {
    let sessionManager: TerminalSessionManager
    let splitState: TerminalSplitPresentationState
    let actualHorizontalSizeClass: UserInterfaceSizeClass?
    let isRunning: Bool
    let onOpenSettings: () -> Void
    let onSetupCallbacks: (TerminalSession) -> Void

    #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
        @Environment(StoreScreenshotLocalization.self) private var screenshotLocalization
    #endif

    func makeCoordinator() -> Coordinator {
        Coordinator(splitState: splitState, onOpenSettings: onOpenSettings)
    }

    func makeUIViewController(context: Context) -> UISplitViewController {
        let splitViewController = UISplitViewController(style: .doubleColumn)
        splitViewController.delegate = context.coordinator
        splitViewController.primaryBackgroundStyle = .sidebar
        splitViewController.preferredDisplayMode = .secondaryOnly
        splitViewController.minimumPrimaryColumnWidth = 260
        splitViewController.preferredPrimaryColumnWidth = 300
        splitViewController.maximumPrimaryColumnWidth = 320

        let coordinator = context.coordinator
        let primaryHosting = UIHostingController(
            rootView: TerminalSidebarView(
                sessionManager: sessionManager,
                onSelectSession: { coordinator.hideSidebarIfOverlay() },
                onOpenSettings: {
                    coordinator.hideSidebarIfOverlay()
                    coordinator.onOpenSettings()
                },
                onManageShortcuts: {
                    coordinator.hideSidebarIfOverlay()
                    coordinator.splitState.isShortcutsPresented = true
                }
            )
            #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            .modifier(StoreScreenshotLocaleModifier(localization: screenshotLocalization))
            #endif
        )
        primaryHosting.view.backgroundColor = .clear
        let secondaryHosting = UIHostingController(
            rootView: TerminalDetailView(
                sessionManager: sessionManager,
                splitState: splitState,
                onSetupCallbacks: onSetupCallbacks
            )
            #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            .modifier(StoreScreenshotLocaleModifier(localization: screenshotLocalization))
            #endif
        )

        coordinator.splitViewController = splitViewController
        coordinator.secondaryHosting = secondaryHosting

        splitViewController.setViewController(primaryHosting, for: .primary)
        splitViewController.setViewController(secondaryHosting, for: .secondary)
        return splitViewController
    }

    func updateUIViewController(_ splitViewController: UISplitViewController, context: Context) {
        context.coordinator.onOpenSettings = onOpenSettings
        #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
            let isRTL = context.environment.layoutDirection == .rightToLeft
            splitViewController.view.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
            splitViewController.traitOverrides.layoutDirection = isRTL ? .rightToLeft : .leftToRight
        #endif
        applyLayoutBehavior(to: splitViewController, coordinator: context.coordinator)
        applyRunningState(to: splitViewController)
    }

    private func applyRunningState(to splitViewController: UISplitViewController) {
        if splitViewController.presentsWithGesture != isRunning {
            splitViewController.presentsWithGesture = isRunning
        }
        let buttonVisibility: UISplitViewController.DisplayModeButtonVisibility = isRunning ? .always : .never
        if splitViewController.displayModeButtonVisibility != buttonVisibility {
            splitViewController.displayModeButtonVisibility = buttonVisibility
        }
        if !isRunning, splitViewController.displayMode != .secondaryOnly {
            splitViewController.hide(.primary)
        }
    }

    private func applyLayoutBehavior(to splitViewController: UISplitViewController, coordinator: Coordinator) {
        let isCompact = actualHorizontalSizeClass == .compact
        guard coordinator.lastIsCompact != isCompact else { return }
        coordinator.lastIsCompact = isCompact

        if isCompact {
            splitViewController.traitOverrides.horizontalSizeClass = .regular
            splitViewController.preferredSplitBehavior = .overlay
            coordinator.secondaryHosting?.traitOverrides.horizontalSizeClass = .compact
        } else {
            splitViewController.traitOverrides.remove(UITraitHorizontalSizeClass.self)
            splitViewController.preferredSplitBehavior = .automatic
            coordinator.secondaryHosting?.traitOverrides.remove(UITraitHorizontalSizeClass.self)
        }
    }

    final class Coordinator: NSObject, UISplitViewControllerDelegate {
        let splitState: TerminalSplitPresentationState
        var onOpenSettings: () -> Void
        weak var splitViewController: UISplitViewController?
        weak var secondaryHosting: UIViewController?
        var lastIsCompact: Bool?

        init(splitState: TerminalSplitPresentationState, onOpenSettings: @escaping () -> Void) {
            self.splitState = splitState
            self.onOpenSettings = onOpenSettings
        }

        func hideSidebarIfOverlay() {
            guard let svc = splitViewController, svc.splitBehavior == .overlay else { return }
            svc.hide(.primary)
        }

        func splitViewController(
            _: UISplitViewController,
            willChangeTo displayMode: UISplitViewController.DisplayMode
        ) {
            splitState.isSidebarOverlayVisible = (displayMode == .oneOverSecondary || displayMode == .twoOverSecondary)
            splitState.isSidebarVisible = displayMode != .secondaryOnly
        }

        func splitViewController(_ svc: UISplitViewController, willShow column: UISplitViewController.Column) {
            if column == .primary, svc.splitBehavior == .overlay {
                splitState.isSidebarOverlayVisible = true
            }
        }

        func splitViewController(_ svc: UISplitViewController, willHide column: UISplitViewController.Column) {
            if column == .primary, svc.splitBehavior == .overlay {
                splitState.isSidebarOverlayVisible = false
            }
        }
    }
}

private struct TerminalDetailView: View {
    let sessionManager: TerminalSessionManager
    let splitState: TerminalSplitPresentationState
    let onSetupCallbacks: (TerminalSession) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let isRunning = sessionManager.services.system.state == .running
        GeometryReader { column in
            terminalContent
                .toolbar { toolbar(columnWidth: column.size.width, isRunning: isRunning) }
        }
        .navigationTitle(isRunning && horizontalSizeClass == .regular ? "" : (sessionManager.activeSession?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(HorizontalBarsOnlyModifier())
        .sheet(isPresented: Bindable(splitState).isShortcutsPresented) {
            NavigationStack {
                ManageShortcutsView(services: sessionManager.services)
            }
        }
    }

    private var terminalContent: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                let isSelected = session.id == sessionManager.activeSessionID
                TerminalSessionContentView(
                    session: session,
                    isActive: isSelected && splitState.isTerminalInputActive && session.phase == .running && !session.search.isEditing,
                    isVisible: isSelected
                ) {
                    sessionManager.closeSession(id: session.id)
                }
                .opacity(isSelected ? 1 : 0)
                .zIndex(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .onAppear {
                    onSetupCallbacks(session)
                }
                .onChange(of: isSelected, initial: true) { _, isSelected in
                    session.search.setSurfaceActive(isSelected)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if horizontalSizeClass != .regular, let session = sessionManager.activeSession {
                FindDock(search: session.search, isFloating: false)
                    .id(session.id)
            }
        }
        .overlay {
            if horizontalSizeClass == .regular, let session = sessionManager.activeSession {
                FindDock(search: session.search, isFloating: true)
                    .id(session.id)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(columnWidth: CGFloat, isRunning: Bool) -> some ToolbarContent {
        if isRunning {
            if !splitState.isSidebarVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("New") {
                            NewSessionMenuItems(sessionManager: sessionManager, onAdd: {})
                        }
                        Section {
                            Button {
                                sessionManager.activeSession?.search.present()
                            } label: {
                                Label("Find", systemImage: "magnifyingglass")
                            }
                            Button {
                                splitState.isShortcutsPresented = true
                            } label: {
                                Label("Manage Shortcuts", systemImage: "slider.horizontal.3")
                            }
                        }
                    } label: {
                        Label("Others", systemImage: "ellipsis")
                    }
                }
            }
            if horizontalSizeClass == .regular {
                let tabBar = TerminalTabBar(
                    sessionManager: sessionManager,
                    showsActiveSessionOnly: splitState.isSidebarVisible,
                    columnWidth: columnWidth
                )
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .principal) { tabBar }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { tabBar }
                }
            }
        }
    }
}

private struct HorizontalBarsOnlyModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
    }
}

private struct TerminalKeyboardShortcuts: View {
    let onNewSession: () -> Void
    let onCloseSession: () -> Void
    let onPreviousSession: () -> Void
    let onNextSession: () -> Void
    let onOpenSettings: () -> Void
    let onFind: () -> Void
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void

    var body: some View {
        Group {
            Button("New Session", action: onNewSession)
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab", action: onNewSession)
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Session", action: onCloseSession)
                .keyboardShortcut("w", modifiers: .command)
            Button("Previous Session", action: onPreviousSession)
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Session", action: onNextSession)
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Settings", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
            Button("Find", action: onFind)
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next", action: onFindNext)
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous", action: onFindPrevious)
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

import SwiftUI

@main
struct SwiptermApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            Group {
                #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                    StoreScreenshotBatch { ContentView(services: services) }
                #else
                    ContentView(services: services)
                #endif
            }
            .environment(services.system)
            .environment(services.containers)
            .environment(services.settings)
            .environment(services.location)
            .environment(services.catalog)
            .environment(services.fonts)
            #if DEBUG || SIDELOAD
                .environment(services.jit)
            #endif
        }
    }
}

private struct ContentView: View {
    let services: AppServices

    @State private var sessionManager: TerminalSessionManager
    @State private var setupDraft = SetupDraft()
    @State private var showSettings = false

    #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
        @Environment(\.locale) private var screenshotLocale
    #endif

    init(services: AppServices) {
        self.services = services
        _sessionManager = State(initialValue: TerminalSessionManager(services: services))
    }

    var body: some View {
        let system = services.system
        let containers = services.containers
        let creation = containers.creations.first
        Group {
            switch system.state {
            case .checking:
                Color.clear
            case .setup:
                NavigationStack {
                    if let creation {
                        ProvisioningView(creation: creation)
                            .id(creation.attempt)
                    } else {
                        SetupView(draft: $setupDraft) { _ in }
                    }
                }
                #if SWIPTERM_STORE_SCREENSHOTS && targetEnvironment(simulator)
                .id(screenshotLocale)
                #endif
            case .booting, .running, .shuttingDown, .halted, .failed:
                TerminalContainerView(sessionManager: sessionManager, showSettings: $showSettings)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .modifier(KeepScreenAwakeModifier(
            isRequired: system.state == .shuttingDown || containers.creations.contains { $0.state == .running } || !containers.exportProgress.isEmpty
        ))
        .modifier(OpenURLPromptModifier())
        .modifier(BootFailurePromptModifier())
        .onChange(of: system.state) { _, state in
            switch state {
            case .running:
                setupDraft = SetupDraft()
            case .setup, .shuttingDown, .failed:
                showSettings = false
            default:
                break
            }
        }
        #if !SWIPTERM_STORE_SCREENSHOTS || !targetEnvironment(simulator)
        .task {
            system.onWillShutdown = {
                sessionManager.closeAll()
            }
            #if DEBUG || SIDELOAD
                services.jit.start()
            #endif
            await services.fonts.bootstrap()
            system.bootstrap()
        }
        #endif
    }
}

private struct KeepScreenAwakeModifier: ViewModifier {
    let isRequired: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isRequired, initial: true) { _, keepsAwake in
                UIApplication.shared.isIdleTimerDisabled = keepsAwake
            }
    }
}

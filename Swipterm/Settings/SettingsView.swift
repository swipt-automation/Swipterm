import SwiftUI
import SwiptermKit
import UIKit

struct SettingsView: View {
    private static let gpuModes: [GPUMode] = [.automatic] + LinuxRuntime.availableGPUBackends.map(GPUMode.init) + [.disabled]

    private let system = LinuxSystem.shared
    @Bindable private var settings = AppSettings.shared
    @Bindable private var location = HostLocation.shared

    @Environment(\.dismiss) private var dismiss
    @State private var newContainerDraft = SetupDraft()
    @State private var isCreatingContainer = false
    @State private var isImportingContainer = false

    var body: some View {
        Form {
            Section("Engine") {
                Picker("GPU", selection: $settings.gpuMode) {
                    ForEach(Self.gpuModes, id: \.self) { mode in
                        Group {
                            switch mode {
                            case .automatic:
                                Text("Automatic")
                            case .moltenVK:
                                Text(verbatim: "MoltenVK")
                            case .kosmicKrisp:
                                Text(verbatim: "KosmicKrisp")
                            case .disabled:
                                Text("Disabled")
                            }
                        }
                        .tag(mode)
                    }
                }
                #if DEBUG || SIDELOAD
                    JITRow()
                #endif
                #if DEBUG || SIDELOAD || TESTFLIGHT
                    caffeinateToggle
                #else
                    if settings.isCaffeinateAvailable {
                        caffeinateToggle
                    }
                #endif
                if let runtimeGPUMode = system.runtimeGPUMode, runtimeGPUMode != settings.gpuMode {
                    Button("Restart to Apply") {
                        dismiss()
                        system.restart()
                    }
                }
            }
            ContainerListSection {
                isCreatingContainer = true
            } onImport: {
                isImportingContainer = true
            } row: { container in
                NavigationLink {
                    ContainerView(container: container, dismissSettings: dismiss)
                } label: {
                    ContainerLabel(container: container)
                }
            }
            Section("Terminal") {
                NavigationLink("Ghostty Configuration") {
                    GhosttyConfigurationView()
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isCreatingContainer) {
            SetupView(draft: $newContainerDraft)
        }
        .modifier(ContainerImporterModifier(isPresented: $isImportingContainer))
        .alert("No Location Access", isPresented: $location.isPresentingDeniedAlert) {
            Button("Open Settings") {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            location.isSettingsVisible = true
        }
        .onDisappear {
            location.isSettingsVisible = false
            location.isPresentingDeniedAlert = false
        }
    }

    private var caffeinateToggle: some View {
        Toggle("Keep Running in Background", isOn: Binding {
            settings.isCaffeinateEnabled
        } set: { isEnabled in
            location.setCaffeinateEnabled(isEnabled)
        })
    }
}

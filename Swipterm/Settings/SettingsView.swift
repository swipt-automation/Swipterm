import SwiftUI
import SwiptermKit
import UIKit

struct SettingsView: View {
    private static let gpuModes: [GPUMode] = [.automatic] + LinuxRuntime.availableGPUBackends.map(GPUMode.init) + [.disabled]

    @Environment(LinuxSystem.self) private var system
    @Environment(AppSettings.self) private var settings
    @Environment(HostLocation.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var path: [ContainerRoute] = []
    @State private var isImportingContainer = false

    var body: some View {
        @Bindable var settings = settings
        @Bindable var location = location
        NavigationStack(path: $path) {
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
                    path.append(.newContainer)
                } onImport: {
                    isImportingContainer = true
                } onOpenCreation: { creation in
                    path.append(.creation(creation.id))
                } row: { container in
                    NavigationLink(value: ContainerRoute.container(container.id)) {
                        ContainerLabel(container: container)
                    }
                }
                Section("Terminal") {
                    NavigationLink("Ghostty Configuration") {
                        GhosttyConfigurationView(settings: settings)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ContainerDestinationModifier(path: $path, dismissSettings: dismiss))
            .modifier(ContainerImporterModifier(isPresented: $isImportingContainer) { creation in
                path.append(.creation(creation.id))
            })
            .alert("No Location Access", isPresented: $location.isPresentingDeniedAlert) {
                Button("Open Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button("OK", role: .cancel) {}
            }
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

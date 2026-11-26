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
    @State private var importFailure: String?

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
            Section {
                ForEach(system.containers) { container in
                    NavigationLink {
                        ContainerView(container: container, dismissSettings: dismiss)
                    } label: {
                        Label {
                            Text(verbatim: container.metadata.name)
                        } icon: {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .opacity(container.id == system.activeContainerID ? 1 : 0)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Containers")
                    Spacer()
                    Menu {
                        Button {
                            isCreatingContainer = true
                        } label: {
                            Label("Create", systemImage: "plus")
                        }
                        Button {
                            isImportingContainer = true
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("New Container"))
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
        .fileImporter(isPresented: $isImportingContainer, allowedContentTypes: SetupView.supportedArchiveTypes) { result in
            do {
                try system.install(.importArchive(result.get()))
            } catch {
                importFailure = error.localizedDescription
            }
        }
        .alert("Can’t Create Container", isPresented: Binding {
            importFailure != nil
        } set: { presented in
            if !presented {
                importFailure = nil
            }
        }, presenting: importFailure) { _ in
        } message: { failure in
            Text(failure)
        }
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

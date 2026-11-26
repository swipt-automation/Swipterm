import SwiftUI
import UIKit

struct SettingsView: View {
    // SwiptermKit refuses to boot a machine with more than 8 vCPUs.
    private static let cpuLimits = Array(1 ... min(ProcessInfo.processInfo.activeProcessorCount, 8))
    private static let memoryLimits = ([512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384] as [UInt64])
        .map { $0 << 20 }
        .filter { $0 < ProcessInfo.processInfo.physicalMemory }

    private let system = LinuxSystem.shared
    @Bindable private var settings = AppSettings.shared
    @Bindable private var location = HostLocation.shared

    @Environment(\.dismiss) private var dismiss
    @State private var newContainerDraft = SetupDraft()
    @State private var isCreatingContainer = false
    @State private var isImportingContainer = false

    var body: some View {
        Form {
            Section {
                Picker("CPU Limit", selection: $settings.cpuLimit) {
                    Text("No Limit")
                        .tag(Int?.none)
                    ForEach(Self.cpuLimits, id: \.self) { count in
                        Text(count, format: .number)
                            .tag(Int?.some(count))
                    }
                }
                Picker("Memory Limit", selection: $settings.memoryLimit) {
                    Text("No Limit")
                        .tag(UInt64?.none)
                    ForEach(Self.memoryLimits, id: \.self) { size in
                        Text(Int64(size), format: .byteCount(style: .memory))
                            .tag(UInt64?.some(size))
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
                if let runtimeEngine = system.runtimeEngine, runtimeEngine != settings.engineConfiguration {
                    Button("Restart to Apply") {
                        dismiss()
                        system.restart()
                    }
                }
            } header: {
                Text("Engine")
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
            if let url = try? result.get() {
                system.install(.importArchive(url))
            }
        }
        .alert("No Location Access", isPresented: $location.isPresentingDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
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

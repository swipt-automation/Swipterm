import SwiftUI
import UIKit

struct SettingsView: View {
    private let system = LinuxSystem.shared
    private let settings = AppSettings.shared
    @Bindable private var location = HostLocation.shared

    @Environment(\.dismiss) private var dismiss
    @State private var dataSize: Int64?
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            if system.installedContainer != nil {
                Section("Container") {
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
                    LabeledContent("Data Size") {
                        if let dataSize {
                            Text(dataSize.formatted(.byteCount(style: .file)))
                        }
                    }
                    Button("Reset", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .confirmationDialog("Reset Container?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) {
                            dismiss()
                            system.reset()
                        }
                    }
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
        .task {
            guard system.installedContainer != nil else { return }
            dataSize = await Task.detached(priority: .utility) { LinuxSystem.containerDataSize() }.value
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

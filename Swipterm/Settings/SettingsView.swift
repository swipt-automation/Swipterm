import SwiftUI
import SwiptermKit
import UIKit

struct SettingsView: View {
    // SwiptermKit refuses to boot a machine with more than 8 vCPUs.
    private static let cpuLimits = Array(1 ... min(ProcessInfo.processInfo.activeProcessorCount, 8))
    private static let memoryLimits = ([512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384] as [UInt64])
        .map { $0 << 20 }
        .filter { $0 < ProcessInfo.processInfo.physicalMemory }
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
            Section {
                LimitSliderRow(
                    title: "CPU Limit",
                    selection: $settings.cpuLimit,
                    limits: Self.cpuLimits
                ) { count in
                    Text(count, format: .number)
                }
                LimitSliderRow(
                    title: "Memory Limit",
                    selection: $settings.memoryLimit,
                    limits: Self.memoryLimits
                ) { size in
                    Text(Int64(size), format: .byteCount(style: .memory))
                }
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

private struct LimitSliderRow<Value: BinaryInteger>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value?
    let limits: [Value]
    let formatValue: (Value) -> Text

    @State private var draftIndex: Double?
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title) {
                valueText
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
            slider
        }
        .padding(.vertical, 2)
        .onDisappear {
            if let draftIndex {
                commit(draftIndex)
                self.draftIndex = nil
            }
            isEditing = false
        }
    }

    @ViewBuilder
    private var slider: some View {
        let upperBound = Double(limits.count)
        let binding = Binding<Double> {
            currentIndex
        } set: { newValue in
            if isEditing {
                draftIndex = newValue
            } else {
                commit(newValue)
            }
        }
        if #available(iOS 26.0, *) {
            Slider(
                value: binding,
                in: 0 ... upperBound,
                step: 1,
                label: { Text(title) },
                tick: { SliderTick($0) },
                onEditingChanged: handleEditingChanged
            )
            .accessibilityValue(valueText)
        } else {
            Slider(
                value: binding,
                in: 0 ... upperBound,
                step: 1,
                label: { Text(title) },
                onEditingChanged: handleEditingChanged
            )
            .sensoryFeedback(.selection, trigger: Int(currentIndex.rounded()))
            .accessibilityValue(valueText)
        }
    }

    private var valueText: Text {
        if let value = displayedValue {
            formatValue(value)
        } else {
            Text("No Limit")
        }
    }

    private var currentIndex: Double {
        draftIndex ?? index(for: selection)
    }

    private var displayedValue: Value? {
        if let draftIndex {
            return value(for: draftIndex)
        }
        return selection
    }

    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing
        if editing {
            draftIndex = index(for: selection)
        } else if let draftIndex {
            commit(draftIndex)
            self.draftIndex = nil
        }
    }

    private func commit(_ index: Double) {
        let next = value(for: index)
        if selection != next {
            selection = next
        }
    }

    private func index(for value: Value?) -> Double {
        guard let value else {
            return Double(limits.count)
        }
        if let exact = limits.firstIndex(of: value) {
            return Double(exact)
        }
        if let upper = limits.firstIndex(where: { $0 >= value }) {
            if upper == 0 {
                return 0
            }
            let lowerDistance = value - limits[upper - 1]
            let upperDistance = limits[upper] - value
            return Double(lowerDistance <= upperDistance ? upper - 1 : upper)
        }
        return Double(limits.count)
    }

    private func value(for index: Double) -> Value? {
        let index = Int(index.rounded())
        return index < limits.count ? limits[index] : nil
    }
}

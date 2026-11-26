import SwiftUI

struct ContainerView: View {
    let container: LinuxContainer
    let dismissSettings: DismissAction

    private let system = LinuxSystem.shared

    @Environment(\.dismiss) private var dismiss
    @State private var dataSize: Int64?
    @State private var isConfirmingExport = false
    @State private var isConfirmingDelete = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedArchiveURL: URL?
    @State private var isSavingArchive = false
    @State private var exportFailure: String?

    var body: some View {
        let isActive = container.id == system.activeContainerID
        Form {
            Section {
                if let distribution = container.metadata.distribution {
                    LabeledContent("Distribution") {
                        Text(verbatim: distribution.displayName)
                    }
                }
                LabeledContent("Data Size") {
                    if let dataSize {
                        Text(dataSize.formatted(.byteCount(style: .file)))
                    }
                }
            }
            Section {
                if !isActive {
                    Button("Activate") {
                        dismissSettings()
                        system.activate(container)
                    }
                }
                Button("Export") {
                    if isActive, system.state == .running {
                        isConfirmingExport = true
                    } else {
                        export()
                    }
                }
                .disabled(isActive && system.state == .booting)
                .confirmationDialog("Export Container?", isPresented: $isConfirmingExport, titleVisibility: .visible) {
                    Button("Export") {
                        export()
                    }
                } message: {
                    Text("The container shuts down while it’s exported and restarts afterward.")
                }
                Button("Delete", role: .destructive) {
                    isConfirmingDelete = true
                }
                .confirmationDialog("Delete Container?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        system.delete(container)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: container.metadata.name))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding {
            system.exportProgress != nil
        } set: { _ in }, onDismiss: {
            isSavingArchive = exportedArchiveURL != nil
        }) {
            ExportProgressView(progress: system.exportProgress ?? 1) {
                exportTask?.cancel()
            }
        }
        .fileMover(isPresented: $isSavingArchive, file: exportedArchiveURL) { _ in
            removeExportedArchive()
        } onCancellation: {
            removeExportedArchive()
        }
        .alert("Couldn’t Export Container", isPresented: Binding {
            exportFailure != nil
        } set: { presented in
            if !presented {
                exportFailure = nil
            }
        }) {} message: {
            Text(exportFailure ?? "")
        }
        .task {
            dataSize = await Task.detached(priority: .utility) { LinuxSystem.dataSize(of: container) }.value
        }
    }

    private func export() {
        exportedArchiveURL = nil
        exportTask = Task {
            do {
                exportedArchiveURL = try await system.export(container)
            } catch is CancellationError {
            } catch {
                exportFailure = error.localizedDescription
            }
        }
    }

    private func removeExportedArchive() {
        if let exportedArchiveURL {
            try? FileManager.default.removeItem(at: exportedArchiveURL)
        }
    }
}

private struct ExportProgressView: View {
    let progress: Double
    let onCancel: () -> Void

    @State private var height: CGFloat = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Exporting…")
                .font(.headline)
            ProgressView(value: progress)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(24)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            height = newHeight
        }
        .presentationDetents([.height(height)])
        .interactiveDismissDisabled()
        .modifier(FittedPresentationModifier())
    }
}

private struct FittedPresentationModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .presentationSizing(.fitted)
        } else {
            content
        }
    }
}

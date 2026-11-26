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
    @State private var isPresentingExportFailure = false

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
            Section("Actions") {
                if !isActive {
                    Button("Activate") {
                        dismissSettings()
                        system.activate(container)
                    }
                }
                Button("Export") {
                    isConfirmingExport = true
                }
                .disabled(isActive && system.state == .booting)
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
        .alert("Export Container?", isPresented: $isConfirmingExport) {
            Button("Export") {
                export()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isActive, system.state == .running {
                Text("Exporting takes a long time. The container shuts down during the export and restarts afterward.")
            } else {
                Text("Exporting takes a long time.")
            }
        }
        .background {
            ExportProgressAlert(containerName: container.metadata.name, progress: system.exportProgress) {
                exportTask?.cancel()
            } onDismiss: {
                isSavingArchive = exportedArchiveURL != nil
                isPresentingExportFailure = exportFailure != nil
            }
        }
        .fileMover(isPresented: $isSavingArchive, file: exportedArchiveURL) { result in
            if case let .failure(error) = result {
                try! FileManager.default.removeItem(at: exportedArchiveURL!)
                exportFailure = error.localizedDescription
                isPresentingExportFailure = true
            }
        } onCancellation: {
            try! FileManager.default.removeItem(at: exportedArchiveURL!)
        }
        .alert("Couldn’t Export Container", isPresented: $isPresentingExportFailure, presenting: exportFailure) { _ in
        } message: { failure in
            Text(failure)
        }
        .task {
            dataSize = await Task.detached(priority: .utility) { LinuxSystem.dataSize(of: container) }.value
        }
    }

    private func export() {
        exportedArchiveURL = nil
        exportFailure = nil
        exportTask = Task {
            do {
                exportedArchiveURL = try await system.export(container)
            } catch is CancellationError {
            } catch {
                exportFailure = error.localizedDescription
            }
        }
    }
}

private struct ExportProgressAlert: UIViewControllerRepresentable {
    let containerName: String
    let progress: Double?
    let onCancel: () -> Void
    let onDismiss: () -> Void

    final class Coordinator {
        var alert: ProgressAlert?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context _: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let progress else {
            if let alert = context.coordinator.alert {
                context.coordinator.alert = nil
                alert.controller.dismiss(animated: true, completion: onDismiss)
            }
            return
        }
        if let alert = context.coordinator.alert {
            alert.update(progress)
        } else {
            let alert = ProgressAlert(title: String(localized: "Exporting \(containerName)…"), onCancel: onCancel)
            alert.update(progress)
            context.coordinator.alert = alert
            controller.present(alert.controller, animated: true)
        }
    }
}

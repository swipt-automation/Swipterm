import SwiftUI

struct ContainerView: View {
    let container: LinuxContainer
    let dismissSettings: DismissAction

    @Environment(LinuxSystem.self) private var system
    @Environment(ContainerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var dataSize: Int64?
    @State private var isConfirmingExport = false
    @State private var isConfirmingDelete = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedArchiveURL: URL?
    @State private var isSavingArchive = false
    @State private var failure: Failure?

    private struct Failure {
        let title: LocalizedStringKey
        let message: String
    }

    var body: some View {
        let isActive = container.id == store.activeContainerID
        let occupancy = store.occupancy(of: container.id)
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
                if let occupancy {
                    LabeledContent("Status") {
                        switch occupancy {
                        case let .mounted(path, readOnly):
                            if readOnly {
                                Text("Mounted Read-Only at \(Text(verbatim: path))")
                            } else {
                                Text("Mounted at \(Text(verbatim: path))")
                            }
                        case .entered, .exporting:
                            ContainerOccupancyText(occupancy: occupancy)
                        }
                    }
                }
            }
            Section("Actions") {
                if !isActive {
                    Button("Activate") {
                        dismissSettings()
                        system.activate(container)
                    }
                    .disabled(occupancy != nil)
                }
                Button("Export") {
                    isConfirmingExport = true
                }
                .disabled(occupancy != nil || (isActive && system.state == .booting))
                Button("Delete", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(occupancy != nil)
                .confirmationDialog("Delete Container?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        do {
                            try system.delete(container)
                            dismiss()
                        } catch {
                            failure = Failure(title: "Couldn’t Delete Container", message: error.localizedDescription)
                        }
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
            ExportProgressAlert(containerName: container.metadata.name, progress: store.exportProgress[container.id]) {
                exportTask?.cancel()
            } onDismiss: {
                isSavingArchive = exportedArchiveURL != nil
            }
        }
        .fileMover(isPresented: $isSavingArchive, file: exportedArchiveURL) { result in
            if case let .failure(error) = result {
                try! FileManager.default.removeItem(at: exportedArchiveURL!)
                failure = Failure(title: "Couldn’t Export Container", message: error.localizedDescription)
            }
        } onCancellation: {
            try! FileManager.default.removeItem(at: exportedArchiveURL!)
        }
        .alert(failure?.title ?? "", isPresented: Binding {
            failure != nil && store.exportProgress[container.id] == nil
        } set: { presented in
            if !presented {
                failure = nil
            }
        }, presenting: failure) { _ in
        } message: { failure in
            Text(failure.message)
        }
        .task {
            dataSize = await Task.detached(priority: .utility) { ContainerStore.dataSize(of: container) }.value
        }
    }

    private func export() {
        exportedArchiveURL = nil
        failure = nil
        exportTask = Task {
            do {
                exportedArchiveURL = try await system.export(container)
            } catch is CancellationError {
            } catch {
                failure = Failure(title: "Couldn’t Export Container", message: error.localizedDescription)
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

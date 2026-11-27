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
    @State private var isPresentingFailure = false
    @State private var isPresentingExportAlert = false

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
                switch occupancy {
                case let .mounted(path, readOnly):
                    LabeledContent("Status") {
                        if readOnly {
                            Text("Mounted Read-Only at \(Text(verbatim: path))")
                        } else {
                            Text("Mounted at \(Text(verbatim: path))")
                        }
                    }
                case .entered:
                    LabeledContent("Status") {
                        ContainerOccupancyText(occupancy: occupancy)
                    }
                case .exporting, nil:
                    EmptyView()
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
                            isPresentingFailure = true
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
                isPresentingExportAlert = false
                isSavingArchive = exportedArchiveURL != nil
                isPresentingFailure = failure != nil
            }
        }
        .onChange(of: store.exportProgress[container.id] != nil) { _, active in
            if active {
                isPresentingExportAlert = true
            }
        }
        .interactiveDismissDisabled(store.exportProgress[container.id] != nil || isPresentingExportAlert)
        .fileMover(isPresented: $isSavingArchive, file: exportedArchiveURL) { result in
            if case let .failure(error) = result {
                try! FileManager.default.removeItem(at: exportedArchiveURL!)
                failure = Failure(title: "Couldn’t Export Container", message: error.localizedDescription)
                isPresentingFailure = true
            }
        } onCancellation: {
            try! FileManager.default.removeItem(at: exportedArchiveURL!)
        }
        .alert(failure?.title ?? "", isPresented: $isPresentingFailure, presenting: failure) { _ in
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
        isPresentingFailure = false
        exportTask = Task {
            do {
                exportedArchiveURL = try await system.export(container)
            } catch is CancellationError {
            } catch {
                failure = Failure(title: "Couldn’t Export Container", message: error.localizedDescription)
                if !isPresentingExportAlert {
                    isPresentingFailure = true
                }
            }
        }
    }
}

private struct ExportProgressAlert: UIViewControllerRepresentable {
    let containerName: String
    let progress: Double?
    let onCancel: () -> Void
    let onDismiss: () -> Void

    final class Presenter: UIViewController {
        var alert: ProgressAlert?
        var didPresent = false
        var isPresenting = false
        var pendingDismiss = false
        var onDismiss: () -> Void = {}

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentAlertIfNeeded()
        }

        func presentAlertIfNeeded() {
            guard let alert, !didPresent, !isPresenting, !pendingDismiss else {
                return
            }
            var host: UIViewController = self
            while let parent = host.parent {
                host = parent
            }
            guard host.viewIfLoaded?.window != nil else {
                return
            }
            if let presented = host.presentedViewController {
                presented.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.presentAlertIfNeeded()
                }
                return
            }
            didPresent = true
            isPresenting = true
            host.present(alert.controller, animated: true) { [weak self] in
                guard let self else { return }
                isPresenting = false
                if pendingDismiss {
                    finishDismiss()
                }
            }
        }

        func dismissAlert() {
            guard alert != nil else { return }
            if isPresenting {
                pendingDismiss = true
                return
            }
            finishDismiss()
        }

        private func finishDismiss() {
            pendingDismiss = false
            didPresent = false
            guard let alert else { return }
            self.alert = nil
            if alert.controller.presentingViewController != nil {
                alert.controller.dismiss(animated: true, completion: onDismiss)
            } else {
                onDismiss()
            }
        }
    }

    func makeUIViewController(context _: Context) -> Presenter {
        Presenter()
    }

    func updateUIViewController(_ presenter: Presenter, context _: Context) {
        presenter.onDismiss = onDismiss
        guard let progress else {
            presenter.dismissAlert()
            return
        }
        if let alert = presenter.alert {
            alert.update(progress)
        } else {
            let alert = ProgressAlert(title: String(localized: "Exporting \(containerName)…"), onCancel: onCancel)
            alert.update(progress)
            presenter.alert = alert
            presenter.didPresent = false
            presenter.pendingDismiss = false
        }
        presenter.presentAlertIfNeeded()
    }
}

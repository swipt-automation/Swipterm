import SwiftUI
import SwiptermKit

struct BootFailurePromptModifier: ViewModifier {
    private let system = LinuxSystem.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding {
                if case let .failed(failure) = system.state {
                    failure
                } else {
                    nil
                }
            } set: { _ in }) { failure in
                BootFailureSheet(failure: failure)
            }
    }
}

private struct BootFailureSheet: View {
    private enum Route: Hashable {
        case kernels
        case containers
        case createContainer
    }

    let failure: LinuxSystem.BootFailure

    @State private var path: [Route] = []
    @State private var formHeight: CGFloat?
    @State private var kernelsHeight: CGFloat?
    @State private var containersHeight: CGFloat?
    @State private var createContainerHeight: CGFloat?
    @State private var navBarHeight: CGFloat = 56
    @State private var newContainerDraft = SetupDraft()
    @State private var isImportingContainer = false

    private var activeDetents: Set<PresentationDetent> {
        let height = switch path.last {
        case .kernels: kernelsHeight
        case .containers: containersHeight
        case .createContainer: createContainerHeight
        case nil: formHeight
        }
        if let height {
            return [.height(height)]
        }
        return [.medium]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Text(verbatim: failure.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Actions") {
                    if !failure.kernelAlternatives.isEmpty {
                        NavigationLink(value: Route.kernels) {
                            Label("Other Kernels…", systemImage: "cpu")
                        }
                    }

                    NavigationLink(value: Route.containers) {
                        Label("Other Containers…", systemImage: "shippingbox")
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(12)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(FormHeightReaderModifier(formHeight: $formHeight, navBarHeight: $navBarHeight))
            .navigationTitle("Couldn’t Start Linux")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .kernels:
                    BootRecoveryKernelsView(releases: failure.kernelAlternatives)
                        .modifier(FormHeightReaderModifier(formHeight: $kernelsHeight, navBarHeight: $navBarHeight))
                case .containers:
                    BootRecoveryContainersView {
                        path.append(.createContainer)
                    } onImport: {
                        isImportingContainer = true
                    }
                    .modifier(FormHeightReaderModifier(formHeight: $containersHeight, navBarHeight: $navBarHeight))
                    .modifier(ContainerImporterModifier(isPresented: $isImportingContainer))
                case .createContainer:
                    SetupView(draft: $newContainerDraft)
                        .modifier(FormHeightReaderModifier(formHeight: $createContainerHeight, navBarHeight: $navBarHeight))
                }
            }
        }
        .presentationDetents(activeDetents)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }
}

private struct BootRecoveryKernelsView: View {
    let releases: [String]

    var body: some View {
        Form {
            ForEach(releases, id: \.self) { release in
                Button {
                    LinuxSystem.shared.restart(kernel: .release(release))
                } label: {
                    Text(verbatim: release)
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Other Kernels")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BootRecoveryContainersView: View {
    let onCreate: () -> Void
    let onImport: () -> Void

    private let system = LinuxSystem.shared

    var body: some View {
        Form {
            ContainerListSection(onCreate: onCreate, onImport: onImport) { container in
                Button {
                    system.activate(container)
                } label: {
                    Text(verbatim: container.metadata.name)
                }
                .disabled(container.id == system.activeContainerID)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Other Containers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

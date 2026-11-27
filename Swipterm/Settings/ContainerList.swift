import SwiftUI
import UniformTypeIdentifiers

enum ContainerRoute: Hashable {
    case container(String)
    case creation(String)
    case newContainer
}

struct ContainerListSection<Row: View>: View {
    let onCreate: () -> Void
    let onImport: () -> Void
    let onOpenCreation: (ContainerCreation) -> Void
    @ViewBuilder let row: (LinuxContainer) -> Row

    @Environment(ContainerStore.self) private var store

    var body: some View {
        Section {
            ForEach(store.containers, content: row)
            ForEach(store.creations) { creation in
                Button {
                    onOpenCreation(creation)
                } label: {
                    LabeledContent {
                        if creation.state == .running {
                            Text("Initializing…")
                        } else {
                            Text("Failed")
                        }
                    } label: {
                        Text(verbatim: creation.name)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            HStack {
                Text("Containers")
                Spacer()
                Menu {
                    Button(action: onCreate) {
                        Label("Create", systemImage: "plus")
                    }
                    Button(action: onImport) {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("New Container"))
            }
        }
    }
}

struct ContainerLabel: View {
    let container: LinuxContainer

    @Environment(ContainerStore.self) private var store

    var body: some View {
        LabeledContent {
            ContainerOccupancyText(occupancy: store.occupancy(of: container.id))
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: container.metadata.name)
                    .lineLimit(1)
                if container.id == store.activeContainerID {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .fixedSize()
                }
            }
        }
    }
}

struct ContainerOccupancyText: View {
    let occupancy: ContainerOccupancy?

    var body: some View {
        switch occupancy {
        case .mounted:
            Text("Mounted")
        case .entered:
            Text("In Use")
        case .exporting:
            Text("Exporting…")
        case nil:
            EmptyView()
        }
    }
}

struct ContainerDestinationModifier: ViewModifier {
    @Binding var path: [ContainerRoute]
    let dismissSettings: DismissAction

    @Environment(ContainerStore.self) private var store
    @State private var draft = SetupDraft()
    @State private var followed: ContainerCreation?

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: ContainerRoute.self) { route in
                switch route {
                case let .container(id):
                    if let container = store.containers.first(where: { $0.id == id }) {
                        ContainerView(container: container, dismissSettings: dismissSettings)
                    }
                case let .creation(id):
                    if let creation = store.creations.first(where: { $0.id == id }) {
                        ProvisioningView(creation: creation)
                            .id(creation.attempt)
                    }
                case .newContainer:
                    SetupView(draft: $draft) { creation in
                        draft = SetupDraft()
                        path = path.dropLast() + [.creation(creation.id)]
                    }
                }
            }
            .onChange(of: path, initial: true) { _, path in
                if case let .creation(id) = path.last,
                   let creation = store.creations.first(where: { $0.id == id })
                {
                    followed = creation
                }
            }
            .onChange(of: store.creations.map(\.id)) { _, ids in
                guard case let .creation(id) = path.last, !ids.contains(id) else { return }
                if let followed, followed.id == id, case let .finished(container) = followed.state {
                    path = path.dropLast() + [.container(container.id)]
                } else {
                    path.removeLast()
                }
            }
    }
}

struct ContainerImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onCreated: (ContainerCreation) -> Void

    @Environment(LinuxSystem.self) private var system
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data]) { result in
                do {
                    if let creation = try system.create(.importArchive(result.get())) {
                        onCreated(creation)
                    }
                } catch {
                    failure = error.localizedDescription
                }
            }
            .alert("Can’t Create Container", isPresented: Binding {
                failure != nil
            } set: { presented in
                if !presented {
                    failure = nil
                }
            }, presenting: failure) { _ in
            } message: { failure in
                Text(failure)
            }
    }
}

import SwiftUI

struct ContainerListSection<Row: View>: View {
    let onCreate: () -> Void
    let onImport: () -> Void
    @ViewBuilder let row: (LinuxContainer) -> Row

    var body: some View {
        Section {
            ForEach(LinuxSystem.shared.containers, content: row)
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

    var body: some View {
        Label {
            Text(verbatim: container.metadata.name)
        } icon: {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(container.id == LinuxSystem.shared.activeContainerID ? 1 : 0)
        }
    }
}

struct ContainerImporterModifier: ViewModifier {
    @Binding var isPresented: Bool

    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: SetupView.supportedArchiveTypes) { result in
                do {
                    try LinuxSystem.shared.install(.importArchive(result.get()))
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

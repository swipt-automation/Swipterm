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
        HStack(spacing: 8) {
            Text(verbatim: container.metadata.name)
                .lineLimit(1)
            if container.id == LinuxSystem.shared.activeContainerID {
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

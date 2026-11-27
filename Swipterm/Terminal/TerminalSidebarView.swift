import SwiftUI

struct TerminalSidebarView: View {
    let sessionManager: TerminalSessionManager
    let onSelectSession: () -> Void
    let onOpenSettings: () -> Void
    let onManageShortcuts: () -> Void

    var body: some View {
        ScrollView {
            ReorderableSessionStack(sessionManager: sessionManager, axis: .vertical, spacing: 4) { session in
                TerminalSidebarRow(
                    session: session,
                    isSelected: session.id == sessionManager.activeSessionID,
                    onSelect: {
                        sessionManager.activeSessionID = session.id
                        onSelectSession()
                    },
                    onClose: {
                        sessionManager.closeSession(id: session.id)
                    }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(SettingsButtonChromeModifier())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(Text(verbatim: "Swipterm"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button {
                            sessionManager.addSession()
                            onSelectSession()
                        } label: {
                            Label("New Terminal", systemImage: "plus")
                        }
                        ForEach(sessionManager.services.settings.shortcuts) { shortcut in
                            Button {
                                sessionManager.addSession(shortcut: shortcut)
                                onSelectSession()
                            } label: {
                                Label {
                                    Text(verbatim: shortcut.name)
                                } icon: {
                                    Image(systemName: shortcut.symbolName)
                                }
                            }
                        }
                    }
                    Section {
                        Button(action: onManageShortcuts) {
                            Label("Manage Shortcuts", systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
        }
    }
}

private struct SettingsButtonChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
        }
    }
}

private struct TerminalSidebarRow: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(session.title)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(Text("Close Session"))
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.11))
            }
        }
        .drawingGroup()
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

import SwiftUI
import UIKit

struct TerminalSidebarView: View {
    private static let buttonSize: CGFloat = 44
    private static let edgeMargin: CGFloat = 16

    let sessionManager: TerminalSessionManager
    let onSelectSession: () -> Void
    let onOpenSettings: () -> Void
    let onManageShortcuts: () -> Void

    @State private var leadingCornerRadius: CGFloat = 0
    @State private var trailingCornerRadius: CGFloat = 0

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
        .contentMargins(.bottom, Self.buttonSize + Self.edgeMargin, for: .scrollContent)
        .overlay {
            bottomButtons
        }
        .navigationTitle(Text(verbatim: "Swipterm"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        NewSessionMenuItems(sessionManager: sessionManager, onAdd: onSelectSession)
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

    @ViewBuilder
    private var bottomButtons: some View {
        let buttons = HStack {
            SidebarButton(symbol: "gearshape", label: "Settings", size: Self.buttonSize, action: onOpenSettings)
            Spacer()
            SidebarButton(symbol: "power", label: "Shut Down", size: Self.buttonSize, action: sessionManager.services.system.shutDown)
        }
        if #available(iOS 26.0, *) {
            let leadingInset = Self.cornerInset(radius: leadingCornerRadius)
            let trailingInset = Self.cornerInset(radius: trailingCornerRadius)
            buttons
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.bottom, max(leadingInset, trailingInset))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .background {
                    SidebarCornerReader { leading, trailing in
                        leadingCornerRadius = leading
                        trailingCornerRadius = trailing
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
            buttons
                .padding(.horizontal, Self.edgeMargin)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private static func cornerInset(radius: CGFloat) -> CGFloat {
        let buttonRadius = buttonSize / 2
        let excess = max(0, radius - buttonRadius - edgeMargin)
        return edgeMargin + excess * (1 - 0.5.squareRoot())
    }
}

struct NewSessionMenuItems: View {
    let sessionManager: TerminalSessionManager
    let onAdd: () -> Void

    var body: some View {
        Button {
            sessionManager.addSession()
            onAdd()
        } label: {
            Label("New Terminal", systemImage: "plus")
        }
        ForEach(sessionManager.services.settings.shortcuts) { shortcut in
            Button {
                sessionManager.addSession(shortcut: shortcut)
                onAdd()
            } label: {
                Label {
                    Text(verbatim: shortcut.name)
                } icon: {
                    Image(systemName: shortcut.symbolName)
                }
            }
        }
    }
}

private struct SidebarButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let icon = Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
            if #available(iOS 26.0, *) {
                icon
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            } else {
                icon
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

@available(iOS 26.0, *)
private struct SidebarCornerReader: UIViewRepresentable {
    let onChange: (CGFloat, CGFloat) -> Void

    func makeUIView(context _: Context) -> View {
        View(onChange: onChange)
    }

    func updateUIView(_ view: View, context _: Context) {
        view.onChange = onChange
    }

    final class View: UIView {
        var onChange: (CGFloat, CGFloat) -> Void
        private var lastLeading: CGFloat = -1
        private var lastTrailing: CGFloat = -1

        init(onChange: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            cornerConfiguration = .corners(radius: .containerConcentric())
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let leading = effectiveRadius(corner: isRTL ? .bottomRight : .bottomLeft)
            let trailing = effectiveRadius(corner: isRTL ? .bottomLeft : .bottomRight)
            guard leading != lastLeading || trailing != lastTrailing else { return }
            lastLeading = leading
            lastTrailing = trailing
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange(lastLeading, lastTrailing)
            }
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

import SwiftUI

struct TerminalTabBar: View {
    let sessionManager: TerminalSessionManager
    let showsActiveSessionOnly: Bool
    let columnWidth: CGFloat

    private static let maximumVisibleTabs = 5
    private static let height: CGFloat = 44
    private static let padding: CGFloat = 3
    private static let spacing: CGFloat = 2

    @State private var edgeScroller = TabEdgeScroller()

    var body: some View {
        GeometryReader { viewport in
            if showsActiveSessionOnly {
                activeSessionLabel
            } else {
                tabStrip(width: viewport.size.width)
            }
        }
        // UIKit measures the title view before allocating space beside its buttons.
        .frame(minWidth: 0, idealWidth: columnWidth, maxWidth: columnWidth)
        .frame(height: Self.height)
        .background { tabBarBackground }
    }

    @ViewBuilder private var tabBarBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }

    private var activeSessionLabel: some View {
        HStack(spacing: 6) {
            Text(sessionManager.activeSession?.title ?? "")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height - Self.padding * 2)
        .padding(Self.padding)
    }

    private func tabStrip(width: CGFloat) -> some View {
        let visibleCount = CGFloat(min(sessionManager.sessions.count, Self.maximumVisibleTabs))
        let tabWidth = max((width - Self.padding * 2 - Self.spacing * (visibleCount - 1)) / visibleCount, 0)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ReorderableSessionStack(
                    sessionManager: sessionManager,
                    axis: .horizontal,
                    spacing: Self.spacing,
                    edgeScroller: edgeScroller
                ) { session in
                    TerminalTabItem(
                        session: session,
                        isSelected: session.id == sessionManager.activeSessionID,
                        onSelect: { sessionManager.activeSessionID = session.id },
                        onClose: { sessionManager.closeSession(id: session.id) }
                    )
                    .frame(width: tabWidth, height: Self.height - Self.padding * 2)
                    .contentShape(.dragPreview, Capsule())
                    .id(session.id)
                }
                .background { TabScrollContentAnchor(scroller: edgeScroller).allowsHitTesting(false) }
                .padding(Self.padding)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onDisappear { edgeScroller.stop() }
            .onChange(of: width, initial: true) {
                if let activeSessionID = sessionManager.activeSessionID {
                    proxy.scrollTo(activeSessionID)
                }
            }
            .onChange(of: sessionManager.activeSessionID) { _, newID in
                guard let newID else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }
}

private struct TerminalTabItem: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.subheadline.weight(isSelected ? .medium : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.leading, 12)
                .frame(maxHeight: .infinity)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .accessibilityLabel(Text("Close Session"))
        }
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.primary.opacity(0.11))
            }
        }
        .drawingGroup()
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct ReorderableSessionStack<Content: View>: View {
    let sessionManager: TerminalSessionManager
    let axis: Axis
    let spacing: CGFloat
    var edgeScroller: TabEdgeScroller? = nil
    @ViewBuilder let content: (TerminalSession) -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        if #available(iOS 27.0, *) {
            let container = stack {
                ForEach(sessionManager.sessions, content: content)
                    .reorderable()
            }
            .reorderContainer(for: TerminalSession.self) { difference in
                switch difference.destination.position {
                case let .before(id):
                    sessionManager.moveSessions(difference.sources, before: id)
                case .end:
                    sessionManager.moveSessions(difference.sources, before: nil)
                }
            }
            if let edgeScroller {
                container.onDropSessionUpdated { drop in
                    switch drop.phase {
                    case .entering, .active:
                        if drop.localSession != nil {
                            edgeScroller.update(at: drop.location)
                        }
                    default:
                        edgeScroller.stop()
                    }
                }
            } else {
                container
            }
        } else if let edgeScroller {
            stack {
                ForEach(sessionManager.sessions) { session in
                    content(session).draggable(SessionDrag(id: session.id))
                }
            }
            .onDrop(of: [SessionDrag.contentType], delegate: LegacyTabDrop(
                edgeScroller: edgeScroller,
                sessionManager: sessionManager,
                spacing: spacing,
                layoutDirection: layoutDirection
            ))
        } else {
            stack {
                ForEach(sessionManager.sessions) { session in
                    content(session)
                        .draggable(SessionDrag(id: session.id))
                        .dropDestination(for: SessionDrag.self) { items, _ in
                            withAnimation {
                                sessionManager.moveSessions(Set(items.map(\.id)), onto: session.id)
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func stack(@ViewBuilder items: () -> some View) -> some View {
        if axis == .horizontal {
            HStack(spacing: spacing, content: items)
        } else {
            LazyVStack(spacing: spacing, content: items)
        }
    }
}

nonisolated struct SessionDrag: Codable, Transferable {
    let id: UUID
    static let contentType = UTType(exportedAs: "io.nekohasekai.swipterm.session", conformingTo: .item)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
            .visibility(.ownProcess)
    }
}

import SwiftUI

struct LegacyTabDrop: DropDelegate {
    let edgeScroller: TabEdgeScroller
    let sessionManager: TerminalSessionManager
    let spacing: CGFloat
    let layoutDirection: LayoutDirection

    func dropEntered(info: DropInfo) {
        edgeScroller.update(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edgeScroller.update(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        edgeScroller.stop()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { edgeScroller.stop() }
        let providers = info.itemProviders(for: [SessionDrag.contentType])
        let order = sessionManager.sessions.map(\.id)
        let width = edgeScroller.contentWidth

        let x = layoutDirection == .rightToLeft ? width - info.location.x : info.location.x
        let pitch = (width + spacing) / CGFloat(order.count)
        let target = Int(min(max((x + spacing / 2) / pitch, 0), CGFloat(order.count - 1)))

        var pending = providers.count
        var dragged = Set<UUID>()
        let receive: @MainActor @Sendable (SessionDrag) -> Void = { item in
            dragged.insert(item.id)
            pending -= 1
            guard pending == 0, !dragged.contains(order[target]),
                  let source = order.firstIndex(where: dragged.contains)
            else { return }
            let insertion = source < target ? target + 1 : target
            let nextID = order[insertion...].first { !dragged.contains($0) }
            withAnimation {
                sessionManager.moveSessions(order.filter(dragged.contains), before: nextID)
            }
        }

        for provider in providers {
            _ = provider.loadTransferable(type: SessionDrag.self) { result in
                Task { @MainActor in receive(try! result.get()) }
            }
        }
        return true
    }
}

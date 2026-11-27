import SwiftUI
import UIKit

final class TabEdgeScroller: NSObject {
    fileprivate weak var contentView: UIView?
    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var velocity: CGFloat = 0
    private var offset: CGFloat = 0

    var contentWidth: CGFloat {
        contentView!.bounds.width
    }

    func update(at location: CGPoint) {
        guard let contentView, let scrollView = enclosingScrollView(of: contentView) else {
            stop()
            return
        }
        let point = contentView.convert(location, to: scrollView)
        let bounds = scrollView.bounds
        let speed = Self.speed(at: point.x - bounds.minX, width: bounds.width)
        guard point.y >= bounds.minY, point.y <= bounds.maxY, speed != 0 else {
            stop()
            return
        }
        if displayLink == nil || velocity.sign != speed.sign {
            offset = scrollView.contentOffset.x
        }
        self.scrollView = scrollView
        velocity = speed
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        velocity = 0
    }

    private func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func speed(at x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, x >= 0, x <= width else { return 0 }
        let band = min(64, width / 4)
        let distance = min(x, width - x)
        guard distance < band else { return 0 }
        let depth = 1 - distance / band
        return (x < width / 2 ? -520 : 520) * depth * depth
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, contentView?.window != nil else {
            stop()
            return
        }
        let left = -scrollView.adjustedContentInset.left
        let right = max(left, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
        let next = offset + velocity * (link.targetTimestamp - link.timestamp)
        let current = scrollView.contentOffset
        offset = min(right, max(left, velocity > 0 ? max(current.x, next) : min(current.x, next)))
        if offset != current.x {
            scrollView.setContentOffset(CGPoint(x: offset, y: current.y), animated: false)
        }
        if velocity < 0 ? offset <= left : offset >= right {
            stop()
        }
    }
}

struct TabScrollContentAnchor: UIViewRepresentable {
    let scroller: TabEdgeScroller

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        scroller.contentView = view
        return view
    }

    func updateUIView(_: UIView, context _: Context) {}
}

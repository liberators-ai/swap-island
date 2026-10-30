import CoreGraphics

/// Screen-space rectangles for the island. Pure, so the hit-testing is testable without a window.
///
/// The closed island adds one equal wing on each side of the notch, so it stays centered. The open
/// panel folds both wings away, hangs below the menu bar, and joins the notch through a neck of the
/// notch's width, so opening it covers no menu bar icon.
public struct NotchGeometry: Sendable, Equatable {
    public static let wingWidth: CGFloat = 28
    public static let fallbackSize = CGSize(width: 150, height: 28)
    /// The gap under the menu bar, bridged by the neck's flared shoulders.
    public static let shoulderDrop: CGFloat = 9

    public let screen: CGRect
    public let notchRect: CGRect

    /// `topInset` and the two auxiliary widths come from NSScreen. Everything centers on the notch
    /// they describe, not on the screen, because the two widths can differ (665 and 662 on a 14-inch
    /// MacBook Pro). A screen without a notch gets a virtual one so the island works the same there.
    public init(screen: CGRect, topInset: CGFloat, auxiliaryLeft: CGFloat?, auxiliaryRight: CGFloat?) {
        self.screen = screen
        if topInset > 0, let auxiliaryLeft, let auxiliaryRight {
            notchRect = CGRect(
                x: screen.minX + auxiliaryLeft,
                y: screen.maxY - topInset,
                width: screen.width - auxiliaryLeft - auxiliaryRight,
                height: topInset
            )
        } else {
            notchRect = CGRect(
                x: screen.midX - Self.fallbackSize.width / 2,
                y: screen.maxY - Self.fallbackSize.height,
                width: Self.fallbackSize.width,
                height: Self.fallbackSize.height
            )
        }
    }

    public var notchSize: CGSize { notchRect.size }

    public var closedRect: CGRect {
        CGRect(
            x: notchRect.minX - Self.wingWidth,
            y: notchRect.minY,
            width: notchRect.width + Self.wingWidth * 2,
            height: notchRect.height
        )
    }

    public func panelRect(bodySize: CGSize) -> CGRect {
        CGRect(
            x: notchRect.midX - bodySize.width / 2,
            y: screen.maxY - notchSize.height - Self.shoulderDrop - bodySize.height,
            width: bodySize.width,
            height: bodySize.height
        )
    }

    public func windowFrame(bodySize: CGSize, margin: CGFloat) -> CGRect {
        let height = notchSize.height + Self.shoulderDrop + bodySize.height + margin
        var width = bodySize.width + margin * 2
        // AppKit snaps a window to whole points, which would shift an island centered on a half point.
        if (notchRect.midX - width / 2).rounded() != notchRect.midX - width / 2 { width += 1 }
        return CGRect(x: notchRect.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    public func triggersOpen(at point: CGPoint) -> Bool {
        closedRect.insetBy(dx: 0, dy: -1).contains(point)
    }

    /// `slack` lets a cursor drift past the edge without slamming the panel shut.
    /// It stays below the shoulder drop's worth of menu bar, so reaching for an icon still closes it.
    ///
    /// The folded wings still count here, so a cursor that opened the panel from a wing does not close it again.
    public func isOverIsland(at point: CGPoint, bodySize: CGSize, slack: CGFloat = 0) -> Bool {
        let panel = panelRect(bodySize: bodySize)
        return neck(spanning: closedRect, below: panel).insetBy(dx: 0, dy: -1).contains(point)
            || panel.insetBy(dx: -slack, dy: -slack).contains(point)
    }

    /// The part of the open island that is drawn. Icons beside the neck keep their clicks.
    public func isOverOpenShape(at point: CGPoint, bodySize: CGSize) -> Bool {
        let panel = panelRect(bodySize: bodySize)
        return neck(spanning: notchRect, below: panel).contains(point) || panel.contains(point)
    }

    private func neck(spanning span: CGRect, below panel: CGRect) -> CGRect {
        CGRect(x: span.minX, y: panel.maxY, width: span.width, height: screen.maxY - panel.maxY)
    }
}

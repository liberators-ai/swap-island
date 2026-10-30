import SwiftUI

/// The closed silhouette: flat against the top edge, flaring outward into it at the shoulders,
/// rounded at the bottom like the hardware notch.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// The open panel: a body below the menu bar, joined to the notch by a neck that rises from
/// its top edge, so the menu bar on either side of the neck stays uncovered.
struct PanelShape: Shape {
    var neckLeft: CGFloat
    var neckRight: CGFloat
    var shoulderY: CGFloat
    var fillet: CGFloat
    var topCorner: CGFloat = 16
    var bottomCorner: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: neckLeft, y: 0))
        path.addLine(to: CGPoint(x: neckLeft, y: shoulderY - fillet))
        path.addQuadCurve(
            to: CGPoint(x: neckLeft - fillet, y: shoulderY),
            control: CGPoint(x: neckLeft, y: shoulderY)
        )
        path.addLine(to: CGPoint(x: topCorner, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: 0, y: shoulderY + topCorner), control: CGPoint(x: 0, y: shoulderY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - bottomCorner))
        path.addQuadCurve(to: CGPoint(x: bottomCorner, y: rect.maxY), control: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomCorner, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCorner),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulderY + topCorner))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCorner, y: shoulderY),
            control: CGPoint(x: rect.maxX, y: shoulderY)
        )
        path.addLine(to: CGPoint(x: neckRight + fillet, y: shoulderY))
        path.addQuadCurve(
            to: CGPoint(x: neckRight, y: shoulderY - fillet),
            control: CGPoint(x: neckRight, y: shoulderY)
        )
        path.addLine(to: CGPoint(x: neckRight, y: 0))
        path.closeSubpath()
        return path
    }
}

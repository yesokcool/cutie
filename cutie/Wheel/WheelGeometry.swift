import CoreGraphics
import Foundation

/// The wheel's shape: a ring of equal slices, the first centered at 12 o'clock,
/// going clockwise. Choosing is by direction (a pie menu): anywhere past the
/// center hole picks the slice in that direction, so a flick works.
nonisolated struct WheelGeometry: Equatable, Sendable {
    let count: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    static let margin: CGFloat = 20
    static let footerHeight: CGFloat = 52

    init(count: Int) {
        self.count = count
        // Grow the ring with the slice count so labels keep ~70 pt of arc each.
        let middle = max(112, 11.5 * CGFloat(count))
        innerRadius = middle - 50
        outerRadius = middle + 50
    }

    var sliceAngle: CGFloat { count > 0 ? 2 * .pi / CGFloat(count) : 2 * .pi }

    /// The square the ring is drawn in.
    var wheelSide: CGFloat { 2 * (outerRadius + Self.margin) }

    /// The panel: the ring's square plus the wheel switcher below it.
    var panelSize: CGSize { CGSize(width: wheelSide, height: wheelSide + Self.footerHeight) }

    /// Clockwise from 12 o'clock.
    func centerAngle(of index: Int) -> CGFloat { CGFloat(index) * sliceAngle }

    /// The slice in the direction of `offset` from the center (y up), or nil in the center hole.
    func index(at offset: CGVector) -> Int? {
        guard count > 0 else { return nil }
        let distance = hypot(offset.dx, offset.dy)
        guard distance >= innerRadius * 0.8 else { return nil }
        var angle = atan2(offset.dx, offset.dy) // clockwise from up
        if angle < 0 { angle += 2 * .pi }
        let shifted = (angle + sliceAngle / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(shifted / sliceAngle) % count
    }

    /// A point at `radius` in the direction of slice `index`, in y-down view coordinates around `center`.
    func point(for index: Int, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = centerAngle(of: index)
        return CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }

    /// The slice outline (y-down), with a small gap between neighbours.
    func slicePath(_ index: Int, center: CGPoint, gap: CGFloat = 3) -> CGPath {
        let path = CGMutablePath()
        let middle = centerAngle(of: index)
        let halfOuter = sliceAngle / 2 - gap / outerRadius
        let halfInner = sliceAngle / 2 - gap / innerRadius
        // CGPath angles are counterclockwise from +x in y-up space; in y-down
        // view space "clockwise from 12" maps to (θ − π/2).
        func viewAngle(_ angle: CGFloat) -> CGFloat { angle - .pi / 2 }
        if count == 1 {
            path.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
            path.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
            return path
        }
        path.addArc(center: center, radius: outerRadius, startAngle: viewAngle(middle - halfOuter), endAngle: viewAngle(middle + halfOuter), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: viewAngle(middle + halfInner), endAngle: viewAngle(middle - halfInner), clockwise: true)
        path.closeSubpath()
        return path
    }
}

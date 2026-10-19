import SwiftUI

nonisolated struct SliceShape: Shape {
    let geometry: WheelGeometry
    let index: Int

    func path(in rect: CGRect) -> Path {
        Path(geometry.slicePath(index, center: CGPoint(x: rect.midX, y: rect.midY)))
    }
}

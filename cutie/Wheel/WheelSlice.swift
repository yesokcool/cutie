import SwiftUI

/// One slice: glass in the slice's outline, its symbol and name at the ring's middle.
struct WheelSlice: View {
    let geometry: WheelGeometry
    let index: Int
    let item: WheelItem
    let highlighted: Bool
    let center: CGPoint

    var body: some View {
        let labelPoint = geometry.point(for: index, radius: (geometry.innerRadius + geometry.outerRadius) / 2, center: center)
        ZStack {
            Color.clear
                .cutieGlass(in: SliceShape(geometry: geometry, index: index), tint: highlighted ? .accentColor : nil)
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 16, weight: .medium))
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 78)
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .position(labelPoint)
        }
        .scaleEffect(highlighted ? 1.06 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

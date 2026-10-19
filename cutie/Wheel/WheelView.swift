import SwiftUI

/// The radial menu: a glass ring of slices around a hub showing the file,
/// and the wheel switcher (⇧ Convert · ⌘ Tools · ⌃ Actions) underneath.
struct WheelView: View {
    let model: WheelModel

    var body: some View {
        let geometry = model.geometry
        let side = geometry.wheelSide
        let center = CGPoint(x: side / 2, y: side / 2)

        VStack(spacing: 0) {
            ZStack {
                GlassEffectContainer(spacing: 6) {
                    ZStack {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            WheelSlice(geometry: geometry, index: index, item: item,
                                       highlighted: model.highlighted == index, center: center)
                        }
                    }
                }
                WheelHub(model: model, diameter: (geometry.innerRadius - 10) * 2)
                    .position(center)
            }
            .frame(width: side, height: side)

            WheelSwitcher(model: model)
                .frame(height: WheelGeometry.footerHeight, alignment: .top)
        }
        .frame(width: geometry.panelSize.width, height: geometry.panelSize.height)
        .scaleEffect(model.appeared ? 1 : 0.86, anchor: UnitPoint(x: 0.5, y: side / 2 / geometry.panelSize.height))
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: model.appeared)
        .animation(.snappy(duration: 0.16), value: model.highlighted)
        .animation(.snappy(duration: 0.24), value: model.wheel)
    }
}

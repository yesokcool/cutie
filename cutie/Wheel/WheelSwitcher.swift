import SwiftUI

/// Which wheel is open, and the key for each of the others.
struct WheelSwitcher: View {
    let model: WheelModel

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Wheel.allCases, id: \.self) { wheel in
                    if let key = model.keys[wheel], key != .off {
                        let active = wheel == model.wheel
                        HStack(spacing: 5) {
                            Text(key.glyph).font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(wheel.title).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .cutieGlass(in: Capsule(), tint: active ? .accentColor : nil)
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

import SwiftUI

extension WheelModel {
    /// A HEIC photo's Convert wheel with PNG highlighted, for the welcome window and snapshots.
    static var sample: WheelModel {
        let model = WheelModel()
        model.inputs = [URL(fileURLWithPath: "/Users/Shared/photo.heic")]
        model.items = [Format.jpg, .png, .pdf, .webp, .avif, .tiff, .gif, .bmp].map(WheelItem.convert)
        model.highlighted = 1
        model.appeared = true
        model.keys = Dictionary(uniqueKeysWithValues: Wheel.allCases.map { ($0, Preferences.key(for: $0)) })
        return model
    }
}

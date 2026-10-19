import SwiftUI

/// The center: the file's icon and what dropping here would do.
struct WheelHub: View {
    let model: WheelModel
    let diameter: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            FileIcon(urls: model.inputs)
                .frame(width: 34, height: 34)
            Text(model.highlightedItem?.title ?? model.wheel.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(model.highlightedItem == nil ? model.inputSummary : model.wheel.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(width: diameter, height: diameter)
        .cutieGlass(in: Circle())
        .contentTransition(.opacity)
    }
}

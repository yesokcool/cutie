import SwiftUI

/// The Float shelf: the files' icon and name, and an X.
struct FloatView: View {
    let model: FloatModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            FileIcon(urls: model.files)
                .frame(width: 64, height: 64)
            Text(model.files.count == 1 ? model.files[0].lastPathComponent : "\(model.files.count) files")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
        }
        .frame(width: FloatController.size.width, height: FloatController.size.height)
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            .padding(8)
        }
        .cutieGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

import SwiftUI

extension EnvironmentValues {
    /// Set when a view is rendered to an image (tests): Liquid Glass needs a live
    /// window behind it, so snapshots draw a flat stand-in with the same shape.
    @Entry var isSnapshot = false
}

extension View {
    /// Liquid Glass in `shape`, optionally tinted (the highlighted slice, the active wheel).
    func cutieGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(CutieGlass(shape: shape, tint: tint, interactive: interactive))
    }
}

private struct CutieGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content.background {
                shape.fill(tint ?? Color(nsColor: .windowBackgroundColor).opacity(0.92))
                    .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 1))
            }
        } else {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

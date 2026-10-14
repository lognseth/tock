import SwiftUI

/// Tock requires macOS 26, so every floating surface is Liquid Glass.
/// Glass is for the layer that floats above content (panels, sidebars, bars), not for the content itself.
extension View {
    func tockSurface<S: Shape>(_ shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}

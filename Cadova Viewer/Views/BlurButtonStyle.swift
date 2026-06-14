import SwiftUI

/// A button style for overlay controls drawn on top of the dark 3D viewport: a translucent
/// material capsule that darkens while pressed and dims when disabled.
struct BlurButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        BlurButtonLabel(configuration: configuration)
    }

    // A nested view so the style can read `isEnabled` from the environment and dim accordingly.
    private struct BlurButtonLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(6)
                .background(configuration.isPressed ? .thickMaterial : .ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerSize: CGSize(width: 8, height: 8)))
                .opacity(isEnabled ? 1 : 0.35)
        }
    }
}

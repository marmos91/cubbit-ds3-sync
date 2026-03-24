import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .mask(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .white.opacity(0.4),
                        .white,
                        .white.opacity(0.4)
                    ]),
                    startPoint: .init(x: phase - 0.5, y: 0.5),
                    endPoint: .init(x: phase + 0.5, y: 0.5)
                )
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 2
                }
            }
    }
}

extension View {
    /// Applies a shimmer/skeleton loading effect to the view.
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }

    /// Conditionally applies a shimmer effect when the condition is true.
    @ViewBuilder
    func shimmeringIf(_ condition: Bool) -> some View {
        if condition {
            modifier(ShimmerModifier())
        } else {
            self
        }
    }
}

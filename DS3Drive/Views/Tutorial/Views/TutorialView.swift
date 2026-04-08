import DS3Lib
import SwiftUI

struct TutorialProgress: View {
    var totalSlides: Int

    @Binding var currentSlideIndex: Int

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            ForEach(0 ..< totalSlides, id: \.self) { index in
                Capsule()
                    .fill(index == currentSlideIndex
                        ? DS3Colors.brandPrimary
                        : DS3Colors.brandBorder.opacity(0.6))
                    .frame(width: index == currentSlideIndex ? 20 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: currentSlideIndex)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentSlideIndex = index
                        }
                    }
            }
        }
    }
}

struct TutorialView: View {
    @StateObject private var vm = TutorialViewModel()

    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown

    private var currentSlide: Slide {
        vm.slides[vm.currentSlideIndex]
    }

    var body: some View {
        ZStack {
            // Unified brand backdrop across ALL tutorial slides — no
            // per-slide variation so the tutorial reads as one coherent
            // Cubbit-branded surface.
            DS3Gradients.brandVerticalBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: DS3Spacing.lg)

                VStack(alignment: .center, spacing: DS3Spacing.lg) {
                    // Hero screenshot, bordered with the brand primary tint.
                    Image(currentSlide.imageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    DS3Colors.brandPrimary.opacity(0.2),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                        .id(vm.currentSlideIndex)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))

                    VStack(spacing: DS3Spacing.md) {
                        Text(currentSlide.titleKey)
                            .font(DS3Typography.title)
                            .fontWeight(.bold)
                            .foregroundStyle(DS3Colors.brandTextPrimary)
                            .multilineTextAlignment(.center)

                        Text(currentSlide.descriptionKey)
                            .font(DS3Typography.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(DS3Colors.brandTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 520)
                    }

                    Button(vm.isLastSlide ? "Get Started" : "Next") {
                        if vm.isLastSlide {
                            tutorialShown = true
                        } else {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                vm.nextSlide()
                            }
                        }
                    }
                    .padding(.top, DS3Spacing.xs)
                    .buttonStyle(PrimaryButtonStyle())

                    TutorialProgress(
                        totalSlides: vm.slides.count,
                        currentSlideIndex: $vm.currentSlideIndex
                    )
                }
                .padding(.horizontal, DS3Spacing.xxl)
                .padding(.vertical, DS3Spacing.xl)

                Spacer(minLength: DS3Spacing.lg)
            }
        }
        .frame(width: 720, height: 580)
        .animation(.easeInOut(duration: 0.3), value: vm.currentSlideIndex)
    }
}

#Preview {
    TutorialView()
}

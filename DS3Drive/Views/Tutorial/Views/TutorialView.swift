import DS3Lib
import os.log
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

    @State private var startAtLoginEnabled: Bool = DefaultSettings.appIsLoginItem

    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    private var currentSlide: Slide {
        vm.slides[vm.currentSlideIndex]
    }

    private var isLoginItemSlide: Bool {
        currentSlide.id == TutorialViewModel.loginItemSlideID
    }

    @ViewBuilder private var slideHero: some View {
        if isLoginItemSlide {
            Image(systemName: "power.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                .foregroundStyle(DS3Colors.brandPrimary)
        } else if let imageName = currentSlide.imageName {
            Image(imageName)
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
        }
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
                    slideHero
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

                    if isLoginItemSlide {
                        Toggle(isOn: $startAtLoginEnabled) {
                            Text("tutorial.loginItem.toggle")
                                .font(DS3Typography.body)
                                .foregroundStyle(DS3Colors.brandTextPrimary)
                        }
                        .toggleStyle(.switch)
                        .tint(DS3Colors.brandPrimary)
                        .frame(maxWidth: 360)
                        .padding(.top, DS3Spacing.md)
                        .padding(.bottom, DS3Spacing.xs)
                    }

                    Button(vm.isLastSlide ? "Get Started" : "Next") {
                        if vm.isLastSlide {
                            applyLoginItemPreference()
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

    /// Explicit consent gate for App Store Guideline 2.4.5(iii): the app
    /// must not register as a login item without a user action. This is
    /// the only place the tutorial updates the login item via `setLoginItem`.
    /// The Preferences toggle is the other intentional entry point.
    private func applyLoginItemPreference() {
        let alreadyRegistered = DefaultSettings.appIsLoginItem
        guard startAtLoginEnabled != alreadyRegistered else { return }
        do {
            try setLoginItem(startAtLoginEnabled)
        } catch {
            logger.error("Failed to update login item from tutorial: \(error.localizedDescription)")
        }
    }
}

#Preview {
    TutorialView()
}

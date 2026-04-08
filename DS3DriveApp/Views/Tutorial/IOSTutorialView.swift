#if os(iOS)
    import DS3Lib
    import SwiftUI

    // MARK: - Slide Model

    private struct IOSTutorialSlide: Identifiable {
        let id = UUID()
        let imageName: String
        let title: String
        let description: String
    }

    // MARK: - Tutorial View

    /// Onboarding tutorial shown once per user after first successful login.
    /// Uses the same `tutorialShown` `AppStorage` key as the macOS app so
    /// users aren't re-prompted when switching platforms with the same
    /// account-scoped defaults.
    struct IOSTutorialView: View {
        @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) private var tutorialShown: Bool = DefaultSettings
            .tutorialShown

        @State private var currentIndex: Int = 0

        private let slides: [IOSTutorialSlide] = [
            IOSTutorialSlide(
                imageName: "tutorial-slide-1",
                title: "Welcome to Cubbit DS3 Drive",
                description: "Sync S3-compatible buckets directly into the Files app. Your data stays encrypted and under your control."
            ),
            IOSTutorialSlide(
                imageName: "tutorial-slide-2",
                title: "Pick a project",
                description: "Browse the projects in your Cubbit workspace and pick the one that holds the bucket you want to sync."
            ),
            IOSTutorialSlide(
                imageName: "tutorial-slide-3",
                title: "Choose a bucket",
                description: "Select any S3 bucket inside the project. You can drill into a folder or sync the whole bucket root."
            ),
            IOSTutorialSlide(
                imageName: "tutorial-slide-4",
                title: "Name and create",
                description: "Give your drive a memorable name — that's how it'll appear in the Files app and the Drives tab."
            ),
            IOSTutorialSlide(
                imageName: "tutorial-slide-5",
                title: "Manage your drives",
                description: "The Drives tab shows every drive with its live sync status. Tap one to pause, refresh, or disconnect."
            ),
            IOSTutorialSlide(
                imageName: "tutorial-slide-6",
                title: "Browse in the Files app",
                description: "Your drives show up under Locations in Files. Open, preview, and download files like any other cloud storage."
            )
        ]

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top bar
                    HStack {
                        Spacer()
                        Button("Skip") {
                            finish()
                        }
                        .font(.custom("Figtree-Medium", size: 15))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    // Slide pager
                    TabView(selection: $currentIndex) {
                        ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                            slideView(slide)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    // Progress indicator
                    TutorialPageIndicator(
                        count: slides.count,
                        currentIndex: $currentIndex
                    )
                    .padding(.top, 8)
                    .padding(.bottom, 24)

                    // CTA
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if isLastSlide {
                            finish()
                        } else {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentIndex += 1
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(isLastSlide ? "Get Started" : "Next")
                                .font(.custom("Figtree-SemiBold", size: 17))
                            Image(systemName: isLastSlide ? "arrow.right.circle.fill" : "arrow.right")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(IOSColors.brandPrimary)
                        )
                    }
                    .buttonStyle(TutorialPressStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }

        private var isLastSlide: Bool {
            currentIndex == slides.count - 1
        }

        private func finish() {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            tutorialShown = true
        }

        // MARK: - Slide Layout

        private func slideView(_ slide: IOSTutorialSlide) -> some View {
            VStack(spacing: 24) {
                Spacer(minLength: 12)

                Image(slide.imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(IOSColors.brandPrimary.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
                    .padding(.horizontal, 32)

                VStack(spacing: 12) {
                    Text(slide.title)
                        .font(.custom("Figtree-SemiBold", size: 24))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Text(slide.description)
                        .font(.custom("Figtree-Regular", size: 15))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 12)
            }
        }
    }

    // MARK: - Page Indicator

    private struct TutorialPageIndicator: View {
        let count: Int
        @Binding var currentIndex: Int

        var body: some View {
            HStack(spacing: 8) {
                ForEach(0 ..< count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentIndex
                            ? IOSColors.brandPrimary
                            : IOSColors.brandBorderStrong)
                        .frame(width: index == currentIndex ? 24 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.25), value: currentIndex)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentIndex = index
                            }
                        }
                }
            }
        }
    }

    // MARK: - Press Style

    private struct TutorialPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    #Preview {
        IOSTutorialView()
    }
#endif

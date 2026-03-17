import SwiftUI
import DS3Lib

struct TutorialProgress: View {
    var totalSlides: Int

    @Binding var currentSlideIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSlides, id: \.self) { index in
                Circle()
                    .fill(index == currentSlideIndex ? Color(nsColor: .separatorColor) : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 8, height: 8)
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
    @StateObject private var vm = TutorialViewModel(
        slides: [
            Slide(
                imageName: .tutorial1,
                title: "Select a project and bucket",
                paragraph: "Navigate your projects and buckets in the sidebar. Expand a project to browse its buckets and pick the one you want to sync"
            ),
            Slide(
                imageName: .tutorial2,
                title: "Name your drive",
                paragraph: "Choose a name for your drive. This is how it will appear in Finder's sidebar"
            ),
            Slide(
                imageName: .tutorial3,
                title: "Control your drives from the menu bar",
                paragraph: "Monitor sync status, add more drives, and access preferences — all from the tray menu"
            ),
            Slide(
                imageName: .tutorial4,
                title: "Access your files from Finder",
                paragraph: "Your DS3 storage appears as a native drive in Finder. Open, edit, and organize your cloud files like any local folder"
            )
        ]
    )

    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown

    private var currentSlide: Slide {
        vm.slides[vm.currentSlideIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(currentSlide.imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .id(vm.currentSlideIndex)
                .transition(.opacity)

            Spacer()

            VStack(spacing: 12) {
                Text(currentSlide.title)
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(currentSlide.paragraph)
                    .font(DS3Typography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(vm.isLastSlide ? "Get Started" : "Next") {
                    if vm.isLastSlide {
                        tutorialShown = true
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            vm.nextSlide()
                        }
                    }
                }
                .padding(.top, 4)
                .buttonStyle(PrimaryButtonStyle())

                TutorialProgress(
                    totalSlides: vm.slides.count,
                    currentSlideIndex: $vm.currentSlideIndex
                )
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(width: 700, height: 520)
        .animation(.easeInOut(duration: 0.3), value: vm.currentSlideIndex)
    }
}

#Preview {
    TutorialView()
}

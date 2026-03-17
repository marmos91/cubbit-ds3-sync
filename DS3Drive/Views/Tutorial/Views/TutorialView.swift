import SwiftUI
import DS3Lib

struct TutorialProgress: View {
    var totalSlides: Int

    @Binding var currentSlideIndex: Int

    var body: some View {
        HStack {
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
                        currentSlideIndex = index
                    }
            }

            Spacer()
        }
    }
}

struct TutorialView: View {
    // TODO: Replace tutorial images (Tutorial1, Tutorial2, Tutorial3) with new screenshots matching the current UI
    // - Tutorial1: should show the new tree navigation view (Projects -> Buckets -> Folders sidebar + content panel)
    // - Tutorial2: should show the new tray menu with status dots, speed metrics, and floating recent files panel
    // - Tutorial3: should show drives in Finder sidebar with the current app icon
    @StateObject private var vm = TutorialViewModel(
        slides: [
            Slide(
                imageName: .tutorial1,
                title: "Browse and sync your DS3 storage",
                paragraph: "Navigate your projects, buckets, and folders in a single tree view. Pick exactly what you want to sync and create a virtual drive in your Finder"
            ),
            Slide(
                imageName: .tutorial2,
                title: "Monitor your drives from the menu bar",
                paragraph: "Keep track of sync status, transfer speed, and recent files at a glance. Manage up to 3 drives with pause, refresh, and reset controls"
            ),
            Slide(
                imageName: .tutorial3,
                title: "Access your files from the Finder",
                paragraph: "Your DS3 storage appears as a native drive in Finder. Open, edit, and organize your cloud files without downloading them first"
            )
        ]
    )

    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown

    private var currentSlide: Slide {
        vm.slides[vm.currentSlideIndex]
    }

    var body: some View {
        HStack {
            Image(currentSlide.imageName)
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                Text(currentSlide.title)
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)

                Text(currentSlide.paragraph)
                    .font(DS3Typography.body)
                    .padding(.vertical)

                Button(vm.isLastSlide ? "Get Started" : "Next") {
                    if vm.isLastSlide {
                        tutorialShown = true
                    } else {
                        vm.nextSlide()
                    }
                }
                .padding(.vertical)
                .buttonStyle(PrimaryButtonStyle())

                TutorialProgress(
                    totalSlides: vm.slides.count,
                    currentSlideIndex: $vm.currentSlideIndex
                )
                .padding(.vertical)
            }
            .frame(minWidth: 272)
            .padding()
            .padding(.horizontal)
        }
        .frame(width: 800, height: 450)
    }
}

#Preview {
    TutorialView()
}

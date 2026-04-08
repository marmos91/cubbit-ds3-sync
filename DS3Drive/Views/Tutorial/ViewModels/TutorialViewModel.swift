import SwiftUI

@MainActor
class TutorialViewModel: ObservableObject {
    @Published var currentSlideIndex: Int
    @Published var slides: [Slide]

    /// Five-slide tutorial, one slide per distinct feature. IDs are
    /// non-sequential (`slide-1`, `-2`, `-3`, `-5`, `-7`) because they
    /// key into `Localizable.xcstrings` entries preserved from an earlier
    /// seven-slide revision — do not renumber. Images live under
    /// `DS3Drive/Assets/Assets.xcassets/tutorial/`.
    static let defaultSlides: [Slide] = [
        Slide(
            id: "slide-1",
            imageName: "tutorial-slide-1",
            titleKey: "tutorial.slide1.title",
            descriptionKey: "tutorial.slide1.description"
        ),
        Slide(
            id: "slide-2",
            imageName: "tutorial-slide-2",
            titleKey: "tutorial.slide2.title",
            descriptionKey: "tutorial.slide2.description"
        ),
        Slide(
            id: "slide-3",
            imageName: "tutorial-slide-3",
            titleKey: "tutorial.slide3.title",
            descriptionKey: "tutorial.slide3.description"
        ),
        Slide(
            id: "slide-5",
            imageName: "tutorial-slide-5",
            titleKey: "tutorial.slide5.title",
            descriptionKey: "tutorial.slide5.description"
        ),
        Slide(
            id: "slide-7",
            imageName: "tutorial-slide-7",
            titleKey: "tutorial.slide7.title",
            descriptionKey: "tutorial.slide7.description"
        )
    ]

    init(slides: [Slide] = TutorialViewModel.defaultSlides, currentSlideIndex: Int = 0) {
        self.slides = slides
        self.currentSlideIndex = currentSlideIndex
    }

    func nextSlide() {
        if currentSlideIndex < slides.count - 1 {
            currentSlideIndex += 1
        }
    }

    var isLastSlide: Bool {
        currentSlideIndex == slides.count - 1
    }
}

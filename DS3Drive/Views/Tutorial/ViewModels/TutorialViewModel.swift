import SwiftUI

class TutorialViewModel: ObservableObject {
    @Published var currentSlideIndex: Int
    @Published var slides: [Slide]
    
    init(slides: [Slide], currentSlideIndex: Int = 0) {
        self.slides = slides
        self.currentSlideIndex = currentSlideIndex
    }
    
    func nextSlide() {
        if currentSlideIndex < slides.count {
            currentSlideIndex = currentSlideIndex + 1
        }
    }
    
    func isLastSlide() -> Bool {
        return currentSlideIndex == slides.count - 1
    }
}

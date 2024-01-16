import SwiftUI

struct TutorialView: View {
    @StateObject var vm: TutorialViewModel = TutorialViewModel(
        slides: [
            Slide(
                imageName: "TutorialExample",
                title: "Slide 1",
                paragraph: "Lorem Ipsum is simply dummy text of the printing and typesetting industry. Lorem Ipsum has been the industry's standard dummy text ever since the 1500s"
            ),
            Slide(
                imageName: "TutorialExample",
                title: "Slide 2",
                paragraph: "Lorem Ipsum is simply dummy text of the printing and typesetting industry. Lorem Ipsum has been the industry's standard dummy text ever since the 1500s"
            )
        ]
    )
    
    @AppStorage("tutorialShown") var tutorialShown: Bool = DefaultSettings.tutorialShown
    
    var body: some View {
        HStack {
            Image(vm.slides[vm.currentSlideIndex].imageName).padding(.top, 50.0)
            
            VStack(alignment: .leading) {
                
                Text(vm.slides[vm.currentSlideIndex].title)
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(/*@START_MENU_TOKEN@*/.bold/*@END_MENU_TOKEN@*/)
                
                Text(vm.slides[vm.currentSlideIndex].paragraph)
                    .font(.custom("Nunito", size: 14))
                    .padding(.vertical)
                
                if vm.isLastSlide() {
                    Button("Sync Projects") {
                        tutorialShown = true
                    }
                    .padding(.vertical)
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Next") {
                        vm.nextSlide()
                    }
                    .padding(.vertical)
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .frame(minWidth: 272)
            .padding()
        }
    }
}

#Preview {
    TutorialView()
}

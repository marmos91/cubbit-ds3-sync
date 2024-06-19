import SwiftUI

struct TutorialProgress: View {
    var totalSlides: Int
    
    @Binding var currentSlide: Int
    
    @State var isHovering: Bool = false
    
    var body: some View {
        ForEach((0...totalSlides - 1), id: \.self) { index in
            Circle()
                .fill(index == currentSlide ? Color(.darkMainBorder) : Color(.darkMainTop))
                .frame(width: 8, height: 8)
                .onHover { hovering in
                    isHovering = hovering
                }
                .onChange(of: isHovering) {
                    DispatchQueue.main.async {
                        if isHovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .onTapGesture {
                    currentSlide = index
                }
        }
    }
}

struct TutorialView: View {
    @StateObject var vm: TutorialViewModel = TutorialViewModel(
        slides: [
            Slide(
                imageName: .tutorial1,
                title: "Sync a DS3 bucket with a virtual drive in your finder",
                paragraph: "Select a DS3 Bucket from one of your projects and start syncing your files. You can also choose to sync only specific folders"
            ),
            Slide(
                imageName: .tutorial2,
                title: "Manage up to 3 drives from the tray menu",
                paragraph: "From the Cubbit DS3 Sync Tray enu you can manage up to 3 drives. You can add or remove drives and change their settings"
            ),
            Slide(
                imageName: .tutorial3,
                title: "Access your files from the Finder",
                paragraph: "Use the tool your are familiar with to access your files stored on Cubbit DS3. With Cubbit DS3 Sync you can create a virtual drive to sync your files, without having to download them locally"
            )
        ]
    )
    
    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            HStack {
                Image(vm.slides[vm.currentSlideIndex].imageName)
//                    .resizable()
                    .ignoresSafeArea()
                    
//                    .frame(height: .infinity)
                    
                
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
                    
                    HStack {
                        TutorialProgress(
                            totalSlides: vm.slides.count,
                            currentSlide: $vm.currentSlideIndex
                        )
                        
                        Spacer()
                    }
                    .padding(.vertical)
                }
                .frame(minWidth: 272)
                .padding()
                .padding(.horizontal)
            }
        }
        .frame(
            minWidth: 800,
            maxWidth: 800,
            minHeight: 450,
            maxHeight: 450
        )
    }
}

#Preview {
    TutorialView()
}

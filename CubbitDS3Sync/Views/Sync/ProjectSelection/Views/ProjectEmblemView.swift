import SwiftUI

struct ProjectEmblemView: View {
    var shortName: String
    
    var body: some View {
        Text(shortName.uppercased())
            .font(.custom("Nunito", size: 16))
            .foregroundStyle(.black)
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange)
            }
    }
}

#Preview {
    ProjectEmblemView(shortName: "De")
        .padding()
}

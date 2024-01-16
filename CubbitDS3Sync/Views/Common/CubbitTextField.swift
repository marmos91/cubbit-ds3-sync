import SwiftUI

struct CubbitTextField: View {
    var placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    
    var body: some View {
        HStack{
            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            }
        }
        .padding()
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.sidebarBackground))
        }
    }
}

#Preview {
    ZStack {
        Color(.background)
        
        VStack{
            CubbitTextField(
                placeholder: "Email",
                text: Binding.constant("")
            )
            
            CubbitTextField(
                placeholder: "Password",
                text: Binding.constant(""),
                isSecure: true
            )
        }
        .padding()
    }
}

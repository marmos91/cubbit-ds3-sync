import SwiftUI

struct CubbitTextField: View {
    var placeholder: String
    
    @Binding var text: String
    @State var isShowingPassword = false
    
    var isSecure: Bool = false
    var canShowPassword = true
    
    var body: some View {
        HStack{
            if isSecure {
                if isShowingPassword {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                }
                
                if canShowPassword {
                    Image(.showPasswordIcon)
                        .resizable()
                        .frame(width: 16, height: 16, alignment: .trailing)
                        .onTapGesture {
                            isShowingPassword = !isShowingPassword
                        }
                }
                
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

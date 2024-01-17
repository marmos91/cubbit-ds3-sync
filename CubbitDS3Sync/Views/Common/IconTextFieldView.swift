import SwiftUI

struct IconTextField: View {
    var iconName: ImageResource?
    var placeholder: String
    var error: Error? = nil
    
    @Binding var text: String
    @State var shouldShowPassword = false
    
    var isSecure = false
    
    var body: some View {
        HStack(alignment: /*@START_MENU_TOKEN@*/.center/*@END_MENU_TOKEN@*/, spacing: 10) {
            if iconName != nil {
                Image(iconName!)
                    .resizable()
                    .frame(width: 16, height: 16, alignment: .leading)
                    .padding(.leading, 10.0)
            }
            
            if isSecure {
                if shouldShowPassword {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(PlainTextFieldStyle())
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(PlainTextFieldStyle())
                }
                
                Image(.showPasswordIcon)
                    .resizable()
                    .frame(width: 16, height: 16, alignment: .trailing)
                    .onTapGesture {
                        shouldShowPassword = !shouldShowPassword
                    }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(PlainTextFieldStyle())
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(lineWidth: 1)
                .fill(error != nil ? Color.red : Color(.textFieldBorder))
                .frame(maxWidth: .infinity, maxHeight: 32)
        )
    }
}

#Preview {
    VStack {
        IconTextField(iconName: .emailIcon, placeholder: "Email", text: Binding.constant(""), isSecure: false)
        
        IconTextField(iconName: .passwordIcon, placeholder: "Password", text: Binding.constant(""), isSecure: true)
    }.padding()
}
    

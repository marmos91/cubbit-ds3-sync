import SwiftUI

struct MFAView: View {
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(LoginViewModel.self) var loginViewModel: LoginViewModel
    
    var email: String
    var password: String
    
    @State var tfaCode: String = ""
    @FocusState var focused: Bool?
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            VStack {
                if loginViewModel.isLoading {
                    LoadingView()
                } else {
                    Text("Two-factor authentication (2FA)")
                        .font(.custom("Nunito", size: 18))
                        .fontWeight(.bold)
                        .padding(.vertical)
                    
                    Text("Enter the code from your authenticator app")
                        .font(.custom("Nunito", size: 14))
                        .padding(.bottom)
                    
                    BorderedSectionView {
                        HStack {
                            Text("Authentication code")
                            
                            Spacer()
                        }
                        .padding(.vertical)
                        
                        IconTextField(
                            iconName: .mfaIcon,
                            placeholder: "2FA 6-digit code",
                            text: $tfaCode
                        )
                        .focused($focused, equals: true)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                                self.focused = true
                            }
                        }
                        .onSubmit {
                            self.loginWithMFA()
                        }
                        
                        Button("Log in") {
                            self.loginWithMFA()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(tfaCode == "")
                        .padding(.vertical)
                        .onSubmit {
                            self.loginWithMFA()
                        }
                        
                        if let loginError = loginViewModel.loginError {
                            Text(loginError.localizedDescription)
                                .font(.custom("Nunito", size: 14))
                                .foregroundStyle(Color.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .frame(width: 500, height: 400)
        }
        .frame(width: 700, height: 450)
    }
    
    func loginWithMFA() {
        Task {
            try await loginViewModel.login(
                withAuthentication: self.ds3Authentication,
                email: email,
                password: password,
                withTfaToken: tfaCode
            )
        }
    }
}

#Preview {
    MFAView(
        email: "test@cubbit.io",
        password: "123"
    )
    .environment(DS3Authentication.loadFromPersistenceOrCreateNew())
    .environment(LoginViewModel())
}

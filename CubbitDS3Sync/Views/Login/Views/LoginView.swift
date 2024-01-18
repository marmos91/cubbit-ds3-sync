import SwiftUI

struct LoginView: View {
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    
    @State var email: String = ""
    @State var password: String = ""
    
    var loginViewModel: LoginViewModel = LoginViewModel()
    
    var body: some View {
        
        if loginViewModel.need2FA {
            MFAView(email: email, password: password)
                .environment(loginViewModel)
                .environment(ds3Authentication)
        } else {
            ZStack {
                Color(.background).ignoresSafeArea()
                
                VStack(alignment: .center) {
                    Image(.cubbitLogo)
                        .resizable()
                        .frame(width: 120, height: 44)
                        .padding(.vertical)
                    
                    Text("DS3 Object Storage Log in", comment: "The h1 of the login page")
                        .font(.custom("Nunito", size: 16))
                        .bold()
                        .padding(.vertical)
                    
                    IconTextField(
                        iconName: .emailIcon,
                        placeholder: NSLocalizedString("Email", comment: "Email placeholder"),
                        error: loginViewModel.loginError,
                        text: $email
                    )
                    
                    IconTextField(
                        iconName: .passwordIcon,
                        placeholder: NSLocalizedString("Password", comment: "Password placeholder"),
                        error: loginViewModel.loginError,
                        text: $password,
                        isSecure: true
                    )
                    .onSubmit {
                        self.login()
                    }
                    
                    Button(loginViewModel.isLoading ? NSLocalizedString("Loading...", comment: "Loading") : NSLocalizedString("Log in", comment: "Login button")) {
                        self.login()
                    }
                    .padding(.vertical)
                    .disabled(loginDisabled())
                    .buttonStyle(PrimaryButtonStyle())
                    
                    if loginViewModel.loginError != nil {
                        Text("An error occurred: \(loginViewModel.loginError!.localizedDescription)")
                            .foregroundStyle(Color.red)
                    }
                    
                    LinkView(
                        text: NSLocalizedString("Forgot your password?", comment: "Forgot your password link"),
                        href: ConsoleURLs.recoveryURL
                    )
                    .padding()
                    
                    OutlineLink(
                        text: NSLocalizedString("Sign up", comment: "Sign up button text"),
                        href: ConsoleURLs.signupURL
                    )
                }
                .frame(width: 360, height: 500)
                .padding(.vertical, 80.0)
                .padding(.horizontal, 100)
            }
            .frame(width: 360, height: 500)
            .padding(.vertical, 80.0)
            .padding(.horizontal, 100)
        }
    }
    
    func loginDisabled() -> Bool {
        return self.email == "" || self.password == ""
    }
    
    func login() {
        Task {
            try await loginViewModel.login(
                withAuthentication: self.ds3Authentication,
                email: email,
                password: password
            )
        }
    }
}

#Preview {
    LoginView()
        .environment(DS3Authentication())
}

import SwiftUI
import DS3Lib

struct LoginView: View {
    enum FocusedField {
        case email, password
    }
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication

    @State var email: String = ""
    @State var password: String = ""
    @State var tenant: String = UserDefaults.standard.string(forKey: DefaultSettings.UserDefaultsKeys.lastTenant) ?? DefaultSettings.defaultTenantName
    @State var coordinatorURL: String = UserDefaults.standard.string(forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL) ?? CubbitAPIURLs.defaultCoordinatorURL
    @State var showAdvanced: Bool = false
    @FocusState private var focusedField: FocusedField?

    var loginViewModel: LoginViewModel = LoginViewModel()

    var body: some View {

        if loginViewModel.need2FA {
            MFAView(email: email, password: password, tenant: tenant, coordinatorURL: coordinatorURL)
                .environment(loginViewModel)
                .environment(ds3Authentication)
        } else {
            ZStack {
                Color(.background)
                    .ignoresSafeArea()

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
                    .focused(self.$focusedField, equals: .email)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                            self.focusedField = .email
                        }
                    }

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

                    Button {
                        showAdvanced.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text(NSLocalizedString("Advanced", comment: "Advanced login settings"))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showAdvanced {
                        VStack(spacing: 8) {
                            IconTextField(
                                iconName: .userIcon,
                                placeholder: NSLocalizedString("Tenant name", comment: "Tenant name placeholder"),
                                text: $tenant
                            )

                            IconTextField(
                                iconName: .settingsIcon,
                                placeholder: NSLocalizedString("Coordinator URL", comment: "Coordinator URL placeholder"),
                                text: $coordinatorURL
                            )
                        }
                        .padding(.top, 4)
                    }

                    Button(loginViewModel.isLoading ? NSLocalizedString("Loading...", comment: "Loading") : NSLocalizedString("Log in", comment: "Login button")) {
                        self.login()
                    }
                    .padding(.vertical)
                    .disabled(loginDisabled)
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

    var loginDisabled: Bool {
        email.isEmpty || password.isEmpty
    }

    func login() {
        ds3Authentication.urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)

        UserDefaults.standard.set(tenant, forKey: DefaultSettings.UserDefaultsKeys.lastTenant)
        UserDefaults.standard.set(coordinatorURL, forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL)

        let viewModel = loginViewModel
        let auth = ds3Authentication
        let tenantValue = (tenant.isEmpty || tenant == DefaultSettings.defaultTenantName) ? nil : tenant
        Task {
            try await viewModel.login(
                withAuthentication: auth,
                email: email,
                password: password,
                tenant: tenantValue,
                coordinatorURL: coordinatorURL
            )
        }
    }
}

#Preview {
    LoginView()
        .environment(DS3Authentication())
}

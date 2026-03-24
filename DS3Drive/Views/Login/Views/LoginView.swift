import DS3Lib
import SwiftUI

struct LoginView: View {
    enum FocusedField {
        case email, password
    }
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var tenant: String = {
        let saved = UserDefaults.standard.string(forKey: DefaultSettings.UserDefaultsKeys.lastTenant) ?? ""
        return saved.isEmpty ? DefaultSettings.defaultTenantName : saved
    }()
    @State private var coordinatorURL: String = UserDefaults.standard
        .string(forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL) ?? CubbitAPIURLs.defaultCoordinatorURL
    @State private var showAdvanced: Bool = false
    @FocusState private var focusedField: FocusedField?

    @State private var loginViewModel = LoginViewModel()

    var body: some View {
        if loginViewModel.need2FA {
            MFAView(email: email, password: password, tenant: tenant, coordinatorURL: coordinatorURL)
                .environment(loginViewModel)
                .environment(ds3Authentication)
        } else {
            VStack(spacing: 0) {
                Spacer()

                // Card content
                VStack(alignment: .center, spacing: DS3Spacing.lg) {
                    // Logo
                    Image(.cubbitLogo)
                        .resizable()
                        .frame(width: 120, height: 44)

                    Text("Cubbit DS3 Drive")
                        .font(DS3Typography.caption)
                        .foregroundStyle(DS3Colors.secondaryText)

                    // Title
                    Text("Log in to your account")
                        .font(DS3Typography.headline)
                        .foregroundStyle(DS3Colors.primaryText)
                        .padding(.bottom, DS3Spacing.xs)

                    // Email field with SF Symbol
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "envelope")
                            .foregroundStyle(DS3Colors.secondaryText)
                            .frame(width: 20)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textFieldStyle(.plain)
                            .font(DS3Typography.body)
                            .textContentType(.username)
                    }
                    .padding(DS3Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS3Colors.separator, lineWidth: 1)
                    )
                    .focused(self.$focusedField, equals: .email)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                            self.focusedField = .email
                        }
                    }
                    .onSubmit {
                        focusedField = .password
                    }

                    // Password field with SF Symbol
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "lock")
                            .foregroundStyle(DS3Colors.secondaryText)
                            .frame(width: 20)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .textFieldStyle(.plain)
                            .font(DS3Typography.body)
                            .textContentType(.password)
                    }
                    .padding(DS3Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS3Colors.separator, lineWidth: 1)
                    )
                    .onSubmit {
                        self.login()
                    }

                    // Advanced section
                    VStack(alignment: .leading, spacing: DS3Spacing.sm) {
                        Button {
                            showAdvanced.toggle()
                        } label: {
                            HStack(spacing: DS3Spacing.xs) {
                                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text("Advanced")
                                    .font(DS3Typography.caption)
                            }
                            .foregroundStyle(DS3Colors.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if showAdvanced {
                            HStack(spacing: DS3Spacing.sm) {
                                Image(systemName: "person")
                                    .foregroundStyle(DS3Colors.secondaryText)
                                    .frame(width: 20)
                                TextField("Tenant name", text: $tenant)
                                    .textFieldStyle(.plain)
                                    .font(DS3Typography.body)
                            }
                            .padding(DS3Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DS3Colors.separator, lineWidth: 1)
                            )

                            HStack(spacing: DS3Spacing.sm) {
                                Image(systemName: "globe")
                                    .foregroundStyle(DS3Colors.secondaryText)
                                    .frame(width: 20)
                                TextField("Coordinator URL", text: $coordinatorURL)
                                    .textFieldStyle(.plain)
                                    .font(DS3Typography.body)
                            }
                            .padding(DS3Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DS3Colors.separator, lineWidth: 1)
                            )
                        }
                    }

                    // Login button
                    Button(loginViewModel.isLoading ? "Loading..." : "Log in") {
                        self.login()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(loginDisabled)
                    .frame(maxWidth: .infinity, maxHeight: 36)

                    // Error message
                    if let error = loginViewModel.loginError {
                        Text("An error occurred: \(error.localizedDescription)")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.statusError)
                            .multilineTextAlignment(.center)
                    }

                    // Links
                    if let url = URL(string: ConsoleURLs.recoveryURL) {
                        Link("Forgot your password?", destination: url)
                            .font(DS3Typography.caption)
                            .foregroundStyle(Color.accentColor)
                    }

                    if let url = URL(string: ConsoleURLs.signupURL) {
                        Link("Sign up", destination: url)
                            .font(DS3Typography.caption)
                            .foregroundStyle(Color.accentColor)
                            .padding(.bottom, DS3Spacing.sm)
                    }
                }
                .padding(.horizontal, DS3Spacing.xxl)
                .padding(.vertical, DS3Spacing.xl)
                .frame(maxWidth: 340)

                Spacer()
            }
            .frame(width: 400, height: 500)
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
            do {
                try await viewModel.login(
                    withAuthentication: auth,
                    email: email,
                    password: password,
                    tenant: tenantValue,
                    coordinatorURL: coordinatorURL
                )
            } catch {
                // Error handled by LoginViewModel
            }
        }
    }
}

#Preview {
    LoginView()
        .environment(DS3Authentication())
}

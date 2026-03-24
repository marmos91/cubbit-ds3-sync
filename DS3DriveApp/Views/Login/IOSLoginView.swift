#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// iOS-native login view with email, password, inline errors, iPad card layout,
    /// advanced tenant/coordinator settings, and 2FA sheet presentation.
    struct IOSLoginView: View {
        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        @State private var loginViewModel = LoginViewModel()
        @State private var email = ""
        @State private var password = ""
        @State private var showPassword = false
        @State private var tenant: String = UserDefaults.standard
            .string(forKey: DefaultSettings.UserDefaultsKeys.lastTenant) ?? ""
        @State private var coordinatorURL: String = UserDefaults.standard
            .string(forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL) ?? CubbitAPIURLs.defaultCoordinatorURL
        @State private var showAdvanced = false

        var body: some View {
            if horizontalSizeClass == .compact {
                // iPhone: full-width form
                loginContent
                    .background(IOSColors.background)
            } else {
                // iPad: centered card layout
                ZStack {
                    IOSColors.background
                        .ignoresSafeArea()

                    loginContent
                        .frame(maxWidth: 400)
                        .padding(IOSSpacing.xl)
                        .background(IOSColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                }
            }
        }

        // MARK: - Login Form Content

        private var loginContent: some View {
            ScrollView {
                VStack(spacing: IOSSpacing.md) {
                    Spacer(minLength: IOSSpacing.xl)

                    // Logo
                    Image("CubbitLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 44)
                        .accessibilityLabel("Cubbit")

                    // Title
                    Text("DS3 Drive")
                        .font(IOSTypography.title)

                    Spacer(minLength: IOSSpacing.xl)

                    // Email field
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textFieldStyle(.roundedBorder)

                    // Inline error below email
                    if let loginError = loginViewModel.loginError {
                        HStack(spacing: IOSSpacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(IOSTypography.caption)
                            Text(loginError.localizedDescription)
                                .font(IOSTypography.caption)
                        }
                        .foregroundStyle(IOSColors.statusError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }

                    // Password field with show/hide toggle
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                                    .textContentType(.password)
                            } else {
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(IOSColors.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .textFieldStyle(.roundedBorder)

                    Spacer(minLength: IOSSpacing.md)

                    // Sign In button
                    Button {
                        signIn()
                    } label: {
                        if loginViewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Sign In")
                        }
                    }
                    .buttonStyle(IOSPrimaryButtonStyle())
                    .disabled(email.isEmpty || password.isEmpty || loginViewModel.isLoading)

                    // Advanced section
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        VStack(spacing: IOSSpacing.sm) {
                            TextField("Tenant", text: $tenant)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            TextField("Coordinator URL", text: $coordinatorURL)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(.top, IOSSpacing.sm)
                    }
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)

                    Spacer()

                    // Version label
                    Text(
                        "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))"
                    )
                    .font(IOSTypography.footnote)
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, IOSSpacing.lg)
                .padding(.vertical, IOSSpacing.md)
                .animation(IOSAnimations.errorAppear, value: loginViewModel.loginError != nil)
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $loginViewModel.need2FA) {
                IOSMFAView(
                    loginViewModel: loginViewModel,
                    email: email,
                    password: password,
                    tenant: tenant,
                    coordinatorURL: coordinatorURL
                )
                .environment(ds3Authentication)
            }
        }

        // MARK: - Actions

        private func signIn() {
            loginViewModel.loginError = nil

            ds3Authentication.urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
            UserDefaults.standard.set(tenant, forKey: DefaultSettings.UserDefaultsKeys.lastTenant)
            UserDefaults.standard.set(coordinatorURL, forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL)

            let tenantValue = (tenant.isEmpty || tenant == DefaultSettings.defaultTenantName) ? nil : tenant
            let viewModel = loginViewModel
            let auth = ds3Authentication

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
                    // Error is handled by LoginViewModel's published properties
                }
            }
        }
    }

    #Preview {
        IOSLoginView()
            .environment(DS3Authentication())
    }
#endif

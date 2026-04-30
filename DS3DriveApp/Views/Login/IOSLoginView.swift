#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// iOS-native login view: vertically centered content, hero title,
    /// 56pt rounded inputs with leading icons, 54pt brand-primary CTA,
    /// and bottom-pinned version label. iPhone + iPad.
    struct IOSLoginView: View {
        enum FocusedField {
            case email, password, tenant, coordinator
        }

        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.openURL) private var openURL

        @State private var loginViewModel = LoginViewModel()
        @State private var email = ""
        @State private var password = ""
        @State private var showPassword = false
        @State private var tenant: String = {
            let saved = UserDefaults.standard.string(forKey: DefaultSettings.UserDefaultsKeys.lastTenant) ?? ""
            return saved.isEmpty ? DefaultSettings.defaultTenantName : saved
        }()
        @State private var coordinatorURL: String = UserDefaults.standard
            .string(forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL) ?? CubbitAPIURLs.defaultCoordinatorURL
        @State private var showAdvanced = false
        @FocusState private var focusedField: FocusedField?

        private let fieldHeight: CGFloat = 56
        private let buttonHeight: CGFloat = 54
        private let contentMaxWidth: CGFloat = 400

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                GeometryReader { geo in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)

                            loginContent
                                .frame(maxWidth: contentMaxWidth)
                                .padding(.horizontal, horizontalSizeClass == .compact ? 24 : 48)

                            Spacer(minLength: 0)

                            versionLabel
                                .padding(.top, 24)
                                .padding(.bottom, 8)
                        }
                        .frame(minHeight: geo.size.height)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
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

        // MARK: - Login Form Content

        private var loginContent: some View {
            VStack(spacing: 20) {
                // Brand header
                VStack(spacing: 16) {
                    Image("CubbitLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 170, height: 62)
                        .accessibilityLabel("Cubbit")

                    Text("DS3 Drive")
                        .font(.custom("Figtree-SemiBold", size: 24))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                }
                .padding(.bottom, 4)

                // Hero title
                Text("Log in to your account")
                    .font(.custom("Figtree-Medium", size: 18))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)

                // Email field
                brandField(icon: "envelope", focus: .email) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .onChange(of: email) { loginViewModel.loginError = nil }
                        .onSubmit { focusedField = .password }
                }

                // Password field with show/hide toggle
                brandField(icon: "lock", focus: .password) {
                    HStack(spacing: 12) {
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
                        .submitLabel(.go)
                        .onChange(of: password) { loginViewModel.loginError = nil }
                        .onSubmit { signIn() }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 17))
                                .foregroundStyle(IOSColors.brandTextSecondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }

                // Inline error
                if let loginError = loginViewModel.loginError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                        Text(loginError.localizedDescription)
                            .font(.custom("Figtree-Regular", size: 14))
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(IOSColors.statusError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }

                // Advanced section
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { showAdvanced.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Advanced")
                                .font(.custom("Figtree-Medium", size: 14))
                        }
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        brandField(icon: "person", focus: .tenant) {
                            TextField(
                                "Tenant ID",
                                text: $tenant,
                                prompt: Text("Tenant ID")
                                    .foregroundColor(IOSColors.brandTextSecondary)
                            )
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        }

                        brandField(icon: "globe", focus: .coordinator) {
                            TextField(
                                "Coordinator URL",
                                text: $coordinatorURL,
                                prompt: Text(CubbitAPIURLs.defaultCoordinatorURL)
                                    .foregroundColor(IOSColors.brandTextSecondary)
                            )
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Primary CTA
                Button {
                    signIn()
                } label: {
                    ZStack {
                        if loginViewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Log in")
                                .font(.custom("Figtree-SemiBold", size: 17))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: buttonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                loginDisabled
                                    ? IOSColors.brandPrimary.opacity(0.35)
                                    : IOSColors.brandPrimary
                            )
                    )
                }
                .buttonStyle(PressableScale())
                .disabled(loginDisabled)
                .padding(.top, 4)

                // Links
                VStack(spacing: 14) {
                    if let url = URL(string: ConsoleURLs.recoveryURL) {
                        Button("Forgot your password?") { openURL(url) }
                            .font(.custom("Figtree-Medium", size: 15))
                            .foregroundStyle(IOSColors.brandPrimary)
                            .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        Text("Don't have an account?")
                            .font(.custom("Figtree-Regular", size: 15))
                            .foregroundStyle(IOSColors.brandTextSecondary)

                        if let url = URL(string: ConsoleURLs.signupURL) {
                            Button("Sign up") { openURL(url) }
                                .font(.custom("Figtree-SemiBold", size: 15))
                                .foregroundStyle(IOSColors.brandPrimary)
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .animation(.easeInOut(duration: 0.25), value: loginViewModel.loginError != nil)
            .animation(.easeInOut(duration: 0.25), value: showAdvanced)
        }

        private var versionLabel: some View {
            Text(
                "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))"
            )
            .font(.custom("Figtree-Regular", size: 12))
            .foregroundStyle(IOSColors.textTertiary)
        }

        private var loginDisabled: Bool {
            email.isEmpty || password.isEmpty || loginViewModel.isLoading
        }

        // MARK: - Brand Field

        /// 56pt rounded input with leading SF Symbol. `brandBorderSubtle`
        /// stroke, brand primary on focus.
        private func brandField(
            icon: String,
            focus: FocusedField,
            @ViewBuilder content: () -> some View
        ) -> some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .frame(width: 22)

                content()
                    .font(.custom("Figtree-Regular", size: 17))
                    .foregroundStyle(IOSColors.brandTextPrimary)
                    .textFieldStyle(.plain)
                    .tint(IOSColors.brandPrimary)
            }
            .padding(.horizontal, 16)
            .frame(height: fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        focusedField == focus
                            ? IOSColors.brandPrimary
                            : IOSColors.brandBorderSubtle,
                        lineWidth: focusedField == focus ? 1.5 : 1
                    )
            )
            .focused($focusedField, equals: focus)
            .animation(.easeInOut(duration: 0.15), value: focusedField)
        }

        // MARK: - Actions

        private func signIn() {
            loginViewModel.loginError = nil

            ds3Authentication.urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
            UserDefaults.standard.set(tenant, forKey: DefaultSettings.UserDefaultsKeys.lastTenant)
            UserDefaults.standard.set(coordinatorURL, forKey: DefaultSettings.UserDefaultsKeys.lastCoordinatorURL)

            let tenantValue = tenant.isEmpty ? nil : tenant
            let viewModel = loginViewModel
            let auth = ds3Authentication

            Task {
                try? await viewModel.login(
                    withAuthentication: auth,
                    email: email,
                    password: password,
                    tenant: tenantValue,
                    coordinatorURL: coordinatorURL
                )
            }
        }
    }

    // MARK: - Pressable Scale

    /// Subtle press-down scale — the tactile response native iOS CTAs use.
    private struct PressableScale: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    #Preview {
        IOSLoginView()
            .environment(DS3Authentication())
    }
#endif

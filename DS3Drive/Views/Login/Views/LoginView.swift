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
            ZStack {
                // Single unified window backdrop — Cubbit brand vertical gradient
                // (Plan 05-18a: collapse the old four-layer stack into one)
                DS3Gradients.brandVerticalBackground
                    .ignoresSafeArea()

                // Force the hosting window to the screen center on appear.
                // `.defaultPosition(.center)` in DS3DriveApp.swift only
                // applies on first launch; macOS restores the last saved
                // position on subsequent launches, which left the login
                // window stuck wherever it was last dragged.
                WindowCenterer()
                    .frame(width: 0, height: 0)

                VStack(alignment: .center, spacing: DS3Spacing.lg) {
                    Spacer(minLength: 0)

                    // Logo — sits directly on the gradient, no radial glow, no card
                    Image(.cubbitLogo)
                        .resizable()
                        .frame(width: 96, height: 36)

                    Text("DS3 Drive")
                        .font(DS3Typography.caption)
                        .foregroundStyle(DS3Colors.brandTextSecondary)

                    // Title
                    Text("Log in to your account")
                        .font(DS3Typography.title)
                        .foregroundStyle(DS3Colors.brandTextPrimary)
                        .padding(.bottom, DS3Spacing.xs)

                    // Email field
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "envelope")
                            .foregroundStyle(DS3Colors.brandTextSecondary)
                            .frame(width: 20)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textFieldStyle(.plain)
                            .font(DS3Typography.body)
                            .textContentType(.username)
                            .onChange(of: email) {
                                // Clear stale server error as soon as the
                                // user starts correcting their input.
                                loginViewModel.loginError = nil
                            }
                    }
                    .padding(DS3Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                focusedField == .email
                                    ? DS3Colors.brandPrimary
                                    : DS3Colors.brandBorderSubtle,
                                lineWidth: 1
                            )
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

                    // Password field
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "lock")
                            .foregroundStyle(DS3Colors.brandTextSecondary)
                            .frame(width: 20)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .textFieldStyle(.plain)
                            .font(DS3Typography.body)
                            .textContentType(.password)
                            .onChange(of: password) {
                                loginViewModel.loginError = nil
                            }
                    }
                    .padding(DS3Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                focusedField == .password
                                    ? DS3Colors.brandPrimary
                                    : DS3Colors.brandBorderSubtle,
                                lineWidth: 1
                            )
                    )
                    .focused(self.$focusedField, equals: .password)
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
                            .foregroundStyle(DS3Colors.brandTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if showAdvanced {
                            HStack(spacing: DS3Spacing.sm) {
                                Image(systemName: "person")
                                    .foregroundStyle(DS3Colors.brandTextSecondary)
                                    .frame(width: 20)
                                TextField("Tenant name", text: $tenant)
                                    .textFieldStyle(.plain)
                                    .font(DS3Typography.body)
                            }
                            .padding(DS3Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DS3Colors.brandBorderSubtle, lineWidth: 1)
                            )

                            HStack(spacing: DS3Spacing.sm) {
                                Image(systemName: "globe")
                                    .foregroundStyle(DS3Colors.brandTextSecondary)
                                    .frame(width: 20)
                                TextField("Coordinator URL", text: $coordinatorURL)
                                    .textFieldStyle(.plain)
                                    .font(DS3Typography.body)
                            }
                            .padding(DS3Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DS3Colors.brandBorderSubtle, lineWidth: 1)
                            )
                        }
                    }

                    // Login button — shared brand primary style
                    Button(loginViewModel.isLoading ? "Loading..." : "Log in") {
                        self.login()
                    }
                    .buttonStyle(BrandPrimaryButtonStyle(fillWidth: true))
                    .disabled(loginDisabled)
                    .keyboardShortcut(.defaultAction)

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
                            .foregroundStyle(DS3Colors.brandPrimary)
                    }

                    if let url = URL(string: ConsoleURLs.signupURL) {
                        Link("Sign up", destination: url)
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.brandPrimary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS3Spacing.xxl)
                .padding(.vertical, DS3Spacing.xl)
                .frame(maxWidth: 360, maxHeight: .infinity)
            }
            .frame(width: 540, height: 680)
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

// MARK: - WindowCenterer

/// Tiny `NSViewRepresentable` that re-centers its hosting window every
/// time `LoginView` appears. `.defaultPosition(.center)` in
/// `DS3DriveApp.swift` only applies on first launch — macOS restores the
/// last saved window position on subsequent launches, which leaves the
/// login window wherever the user last dragged it.
///
/// Uses `NSWindow.center()` so the positioning follows Apple's HIG
/// (slightly above geometric center, matching every native macOS modal).
private struct WindowCenterer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.center()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op — centering runs once in makeNSView.
    }
}

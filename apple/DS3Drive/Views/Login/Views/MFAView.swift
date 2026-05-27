import DS3Lib
import SwiftUI

struct MFAView: View {
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(LoginViewModel.self) var loginViewModel: LoginViewModel

    var email: String
    var password: String
    var tenant: String
    var coordinatorURL: String

    @State private var tfaCode: String = ""
    @FocusState var focused: Bool?

    var body: some View {
        ZStack {
            // Unified brand backdrop — matches LoginView
            DS3Gradients.brandVerticalBackground
                .ignoresSafeArea()

            VStack(alignment: .center, spacing: DS3Spacing.lg) {
                Spacer(minLength: 0)

                if loginViewModel.isLoading {
                    LoadingView()
                } else {
                    // Icon
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(DS3Colors.brandPrimary)

                    Text("Two-factor authentication")
                        .font(DS3Typography.title)
                        .foregroundStyle(DS3Colors.brandTextPrimary)

                    Text("Enter the code from your authenticator app")
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.brandTextSecondary)
                        .multilineTextAlignment(.center)

                    // Code input
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "number")
                            .foregroundStyle(DS3Colors.brandTextSecondary)
                            .frame(width: 20)
                        TextField("6-digit code", text: $tfaCode)
                            .textFieldStyle(.plain)
                            .font(DS3Typography.body)
                            .textContentType(.oneTimeCode)
                            .onChange(of: tfaCode) {
                                // Clear stale server error as soon as the
                                // user starts correcting their input.
                                loginViewModel.loginError = nil
                            }
                    }
                    .padding(DS3Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                focused == true
                                    ? DS3Colors.brandPrimary
                                    : DS3Colors.brandBorderSubtle,
                                lineWidth: 1
                            )
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

                    // Login button — shared brand primary style
                    Button("Log in") {
                        self.loginWithMFA()
                    }
                    .buttonStyle(BrandPrimaryButtonStyle(fillWidth: true))
                    .disabled(tfaCode.isEmpty)
                    .keyboardShortcut(.defaultAction)

                    // Error
                    if let loginError = loginViewModel.loginError {
                        Text(loginError.localizedDescription)
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.statusError)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS3Spacing.xxl)
            .padding(.vertical, DS3Spacing.xl)
            .frame(maxWidth: 360, maxHeight: .infinity)
        }
        .frame(width: 540, height: 680)
    }

    func loginWithMFA() {
        let viewModel = loginViewModel
        let auth = ds3Authentication
        let tenantValue = tenant.isEmpty ? nil : tenant
        Task {
            do {
                try await viewModel.login(
                    withAuthentication: auth,
                    email: email,
                    password: password,
                    withTfaToken: tfaCode,
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
    MFAView(
        email: "test@cubbit.io",
        password: "123",
        tenant: "",
        coordinatorURL: CubbitAPIURLs.defaultCoordinatorURL
    )
    .environment(DS3Authentication.loadFromPersistenceOrCreateNew())
    .environment(LoginViewModel())
}

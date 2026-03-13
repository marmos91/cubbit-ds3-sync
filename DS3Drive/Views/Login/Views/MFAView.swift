import SwiftUI
import DS3Lib

struct MFAView: View {
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(LoginViewModel.self) var loginViewModel: LoginViewModel

    var email: String
    var password: String
    var tenant: String
    var coordinatorURL: String

    @State var tfaCode: String = ""
    @FocusState var focused: Bool?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Card content
            VStack(alignment: .center, spacing: DS3Spacing.lg) {
                if loginViewModel.isLoading {
                    LoadingView()
                } else {
                    // Icon
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)

                    Text("Two-factor authentication")
                        .font(DS3Typography.title)
                        .foregroundStyle(DS3Colors.primaryText)

                    Text("Enter the code from your authenticator app")
                        .font(DS3Typography.body)
                        .foregroundStyle(DS3Colors.secondaryText)
                        .multilineTextAlignment(.center)

                    // Code input
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "number")
                            .foregroundStyle(DS3Colors.secondaryText)
                            .frame(width: 20)
                        TextField("6-digit code", text: $tfaCode)
                            .textFieldStyle(.plain)
                            .font(DS3Typography.body)
                    }
                    .padding(DS3Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS3Colors.separator, lineWidth: 1)
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

                    // Login button
                    Button("Log in") {
                        self.loginWithMFA()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(tfaCode.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: 36)

                    // Error
                    if let loginError = loginViewModel.loginError {
                        Text(loginError.localizedDescription)
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.statusError)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, DS3Spacing.xxl)
            .padding(.vertical, DS3Spacing.xl)
            .frame(maxWidth: 340)

            Spacer()
        }
        .frame(width: 400, height: 500)
    }

    func loginWithMFA() {
        let viewModel = loginViewModel
        let auth = ds3Authentication
        let tenantValue = (tenant.isEmpty || tenant == DefaultSettings.defaultTenantName) ? nil : tenant
        Task {
            try await viewModel.login(
                withAuthentication: auth,
                email: email,
                password: password,
                withTfaToken: tfaCode,
                tenant: tenantValue,
                coordinatorURL: coordinatorURL
            )
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

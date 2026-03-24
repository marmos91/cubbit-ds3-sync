#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// 2FA code entry sheet presented when the login flow requires two-factor authentication.
    /// Slides up as a sheet from IOSLoginView when `loginViewModel.need2FA` is true.
    struct IOSMFAView: View {
        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(\.dismiss) private var dismiss

        var loginViewModel: LoginViewModel
        let email: String
        let password: String
        let tenant: String
        let coordinatorURL: String

        @State private var tfaCode = ""
        @FocusState private var codeFieldFocused: Bool

        var body: some View {
            NavigationStack {
                VStack(spacing: IOSSpacing.lg) {
                    Spacer()

                    // Shield icon
                    Image(systemName: "lock.shield")
                        .font(.system(size: 48))
                        .foregroundStyle(IOSColors.accent)

                    // Title
                    Text("Two-Factor Authentication")
                        .font(IOSTypography.title)
                        .multilineTextAlignment(.center)

                    // Body
                    Text("Enter the 6-digit verification code from your authenticator app.")
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                        .multilineTextAlignment(.center)

                    // Code input field
                    TextField("6-digit code", text: $tfaCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .focused($codeFieldFocused)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                codeFieldFocused = true
                            }
                        }

                    // Error text
                    if let tfaError = loginViewModel.tfaError {
                        HStack(spacing: IOSSpacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(IOSTypography.caption)
                            Text(tfaError.localizedDescription)
                                .font(IOSTypography.caption)
                        }
                        .foregroundStyle(IOSColors.statusError)
                    }

                    // Verify button
                    Button {
                        verify()
                    } label: {
                        if loginViewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Verify")
                        }
                    }
                    .buttonStyle(IOSPrimaryButtonStyle())
                    .disabled(tfaCode.isEmpty || loginViewModel.isLoading)

                    Spacer()
                }
                .padding(.horizontal, IOSSpacing.lg)
                .navigationTitle("Verify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: ds3Authentication.isLogged) { _, isLogged in
                if isLogged {
                    dismiss()
                }
            }
        }

        // MARK: - Actions

        private func verify() {
            loginViewModel.tfaError = nil

            let viewModel = loginViewModel
            let auth = ds3Authentication
            let tenantValue = (tenant.isEmpty || tenant == DefaultSettings.defaultTenantName) ? nil : tenant

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
                    // Error is handled by LoginViewModel's published properties
                }
            }
        }
    }

    #Preview {
        IOSMFAView(
            loginViewModel: LoginViewModel(),
            email: "test@cubbit.io",
            password: "test",
            tenant: "",
            coordinatorURL: CubbitAPIURLs.defaultCoordinatorURL
        )
        .environment(DS3Authentication())
    }
#endif

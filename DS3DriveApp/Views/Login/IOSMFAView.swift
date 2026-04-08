#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// 2FA code entry sheet. 6-box OTP input with auto-focus,
    /// `oneTimeCode` autofill, and auto-submit on completion.
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

        private let codeLength = 6
        private let buttonHeight: CGFloat = 54

        var body: some View {
            NavigationStack {
                ZStack {
                    IOSGradients.brandVerticalBackground
                        .ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 24) {
                            Spacer(minLength: 24)

                            // Shield icon
                            ZStack {
                                Circle()
                                    .fill(IOSColors.brandPrimary.opacity(0.12))
                                    .frame(width: 96, height: 96)

                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 44, weight: .regular))
                                    .foregroundStyle(IOSColors.brandPrimary)
                            }

                            // Title + body
                            VStack(spacing: 10) {
                                Text("Two-Factor Authentication")
                                    .font(.custom("Figtree-SemiBold", size: 24))
                                    .foregroundStyle(IOSColors.brandTextPrimary)
                                    .multilineTextAlignment(.center)

                                Text("Enter the 6-digit verification code from your authenticator app.")
                                    .font(.custom("Figtree-Regular", size: 16))
                                    .foregroundStyle(IOSColors.brandTextSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(2)
                                    .padding(.horizontal, 8)
                            }
                            .padding(.bottom, 8)

                            // OTP field — 6 boxes driven by a hidden TextField
                            otpBoxes
                                .padding(.horizontal, 4)

                            // Error text
                            if let tfaError = loginViewModel.tfaError {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 14))
                                    Text(tfaError.localizedDescription)
                                        .font(.custom("Figtree-Regular", size: 14))
                                        .multilineTextAlignment(.leading)
                                }
                                .foregroundStyle(IOSColors.statusError)
                                .transition(.opacity)
                            }

                            // Verify CTA
                            Button {
                                verify()
                            } label: {
                                ZStack {
                                    if loginViewModel.isLoading {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text("Verify")
                                            .font(.custom("Figtree-SemiBold", size: 17))
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: buttonHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(
                                            verifyDisabled
                                                ? IOSColors.brandPrimary.opacity(0.35)
                                                : IOSColors.brandPrimary
                                        )
                                )
                            }
                            .buttonStyle(PressableScale())
                            .disabled(verifyDisabled)
                            .padding(.top, 4)

                            Spacer(minLength: 24)
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity)
                        .animation(.easeInOut(duration: 0.25), value: loginViewModel.tfaError != nil)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .navigationTitle("Verify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .font(.custom("Figtree-Medium", size: 17))
                            .foregroundStyle(IOSColors.brandPrimary)
                    }
                }
            }
            .onChange(of: ds3Authentication.isLogged) { _, isLogged in
                if isLogged { dismiss() }
            }
        }

        // MARK: - OTP Boxes

        private var otpBoxes: some View {
            ZStack {
                // Visible decorative boxes underneath.
                HStack(spacing: 10) {
                    ForEach(0 ..< codeLength, id: \.self) { index in
                        otpBox(at: index)
                    }
                }
                .allowsHitTesting(false)

                // Full-size, near-invisible TextField on top so that taps,
                // long-press paste, and the system `oneTimeCode` autofill
                // bar all have a proper hit target spanning the OTP row.
                TextField("", text: $tfaCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFieldFocused)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(height: 60)
                    .contentShape(Rectangle())
                    .onChange(of: tfaCode) { _, newValue in
                        // Normalize first. If the normalized value differs
                        // from the incoming value, reassigning `tfaCode`
                        // re-triggers this handler — we must return early
                        // BEFORE calling `verify()` on the unnormalized
                        // path, otherwise `verify()` fires twice and
                        // submits two concurrent Tasks with the same code.
                        let filtered = newValue.filter(\.isNumber)
                        let clamped = String(filtered.prefix(codeLength))
                        if clamped != newValue {
                            tfaCode = clamped
                            return
                        }
                        loginViewModel.tfaError = nil
                        if clamped.count == codeLength { verify() }
                    }
            }
            .contextMenu {
                // Manual paste fallback — long-press the row to paste the
                // clipboard (digits only, clamped to the code length).
                // Always enabled: reading `UIPasteboard.general.string`
                // from a `.disabled(...)` predicate fires during every
                // body re-render and triggers the iOS 16+ pasteboard
                // access banner unnecessarily, so we let the user tap
                // and handle the empty case inside `pasteFromClipboard`.
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    codeFieldFocused = true
                }
            }
        }

        private func pasteFromClipboard() {
            guard let pasted = UIPasteboard.general.string else { return }
            let digits = String(pasted.filter(\.isNumber).prefix(codeLength))
            guard !digits.isEmpty else { return }
            tfaCode = digits
        }

        private func otpBox(at index: Int) -> some View {
            let digits = Array(tfaCode)
            let digit: String = index < digits.count ? String(digits[index]) : ""
            let isFilled = !digit.isEmpty
            let isCurrent = codeFieldFocused && index == digits.count && digits.count < codeLength

            return Text(digit)
                .font(.custom("Figtree-SemiBold", size: 26))
                .foregroundStyle(IOSColors.brandTextPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(isFilled ? 0.05 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isCurrent
                                ? IOSColors.brandPrimary
                                : (isFilled ? IOSColors.brandBorderStrong : IOSColors.brandBorderSubtle),
                            lineWidth: isCurrent ? 1.5 : 1
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: isFilled)
                .animation(.easeInOut(duration: 0.15), value: isCurrent)
        }

        // MARK: - State

        private var verifyDisabled: Bool {
            tfaCode.count != codeLength || loginViewModel.isLoading
        }

        // MARK: - Actions

        private func verify() {
            loginViewModel.tfaError = nil

            let viewModel = loginViewModel
            let auth = ds3Authentication
            let tenantValue = (tenant.isEmpty || tenant == DefaultSettings.defaultTenantName) ? nil : tenant

            Task {
                try? await viewModel.login(
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

    // MARK: - Pressable Scale

    /// Matches the login CTA press feedback.
    private struct PressableScale: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

// LoginView.swift
// Sign in with Apple + email (Supabase). Privacy consent required before sign-in.

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var mode: Mode = .landing
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var appeared = false
    @State private var dataConsentAccepted = false

    enum Mode { case landing, email }

    private var canSignIn: Bool { dataConsentAccepted && SupabaseConfig.isConfigured && !isLoading }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            RadialGradient(
                colors: [Color.red.opacity(0.18), Color.clear],
                center: .top, startRadius: 40, endRadius: 300
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 72)

                    logoBlock
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)
                        .animation(.easeOut(duration: 0.55).delay(0.08), value: appeared)

                    Spacer().frame(height: 36)

                    consentBlock
                        .padding(.horizontal, 32)
                        .padding(.bottom, 20)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.55).delay(0.18), value: appeared)

                    if !SupabaseConfig.isConfigured {
                        Text("Add Supabase keys in Secrets.xcconfig (see Secrets.example.xcconfig).")
                            .font(.caption)
                            .foregroundStyle(.orange.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 12)
                    }

                    Group {
                        if mode == .landing {
                            landingButtons
                        } else {
                            emailForm
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(.easeOut(duration: 0.55).delay(0.22), value: appeared)

                    if let msg = auth.lastErrorMessage ?? errorMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 14)
                    }

                    Spacer().frame(height: 48)
                }
            }
        }
        .onAppear {
            appeared = false
            withAnimation { appeared = true }
        }
    }

    // MARK: - Logo

    private var logoBlock: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 104, height: 104)
                Image(systemName: "film.stack")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.red)
            }

            Text("Pickr")
                .font(.system(size: 46, weight: .black))
                .foregroundColor(.white)
                .padding(.top, 22)

            Text("Stream Smarter")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .padding(.top, 8)

            Text("Sign in to sync your taste profile\nacross your devices.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Consent

    private var consentBlock: some View {
        Button {
            dataConsentAccepted.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: dataConsentAccepted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(dataConsentAccepted ? AppTheme.brand : .white.opacity(0.35))

                Text(consentAttributed)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Privacy and data collection consent")
        .accessibilityValue(dataConsentAccepted ? "Accepted" : "Not accepted")
    }

    private var consentAttributed: AttributedString {
        var text = AttributedString(
            "I agree to the Privacy Policy and allow Pickr to collect and use my data as described there, including syncing my taste profile across devices."
        )
        if let range = text.range(of: "Privacy Policy") {
            text[range].link = URL(string: "https://somers-cyber.github.io/pickr-legalv2/privacy-policy.html")
            text[range].foregroundColor = .white.opacity(0.92)
            text[range].underlineStyle = .single
        }
        return text
    }

    // MARK: - Landing

    private var landingButtons: some View {
        VStack(spacing: 14) {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await auth.handleAppleSignIn(result: result, dataShareConsent: dataConsentAccepted)
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .padding(.horizontal, 32)
            .opacity(canSignIn ? 1 : 0.45)
            .allowsHitTesting(canSignIn)

            HStack {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                Text("or").font(.caption).foregroundColor(.white.opacity(0.35)).padding(.horizontal, 10)
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            }
            .padding(.horizontal, 32)

            Button {
                isSignUp = false
                withAnimation(.easeInOut(duration: 0.25)) { mode = .email }
            } label: {
                Label("Continue with Email", systemImage: "envelope.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
            .opacity(canSignIn ? 1 : 0.45)
            .disabled(!canSignIn)

            Button {
                isSignUp = true
                withAnimation(.easeInOut(duration: 0.25)) { mode = .email }
            } label: {
                Text("New here? Create an account →")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.brand.opacity(canSignIn ? 0.85 : 0.4))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .disabled(!canSignIn)
        }
    }

    // MARK: - Email

    private var emailForm: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    errorMessage = nil
                    withAnimation(.easeInOut(duration: 0.2)) { mode = .landing }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSignUp.toggle()
                        errorMessage = nil
                    }
                } label: {
                    Text(isSignUp ? "Sign in instead" : "Create account")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.brand)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            Text(isSignUp ? "Create Account" : "Welcome Back")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)

            VStack(spacing: 12) {
                if isSignUp {
                    pickrTextField("Name (optional)", text: $displayName)
                        .textContentType(.name)
                        .autocapitalization(.words)
                }
                pickrTextField("Email", text: $email)
                    .textContentType(isSignUp ? .emailAddress : .username)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                pickrSecureField("Password \(isSignUp ? "(min. 8 chars)" : "")", text: $password)
                    .textContentType(isSignUp ? .newPassword : .password)
            }
            .padding(.horizontal, 32)

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
            }

            Button { submitEmailForm() } label: {
                ZStack {
                    if isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Text(isSignUp ? "Create Account" : "Sign In")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(!canSignIn)
            .opacity(canSignIn ? 1 : 0.45)
            .padding(.horizontal, 32)
            .padding(.top, 22)
        }
    }

    // MARK: - Actions

    private func submitEmailForm() {
        guard dataConsentAccepted else {
            errorMessage = AuthError.consentRequired.errorDescription
            return
        }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                if isSignUp {
                    try await auth.signUpWithEmail(email, password: password, displayName: displayName, dataShareConsent: true)
                } else {
                    try await auth.signInWithEmail(email, password: password, dataShareConsent: true)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: - Inputs

    private func pickrTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.35)))
            .font(.system(size: 16))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func pickrSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.35)))
            .font(.system(size: 16))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthManager.shared)
}

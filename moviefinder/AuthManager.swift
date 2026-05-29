// AuthManager.swift
// Sign in with Apple / email via Supabase Auth; profile + consent in `public.profiles`.

import AuthenticationServices
import Combine
import Foundation
import Supabase

// MARK: - User Profile

struct UserProfile: Codable, Equatable {
    var id: String
    var email: String?
    var displayName: String?

    var country: String?
    var ageGroup: AgeGroup?
    var gender: Gender?
    var marketingConsent: Bool = false
    var dataShareConsent: Bool = false
    var consentDate: Date?

    var createdAt: Date = Date()
    /// True after login + privacy consent (no demographic wizard).
    var profileComplete: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, email, displayName, country, ageGroup, gender
        case marketingConsent, dataShareConsent, consentDate, createdAt, profileComplete
    }
}

// Legacy enums (ProfileSetupView only — not collected in the login flow).
enum AgeGroup: String, Codable, CaseIterable, Identifiable {
    case under18 = "Under 18"
    case age18_24 = "18–24"
    case age25_34 = "25–34"
    case age35_44 = "35–44"
    case age45_54 = "45–54"
    case age55plus = "55+"
    var id: String { rawValue }
}

enum Gender: String, Codable, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"
    case nonBinary = "Non-binary"
    case preferNotToSay = "Prefer not to say"
    var id: String { rawValue }
}

// MARK: - AuthManager

@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isRestoringSession = true
    @Published var lastErrorMessage: String?

    private let profileKey = UserDefaultsKeys.userProfile
    private let loggedInKey = UserDefaultsKeys.isLoggedIn
    private var authListenerTask: Task<Void, Never>?
    /// Prevents the `.initialSession` auth-listener callback from spawning a second
    /// concurrent execution of `applySupabaseSession` while the first is still running.
    private var isApplyingSession = false

    private init() {
        loadLocalCache()
        Task { await restoreSessionIfNeeded() }
    }

    var supabaseUserId: UUID? {
        resolvedSupabaseUserId
    }

    /// Prefer the live Supabase session user id over cached profile metadata.
    var resolvedSupabaseUserId: UUID? {
        if let sessionId = SupabaseClientProvider.client?.auth.currentSession?.user.id {
            return sessionId
        }
        guard let id = profile?.id else { return nil }
        return UUID(uuidString: id)
    }

    // MARK: - Persistence (offline cache)

    private func loadLocalCache() {
        isLoggedIn = UserDefaults.standard.bool(forKey: loggedInKey)
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = decoded
        }
    }

    private func saveLocalCache() {
        UserDefaults.standard.set(isLoggedIn, forKey: loggedInKey)
        if let profile, let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    // MARK: - Session

    func restoreSessionIfNeeded() async {
        defer { isRestoringSession = false }
        guard SupabaseClientProvider.isConfigured, let client = SupabaseClientProvider.client else {
            // Missing Supabase keys in this build — cannot restore or sign in.
            if isLoggedIn {
                isLoggedIn = false
                profile = nil
                saveLocalCache()
            }
            return
        }

        startAuthStateListenerIfNeeded(client: client)

        do {
            let session = try await resolveRestoredSession(client: client)
            try await applySupabaseSession(session, dataShareConsent: profile?.dataShareConsent ?? false)
        } catch {
            // Keep the cached login on transient failures (offline launch, refresh in flight).
            // Only clear when the stored session is actually gone or revoked.
            if shouldClearSessionAfterRestoreFailure(error, client: client) {
                await clearLocalAuthState(signOutRemote: false)
            } else if isLoggedIn, profile != nil {
                saveLocalCache()
            }
        }
    }

    /// Prefer the keychain session; refresh only when expired.
    private func resolveRestoredSession(client: SupabaseClient) async throws -> Session {
        if let cached = client.auth.currentSession {
            if cached.isExpired {
                return try await client.auth.refreshSession()
            }
            return cached
        }
        return try await client.auth.session
    }

    private func shouldClearSessionAfterRestoreFailure(_ error: Error, client: SupabaseClient) -> Bool {
        if client.auth.currentSession != nil { return false }
        if let authError = error as? Supabase.AuthError {
            switch authError {
            case .sessionMissing:
                return true
            case let .api(_, code, _, _):
                switch code {
                case .sessionNotFound, .sessionExpired, .refreshTokenNotFound,
                     .refreshTokenAlreadyUsed, .userNotFound, .userBanned:
                    return true
                default:
                    return false
                }
            default:
                return false
            }
        }
        return false
    }

    private func startAuthStateListenerIfNeeded(client: SupabaseClient) {
        guard authListenerTask == nil else { return }
        authListenerTask = Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                await self.handleAuthStateChange(event: event, session: session)
            }
        }
    }

    private func handleAuthStateChange(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .signedOut:
            await clearLocalAuthState(signOutRemote: false)
        case .signedIn, .tokenRefreshed, .initialSession:
            guard let session else { return }
            try? await applySupabaseSession(session, dataShareConsent: profile?.dataShareConsent ?? false)
        case .userUpdated, .userDeleted, .passwordRecovery, .mfaChallengeVerified:
            break
        }
    }

    private func clearLocalAuthState(signOutRemote: Bool) async {
        // Auth listener `.signedOut` can fire after we already cleared local state — skip the second pass
        // so we don't re-persist empty globals over the user's scoped snapshot.
        guard isLoggedIn || profile != nil else { return }

        // Flush any pending swipe data before revoking the session so the
        // push is authenticated. flushPendingPush also cancels the debounce task.
        await SupabaseSyncService.shared.flushPendingPush()
        if signOutRemote, let client = SupabaseClientProvider.client {
            try? await client.auth.signOut()
        }
        AccountLocalState.clearOnSignOut()
        authListenerTask?.cancel()
        authListenerTask = nil
        isLoggedIn = false
        profile = nil
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.set(false, forKey: loggedInKey)
    }

    // MARK: - Sign In with Apple

    func handleAppleSignIn(result: Result<ASAuthorization, Error>, dataShareConsent: Bool) async {
        lastErrorMessage = nil
        guard dataShareConsent else {
            lastErrorMessage = "Please accept the Privacy Policy to continue."
            return
        }
        switch result {
        case .failure(let error):
            lastErrorMessage = error.localizedDescription
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
            guard let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                lastErrorMessage = "Could not read Apple identity token."
                return
            }
            await signInWithApple(idToken: idToken, credential: cred, dataShareConsent: dataShareConsent)
        }
    }

    private func signInWithApple(
        idToken: String,
        credential: ASAuthorizationAppleIDCredential,
        dataShareConsent: Bool
    ) async {
        guard let client = requireClient() else { return }
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken)
            )
            if let fullName = credential.fullName {
                let given = fullName.givenName ?? ""
                let family = fullName.familyName ?? ""
                let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                if !name.isEmpty {
                    _ = try? await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
                }
            }
            try await applySupabaseSession(session, dataShareConsent: dataShareConsent)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Email

    func signUpWithEmail(_ email: String, password: String, displayName: String, dataShareConsent: Bool) async throws {
        guard dataShareConsent else { throw AuthError.consentRequired }
        guard let client = requireClient() else { throw AuthError.notConfigured }
        guard !email.isEmpty, email.contains("@") else { throw AuthError.invalidEmail }
        guard password.count >= 8 else { throw AuthError.weakPassword }

        lastErrorMessage = nil
        let response = try await client.auth.signUp(email: email, password: password)
        if let session = response.session {
            try await applySupabaseSession(session, dataShareConsent: dataShareConsent, displayName: displayName.isEmpty ? nil : displayName)
        } else {
            lastErrorMessage = "Check your email to confirm your account, then sign in."
        }
    }

    func signInWithEmail(_ email: String, password: String, dataShareConsent: Bool) async throws {
        guard dataShareConsent else { throw AuthError.consentRequired }
        guard let client = requireClient() else { throw AuthError.notConfigured }
        guard !email.isEmpty, !password.isEmpty else { throw AuthError.invalidCredentials }

        lastErrorMessage = nil
        let session = try await client.auth.signIn(email: email, password: password)
        try await applySupabaseSession(session, dataShareConsent: dataShareConsent)
    }

    func updateProfile(_ updated: UserProfile) {
        profile = updated
        saveLocalCache()
        Task {
            try? await upsertRemoteProfile(updated)
        }
    }

    // MARK: - Sign out

    func signOut() async {
        await clearLocalAuthState(signOutRemote: true)
    }

    // MARK: - Supabase profile row

    private func applySupabaseSession(
        _ session: Session,
        dataShareConsent: Bool,
        displayName: String? = nil
    ) async throws {
        // The auth-state listener (emitLocalSessionAsInitialSession: true) fires an
        // .initialSession event at our first await, which would re-enter this function
        // concurrently and overwrite profile/consent with stale values.  The flag
        // serialises calls so only the first one runs; subsequent ones are dropped.
        guard !isApplyingSession else { return }
        isApplyingSession = true
        defer { isApplyingSession = false }

        let user = session.user
        let uid = user.id.uuidString

        // Assign profile id before activateUser so session handlers can mirror per-user state.
        var p = profile ?? UserProfile(id: uid)
        p.id = uid
        profile = p

        AccountLocalState.activateUser(uid)

        // Restart the auth-state listener if it was torn down during sign-out.
        if let client = SupabaseClientProvider.client {
            startAuthStateListenerIfNeeded(client: client)
        }

        p.email = user.email ?? p.email
        if let displayName, !displayName.isEmpty {
            p.displayName = displayName
        } else if (p.displayName ?? "").isEmpty {
            // Local cache was cleared on sign-out: recover display name without overwriting it with nil.
            // 1. Apple stores the full name in user metadata after the first sign-in.
            if let meta = user.userMetadata["full_name"],
               case .string(let name) = meta, !name.isEmpty {
                p.displayName = name
            } else if let client = SupabaseClientProvider.client {
                // 2. Email accounts have the name only in the remote profiles row.
                p.displayName = await fetchRemoteDisplayName(userId: user.id, client: client)
            }
        }
        let device = DeviceMetadata.current()
        p.country = device.country
        p.dataShareConsent = dataShareConsent
        if p.consentDate == nil {
            p.consentDate = Date()
        }
        p.profileComplete = true
        profile = p
        isLoggedIn = true
        saveLocalCache()
        try await upsertRemoteProfile(p)
    }

    private func fetchRemoteDisplayName(userId: UUID, client: SupabaseClient) async -> String? {
        struct Row: Decodable { let display_name: String? }
        let rows: [Row] = (try? await client
            .from("profiles")
            .select("display_name")
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value) ?? []
        guard let name = rows.first?.display_name, !name.isEmpty else { return nil }
        return name
    }

    private func upsertRemoteProfile(_ p: UserProfile) async throws {
        guard let client = SupabaseClientProvider.client,
              let userId = UUID(uuidString: p.id) else { return }

        let row = SupabaseProfileRow(
            id: userId,
            email: p.email,
            display_name: p.displayName,
            country: p.country,
            marketing_consent: p.marketingConsent,
            data_share_consent: p.dataShareConsent,
            consent_date: p.consentDate,
            profile_complete: p.profileComplete
        )
        try await client.from("profiles").upsert(row).execute()
    }

  private func requireClient() -> SupabaseClient? {
        guard let client = SupabaseClientProvider.client else {
            lastErrorMessage = AuthError.notConfigured.errorDescription
            return nil
        }
        return client
    }
}

// MARK: - Supabase DTO

private struct SupabaseProfileRow: Encodable {
    let id: UUID
    let email: String?
    let display_name: String?
    let country: String?
    let marketing_consent: Bool
    let data_share_consent: Bool
    let consent_date: Date?
    let profile_complete: Bool

    // Custom encode so nil Optionals are *omitted* from the JSON body rather than
    // sent as explicit `null`.  Supabase upsert only updates columns present in the
    // payload, so omitting a key leaves the existing DB value untouched — preventing
    // a re-login from overwriting display_name / email / etc. with NULL.
    private enum CodingKeys: String, CodingKey {
        case id, email, display_name, country
        case marketing_consent, data_share_consent, consent_date, profile_complete
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                  forKey: .id)
        try c.encodeIfPresent(email,       forKey: .email)
        try c.encodeIfPresent(display_name, forKey: .display_name)
        try c.encodeIfPresent(country,     forKey: .country)
        try c.encode(marketing_consent,    forKey: .marketing_consent)
        try c.encode(data_share_consent,   forKey: .data_share_consent)
        try c.encodeIfPresent(consent_date, forKey: .consent_date)
        try c.encode(profile_complete,     forKey: .profile_complete)
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case invalidEmail
    case weakPassword
    case invalidCredentials
    case consentRequired
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidEmail:       return "Please enter a valid email address."
        case .weakPassword:       return "Password must be at least 8 characters."
        case .invalidCredentials: return "Email or password is incorrect."
        case .consentRequired:    return "Please accept the Privacy Policy to continue."
        case .notConfigured:      return "Supabase is not configured. Add Secrets.xcconfig (see Secrets.example.xcconfig)."
        }
    }
}

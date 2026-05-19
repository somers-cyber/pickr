// moviefinderApp.swift
// App entry point — delete Xcode's generated ContentView.swift before using this

import SwiftUI

@main
struct moviefinderApp: App {
    @StateObject private var auth = AuthManager.shared

    init() {
        AppTheme.configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(AppTheme.brand)
                .environmentObject(auth)
        }
    }
}

// MARK: - Root View

/// Set to `true` to re-enable the login / profile-setup gate.
/// All auth code is preserved — flipping this back on restores the full flow.
private let authEnabled = true

struct RootView: View {
    // Shared state owned at the root — passed down as EnvironmentObjects
    @StateObject private var engine: RecommendationEngine
    @StateObject private var prefs: StreamingPreferences
    @StateObject private var discoverVM: DiscoverViewModel
    @StateObject private var watchNowVM: WatchNowViewModel

    // Auth gate (kept for when authEnabled = true)
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.scenePhase) private var scenePhase

    /// Legacy welcome / services (only if never completed).
    @AppStorage("onboarding_complete") private var onboardingComplete = false
    /// Mirrored from per-account storage in `AccountLocalState` (see `reloadAccountUIState`).
    @State private var genreOnboardingComplete = UserDefaults.standard.bool(forKey: "genre_onboarding_complete")
    @State private var appIntroComplete = UserDefaults.standard.bool(forKey: AppIntroStorage.completeKey)
    @State private var showGenreOnboardingSheet = false
    @State private var showLaunchSplash = true
    @State private var showAppIntro = false
    @State private var didScheduleLaunchSplashEnd = false
    /// Prevents duplicate Supabase pull/push on login + session restore.
    @State private var hasCompletedPostAuthSync = false

    init() {
        let ud = UserDefaults.standard
        // Upgrades: users who already finished onboarding before genre prefs existed skip the new screen.
        if ud.bool(forKey: "onboarding_complete"), ud.object(forKey: "genre_onboarding_complete") == nil {
            ud.set(true, forKey: "genre_onboarding_complete")
        }
        // Upgrades: existing users skip the new app intro tour.
        if ud.object(forKey: AppIntroStorage.completeKey) == nil,
           ud.bool(forKey: "genre_onboarding_complete") || ud.bool(forKey: "onboarding_complete") {
            ud.set(true, forKey: AppIntroStorage.completeKey)
        }
        let eng = RecommendationEngine()
        let prf = StreamingPreferences()
        _engine = StateObject(wrappedValue: eng)
        _prefs = StateObject(wrappedValue: prf)
        _discoverVM = StateObject(wrappedValue: DiscoverViewModel(engine: eng, prefs: prf))
        _watchNowVM = StateObject(wrappedValue: WatchNowViewModel(engine: eng, prefs: prf))

        // One-time migration: import existing swipe history + liked IDs + detail feedback
        // into EvaluationsStore so Archives shows full history from before this update.
        EvaluationsStore.shared.migrateIfNeeded(
            likedIds:      eng.profile.likedIds,
            swipeHistory:  eng.profile.swipeHistory,
            detailFeedback: {
                // Read the raw feedback map from MovieDetailFeedbackStore
                var map: [Int: MovieDetailFeedback] = [:]
                for id in MovieDetailFeedbackStore.shared.allLikedIds()    { map[id] = .liked }
                for id in MovieDetailFeedbackStore.shared.allDislikedIds() { map[id] = .disliked }
                return map
            }()
        )
    }

    var body: some View {
        Group {
            if authEnabled && auth.isRestoringSession {
                ZStack {
                    Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }

            } else if authEnabled && !auth.isLoggedIn {
                LoginView()

            } else {
                // ── Fully authenticated → main app ───────────────────────
                ZStack {
                    if appIntroComplete {
                        MainTabView()
                            .environmentObject(engine)
                            .environmentObject(prefs)
                            .environmentObject(discoverVM)
                            .environmentObject(watchNowVM)
                            .transition(.opacity)
                    }

                    if showLaunchSplash {
                        PickrLaunchSplashView()
                            .transition(.opacity)
                            .zIndex(2)
                    } else if showAppIntro {
                        AppIntroTourView {
                            if let uid = auth.profile?.id {
                                AccountLocalState.setOnboardingFlag(AppIntroStorage.completeKey, value: true, userId: uid)
                            } else {
                                UserDefaults.standard.set(true, forKey: AppIntroStorage.completeKey)
                            }
                            withAnimation(.easeInOut(duration: 0.4)) {
                                reloadAccountUIState()
                                showAppIntro = false
                            }
                            presentGenreOnboardingIfNeeded()
                        }
                        .transition(.opacity)
                        .zIndex(1)
                    }
                }
                .background(Color(red: 0.07, green: 0.07, blue: 0.09))
                .sheet(isPresented: $showGenreOnboardingSheet) {
                    NavigationStack {
                        GenreOnboardingView(
                            genrePrefs: GenrePreferencesStore.shared,
                            libraryService: MovieLibraryService.shared
                        ) {
                            let gp = GenrePreferencesStore.shared.genrePreferences
                            let buckets = GenreCatalog.engineOnboardingGenreIds(from: gp)
                            if !engine.profile.onboardingComplete {
                                engine.applyOnboardingGenres(
                                    loved: buckets.loved,
                                    liked: buckets.liked,
                                    disliked: buckets.disliked
                                )
                            }
                            if let uid = auth.profile?.id {
                                AccountLocalState.setOnboardingFlag("genre_onboarding_complete", value: true, userId: uid)
                                AccountLocalState.setOnboardingFlag("onboarding_complete", value: true, userId: uid)
                            } else {
                                UserDefaults.standard.set(true, forKey: "genre_onboarding_complete")
                                UserDefaults.standard.set(true, forKey: "onboarding_complete")
                            }
                            reloadAccountUIState()
                            showGenreOnboardingSheet = false
                        }
                        .environmentObject(engine)
                        .environmentObject(prefs)
                        .navigationTitle("Genre Preferences")
                        .navigationBarTitleDisplayMode(.inline)
                        .task {
                            await MovieLibraryService.shared.downloadIfNeeded()
                        }
                    }
                    .interactiveDismissDisabled(true)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
                .onAppear {
                    guard !didScheduleLaunchSplashEnd else { return }
                    didScheduleLaunchSplashEnd = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                        withAnimation(.easeOut(duration: 0.4)) {
                            showLaunchSplash = false
                        }
                        if !appIntroComplete {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                showAppIntro = true
                            }
                        } else {
                            presentGenreOnboardingIfNeeded()
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: onboardingComplete)
                .animation(.easeInOut(duration: 0.4), value: genreOnboardingComplete)
                .animation(.easeInOut(duration: 0.4), value: appIntroComplete)
                .onChange(of: auth.isLoggedIn, initial: false) { _, loggedIn in
                    if loggedIn {
                        schedulePostAuthSetupIfNeeded()
                    } else {
                        hasCompletedPostAuthSync = false
                    }
                }
                .onChange(of: auth.isRestoringSession) { _, restoring in
                    if !restoring {
                        schedulePostAuthSetupIfNeeded()
                    }
                }
                .onAppear {
                    SupabaseSyncService.shared.register(engine: engine)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard auth.isLoggedIn, !auth.isRestoringSession else { return }
                    if phase == .background {
                        Task { await SupabaseSyncService.shared.flushPendingPush() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
                    reloadAccountUIState()
                    if auth.isLoggedIn {
                        showAppIntro = !appIntroComplete
                    }
                }
            }
        }
        .animation(authEnabled ? .easeInOut(duration: 0.4) : nil, value: auth.isLoggedIn)
        .animation(authEnabled ? .easeInOut(duration: 0.35) : nil, value: auth.isRestoringSession)
    }

    private func schedulePostAuthSetupIfNeeded() {
        guard auth.isLoggedIn, !auth.isRestoringSession, !hasCompletedPostAuthSync else { return }
        hasCompletedPostAuthSync = true
        reloadAccountUIState()
        Task { await finishAccountSignIn() }
    }

    private func reloadAccountUIState() {
        if let uid = auth.profile?.id {
            AccountLocalState.mirrorOnboardingFlagsToGlobals(for: uid)
        }
        appIntroComplete = AccountLocalState.globalBool(AppIntroStorage.completeKey)
        genreOnboardingComplete = AccountLocalState.globalBool("genre_onboarding_complete")
        onboardingComplete = AccountLocalState.globalBool("onboarding_complete")
        engine.profile = ProfileStorage.shared.load()
        discoverVM.syncTrainingStateAfterProfileReload()
    }

    private func finishAccountSignIn() async {
        await SupabaseSyncService.shared.syncAfterLogin(
            engine: engine,
            watchlist: WatchlistStore.shared
        )
        reloadAccountUIState()
        await discoverVM.refresh()
        watchNowVM.scheduleGeneratePicks()
        if !appIntroComplete {
            withAnimation(.easeOut(duration: 0.35)) {
                showAppIntro = true
            }
        } else {
            presentGenreOnboardingIfNeeded()
        }
    }

    private func presentGenreOnboardingIfNeeded() {
        guard genreOnboardingComplete == false else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            showGenreOnboardingSheet = true
        }
    }
}

// MARK: - Launch splash (Pickr brand — no controls; matches onboarding welcome look)

private struct PickrLaunchSplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.red.opacity(0.15),
                    Color.clear
                ],
                center: .top,
                startRadius: 40,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 90)

                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.10))
                        .frame(width: 120, height: 120)
                    Image(systemName: "film.stack")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundColor(.red)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.easeOut(duration: 0.55).delay(0.08), value: appeared)

                Text("Pickr")
                    .font(.system(size: 52, weight: .black, design: .default))
                    .foregroundColor(.white)
                    .padding(.top, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.55).delay(0.2), value: appeared)

                Text("Stream Smarter")
                    .font(.system(size: 23, weight: .semibold, design: .default))
                    .foregroundColor(.white.opacity(0.80))
                    .tracking(0.3)
                    .padding(.top, 10)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.55).delay(0.3), value: appeared)

                Spacer()
            }
        }
        .onAppear {
            appeared = false
            withAnimation {
                appeared = true
            }
        }
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var engine:    RecommendationEngine
    @EnvironmentObject var prefs:     StreamingPreferences
    @EnvironmentObject var discoverVM: DiscoverViewModel
    @EnvironmentObject var watchNowVM: WatchNowViewModel

    @AppStorage("watch_now_services_intro_complete") private var watchNowServicesIntroComplete = false
    /// Cold launch: open Watch Now when Curate training is already done. In-session unlock keeps `tab` at 0 (Curate).
    @State private var tab: Int = {
        UserDefaults.standard.bool(forKey: "training_complete") ? 1 : 0
    }()
    /// When true, `WatchNowView` presents the Services sheet once (first visit to Watch Now tab).
    @State private var triggerWatchNowServicesIntro = false

    var body: some View {
        Group {
            if discoverVM.isInTrainingMode {
                TabView(selection: $tab) {
                    DiscoverView(vm: discoverVM)
                        .tabItem { Label("Curate", systemImage: "square.stack.3d.up.fill") }
                        .tag(0)
                }
                .tint(.primary)
                .toolbar(.hidden, for: .tabBar)
            } else {
                TabView(selection: $tab) {
                    DiscoverView(vm: discoverVM)
                        .tabItem { Label("Curate", systemImage: "square.stack.3d.up.fill") }
                        .tag(0)

                    WatchNowView(vm: watchNowVM, triggerServicesIntroFromTab: $triggerWatchNowServicesIntro)
                        .environmentObject(engine)
                        .environmentObject(prefs)
                        .tabItem { Label("Watch Now", systemImage: tab == 1 ? "play.rectangle.fill" : "play.rectangle") }
                        .tag(1)

                    WatchlistView()
                        .environmentObject(engine)
                        .tabItem { Label("Watchlist", systemImage: tab == 2 ? "bookmark.fill" : "bookmark") }
                        .tag(2)

                    ArchivesView()
                        .environmentObject(engine)
                        .environmentObject(prefs)
                        .environmentObject(discoverVM)
                        .tabItem { Label("Archives", systemImage: tab == 3 ? "tray.fill" : "tray") }
                        .tag(3)
                }
                .tint(.primary)
            }
        }
        .environmentObject(WatchlistStore.shared)
        .animation(.easeInOut, value: discoverVM.isInTrainingMode)
        .onAppear {
            requestWatchNowServicesIntroIfNeeded(for: tab)
        }
        .onChange(of: tab) { _, newTab in
            requestWatchNowServicesIntroIfNeeded(for: newTab)
        }
        .onChange(of: discoverVM.isInTrainingMode) { _, inTraining in
            if inTraining { tab = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
            tab = UserDefaults.standard.bool(forKey: "training_complete") ? 1 : 0
        }
    }

    private func requestWatchNowServicesIntroIfNeeded(for selectedTab: Int) {
        guard selectedTab == 1, !watchNowServicesIntroComplete else { return }
        triggerWatchNowServicesIntro = true
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @EnvironmentObject var prefs: StreamingPreferences
    var onComplete: () -> Void

    @State private var step = 0   // 0 = welcome, 1 = services, 2 = done
    @State private var appeared = false
    @State private var doneScreenAppeared = false

    var body: some View {
        Group {
            switch step {
            case 0: welcomeScreen
            case 1: servicesScreen
            default: doneScreen
            }
        }
        .animation(.easeInOut(duration: 0.35), value: step)
    }

    /// Large vertical padding + full-width frame so the primary onboarding CTAs are easy to tap.
    private func onboardingPrimaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var welcomeScreen: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.red.opacity(0.15),
                    Color.clear
                ],
                center: .top,
                startRadius: 40,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 90)

                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.10))
                        .frame(width: 120, height: 120)
                    Image(systemName: "film.stack")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundColor(.red)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.easeOut(duration: 0.6).delay(0.1), value: appeared)

                Text("Pickr")
                    .font(.system(size: 52, weight: .black, design: .default))
                    .foregroundColor(.white)
                    .padding(.top, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.6).delay(0.25), value: appeared)

                Text("Stream Smarter")
                    .font(.system(size: 23, weight: .semibold, design: .default))
                    .foregroundColor(.white.opacity(0.80))
                    .tracking(0.3)
                    .padding(.top, 10)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.6).delay(0.35), value: appeared)

                Spacer()

                Text("Find something worth watching - fast.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.white.opacity(0.78))
                    .padding(.bottom, 18)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.6).delay(0.42), value: appeared)

                VStack(spacing: 12) {
                    onboardingPrimaryButton("Get Started") { step = 1 }

                    Button("Skip setup") { onComplete() }
                        .foregroundColor(.white.opacity(0.40))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 72)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.easeOut(duration: 0.6).delay(0.5), value: appeared)
            }
        }
        .onAppear {
            appeared = false
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                appeared = true
            }
        }
    }

    private var servicesScreen: some View {
        VStack {
            ServicesPickerView(prefs: prefs) { step = 2 }
        }
    }

    private var doneScreen: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.red.opacity(0.15),
                    Color.clear
                ],
                center: .top,
                startRadius: 40,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 90)

                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.10))
                        .frame(width: 120, height: 120)
                    Image(systemName: "film.stack")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundColor(.red)
                }
                .opacity(doneScreenAppeared ? 1 : 0)
                .offset(y: doneScreenAppeared ? 0 : 14)
                .animation(.easeOut(duration: 0.6).delay(0.1), value: doneScreenAppeared)

                Text("Action!")
                    .font(.system(size: 52, weight: .black, design: .default))
                    .foregroundColor(.white)
                    .padding(.top, 28)
                    .opacity(doneScreenAppeared ? 1 : 0)
                    .offset(y: doneScreenAppeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.6).delay(0.25), value: doneScreenAppeared)

                Spacer()

                VStack(alignment: .center, spacing: 6) {
                    Text("Swipe right to like,")
                    Text("Swipe left to dislike,")
                    Text("Swipe up to add to your Watchlist.")
                }
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)
                .opacity(doneScreenAppeared ? 1 : 0)
                .offset(y: doneScreenAppeared ? 0 : 14)
                .animation(.easeOut(duration: 0.6).delay(0.35), value: doneScreenAppeared)

                onboardingPrimaryButton("Start Discovering →") { onComplete() }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 72)
                    .opacity(doneScreenAppeared ? 1 : 0)
                    .offset(y: doneScreenAppeared ? 0 : 14)
                    .animation(.easeOut(duration: 0.6).delay(0.42), value: doneScreenAppeared)
            }
        }
        .onAppear {
            doneScreenAppeared = false
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                doneScreenAppeared = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RootView()
}

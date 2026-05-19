// SettingsView.swift
// Settings tab — profile stats, services, recalibration, account

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject var engine: RecommendationEngine
    @EnvironmentObject var prefs:  StreamingPreferences
    @EnvironmentObject var discoverVM: DiscoverViewModel
    @EnvironmentObject private var auth: AuthManager

    @State private var showRecalConfirm = false
    @State private var showResetConfirm = false
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                profileSection
                recommendationSection
                aboutSection
                #if DEBUG
                debugEngineSection
                #endif
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("Recalibrate Taste?", isPresented: $showRecalConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Recalibrate", role: .destructive) {
                    engine.resetForRecalibration()
                    Task { await discoverVM.refresh() }
                }
            } message: {
                Text("Your genre, actor, and director preferences will reset. Movies you've already seen won't reappear.")
            }
            .alert("Sign Out?", isPresented: $showSignOutConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    Task { await auth.signOut() }
                }
            } message: {
                Text("You can sign in again to sync your profile from the cloud.")
            }
            .alert("Full Reset?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Everything", role: .destructive) {
                    DiscoverViewModel.resetTrainingProgressForFullReset()
                    engine.fullReset()
                    WatchlistStore.shared.removeAll()
                    discoverVM.syncTrainingStateAfterProfileReload()
                    MovieDetailFeedbackStore.shared.clearAll()
                    MovieDetailEngineRecordStore.shared.clearAll()
                    EvaluationsStore.shared.clearAll()
                    GenrePreferencesStore.shared.resetToDefaults()
                    prefs.clearAll()
                    UserDefaults.standard.set(false, forKey: "genre_onboarding_complete")
                    UserDefaults.standard.set(false, forKey: "onboarding_complete")
                    UserDefaults.standard.set(false, forKey: "watch_now_services_intro_complete")
                    UserDefaults.standard.set(false, forKey: "watch_now_info_coach_dismissed")
                    UserDefaults.standard.set(false, forKey: "discover_swipe_coach_dismissed")
                    AppIntroStorage.resetForDebug()
                    Task { await auth.signOut() }
                    Task { await discoverVM.refresh() }
                }
            } message: {
                Text("All preferences, seen history, and watchlist will be cleared. This cannot be undone.")
            }
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section {
            if let email = auth.profile?.email, !email.isEmpty {
                stat("Account", email)
            } else if let name = auth.profile?.displayName, !name.isEmpty {
                stat("Account", name)
            }
            Button("Sign out", role: .destructive) {
                showSignOutConfirm = true
            }
        } header: {
            settingsSectionHeader("Account")
        }
    }

    private var profileSection: some View {
        Section {
            stat("Total swipes",  "\(engine.profile.totalSwipes)")
            stat("Liked movies",  "\(engine.profile.likedIds.count)")
            stat("Movies seen",   "\(engine.profile.seenIds.count)")

            profileStrengthRow
        } header: {
            settingsSectionHeader("Taste profile")
        }
    }

    private var recommendationSection: some View {
        Section {
            Button("Recalibrate taste") { showRecalConfirm = true }
                .foregroundStyle(.orange)
            Button("Full reset") { showResetConfirm = true }
                .foregroundStyle(.red)
        } header: {
            settingsSectionHeader("Recommendations")
        }
    }

    private static let supportEmailURL = URL(string: "mailto:support@pickrmovies.com")!

    private var aboutSection: some View {
        Section {
            stat("Version", appVersionString)
            Link("Contact support", destination: Self.supportEmailURL)
            Link("Privacy Policy", destination: URL(string: "https://somers-cyber.github.io/pickr-legalv2/privacy-policy.html")!)
        } header: {
            settingsSectionHeader("About")
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Movie data provided by TMDB")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org")!)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        } header: {
            settingsSectionHeader("Acknowledgements")
        }
    }

    #if DEBUG
    private var debugEngineSection: some View {
        Section("Debug — Engine State") {
            stat("Total swipes", "\(engine.profile.totalSwipes)")
            stat("Seen movies", "\(engine.profile.seenIds.count)")
            stat("Liked IDs count", "\(engine.profile.likedIds.count)")

            let topGenres = engine.profile.genreWeights
                .sorted { $0.value > $1.value }
                .prefix(5)
            ForEach(Array(topGenres), id: \.key) { pair in
                stat("Genre \(pair.key)", String(format: "%.3f", pair.value))
            }

            let bottomGenres = engine.profile.genreWeights
                .sorted { $0.value < $1.value }
                .prefix(3)
            ForEach(Array(bottomGenres), id: \.key) { pair in
                stat("Genre \(pair.key) ↓", String(format: "%.3f", pair.value))
            }

            stat("Onboarding complete", "\(engine.profile.onboardingComplete)")
            stat("Loved genres", engine.profile.onboardingLoved.map(String.init).joined(separator: ", "))
            stat("Disliked genres", engine.profile.onboardingDisliked.map(String.init).joined(separator: ", "))
            stat("Swipe history count", "\(engine.profile.swipeHistory.count)")
            stat("Training complete", "\(!discoverVM.isInTrainingMode)")

            Button("Copy profile JSON to clipboard") {
                if let data = try? JSONEncoder().encode(engine.profile),
                   let json = String(data: data, encoding: .utf8) {
                    UIPasteboard.general.string = json
                }
            }
            .foregroundColor(.blue)
        }
    }
    #endif

    // MARK: Helpers

    private var appVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.primary.opacity(0.62))
            .tracking(0.7)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Same tiers and bar as Discover’s non-training accuracy badge (`DiscoverViewModel.accuracyBarBadge`).
    private var profileStrengthRow: some View {
        let swipes = engine.profile.totalSwipes
        let (label, color, ratio): (String, Color, Double) = {
            switch swipes {
            case 0:
                return ("Not Started", Color.gray, 0.0)
            case 1..<5:
                return ("Warming Up", Color.gray, Double(swipes) / 5.0 * 0.15)
            case 5..<20:
                return ("Learning", Color.orange, 0.15 + (Double(swipes) - 5) / 15.0 * 0.35)
            case 20..<50:
                return ("Tuned", Color.blue, 0.50 + (Double(swipes) - 20) / 30.0 * 0.35)
            default:
                return ("Dialed In", Color.green, 1.0)
            }
        }()
        let barW = profileStrengthBarWidth
        let fillW = max(swipes == 0 ? 0 : 4, barW * ratio)
        return HStack(alignment: .center) {
            Text("Profile strength")
                .font(.body)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.22))
                        .frame(width: barW, height: 8)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.95), color.opacity(0.65)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillW, height: 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: ratio)
                }
                .frame(width: barW, height: 8)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(color)
                    .animation(.easeInOut(duration: 0.3), value: label)
            }
        }
    }

    /// Mirrors `DiscoverHeaderLayout.barContainerWidth` (middle third of screen, min 120).
    private var profileStrengthBarWidth: CGFloat {
        #if canImport(UIKit)
        let w = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width
        if let w, w > 0 { return max(120, w / 3) }
        #endif
        return 120
    }
}

#Preview {
    SettingsView()
        .environmentObject(RecommendationEngine())
        .environmentObject(StreamingPreferences())
        .environmentObject(DiscoverViewModel(engine: RecommendationEngine(), prefs: StreamingPreferences()))
}

// AccountLocalState.swift
// Isolates on-device taste/history/onboarding per Supabase user id.

import Foundation

extension Notification.Name {
    /// Posted after sign-in user change or sign-out wipe. RootView resets engine + UI flags.
    static let accountSessionDidChange = Notification.Name("pickr_accountSessionDidChange")
}

enum AccountLocalState {

    private static let lastUserIdKey = "pickr_last_signed_in_user_id"

    /// UserDefaults keys mirrored to globals (`@AppStorage` / legacy reads) per active user.
    private static let onboardingFlagBases = [
        "genre_onboarding_complete",
        "onboarding_complete",
        AppIntroStorage.completeKey,
        "training_complete",
        "watch_now_services_intro_complete",
        "watch_now_info_coach_dismissed",
        "discover_swipe_coach_dismissed",
    ]

    private static let trainingValidSwipeCountBase = "training_valid_swipe_count"

    // MARK: - Session

    /// Call when a Supabase session becomes active (new sign-in or restore).
    static func activateUser(_ userId: String) {
        let previous = UserDefaults.standard.string(forKey: lastUserIdKey)
        if previous != userId {
            wipeSharedUserData()
            UserDefaults.standard.set(userId, forKey: lastUserIdKey)
        }
        mirrorOnboardingFlagsToGlobals(for: userId)
        postSessionDidChange()
    }

    /// Call on sign-out — clears taste/history; keeps last user id so the next login can detect a switch.
    static func clearOnSignOut() {
        wipeSharedUserData()
        mirrorOnboardingFlagsToGlobalsForLoggedOut()
        postSessionDidChange()
    }

    static var lastSignedInUserId: String? {
        UserDefaults.standard.string(forKey: lastUserIdKey)
    }

    // MARK: - Onboarding flags (per user + global mirror)

    static func setOnboardingFlag(_ base: String, value: Bool, userId: String?) {
        UserDefaults.standard.set(value, forKey: base)
        if let userId {
            UserDefaults.standard.set(value, forKey: scopedKey(base, userId: userId))
        }
    }

    /// Persists a global onboarding flag and mirrors it to the active account (coaches, etc.).
    static func persistOnboardingFlag(_ base: String, value: Bool) {
        setOnboardingFlag(base, value: value, userId: lastSignedInUserId)
    }

    static func persistTrainingSwipeCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: trainingValidSwipeCountBase)
        if let userId = lastSignedInUserId {
            UserDefaults.standard.set(count, forKey: scopedKey(trainingValidSwipeCountBase, userId: userId))
        }
    }

    static func globalBool(_ base: String) -> Bool {
        UserDefaults.standard.bool(forKey: base)
    }

    /// Copies global onboarding/training flags into the active user's scoped keys (after Curate training, coaches, etc.).
    static func persistGlobalsToScopedUser() {
        guard let userId = lastSignedInUserId else { return }
        let ud = UserDefaults.standard
        for base in onboardingFlagBases {
            ud.set(ud.bool(forKey: base), forKey: scopedKey(base, userId: userId))
        }
        ud.set(ud.integer(forKey: trainingValidSwipeCountBase), forKey: scopedKey(trainingValidSwipeCountBase, userId: userId))
    }

    static func mirrorOnboardingFlagsToGlobals(for userId: String) {
        let ud = UserDefaults.standard
        for base in onboardingFlagBases {
            ud.set(ud.bool(forKey: scopedKey(base, userId: userId)), forKey: base)
        }
        let scopedCount = ud.integer(forKey: scopedKey(trainingValidSwipeCountBase, userId: userId))
        if ud.object(forKey: scopedKey(trainingValidSwipeCountBase, userId: userId)) != nil {
            ud.set(scopedCount, forKey: trainingValidSwipeCountBase)
        } else {
            ud.removeObject(forKey: trainingValidSwipeCountBase)
        }
    }

    private static func mirrorOnboardingFlagsToGlobalsForLoggedOut() {
        let ud = UserDefaults.standard
        for base in onboardingFlagBases {
            ud.set(false, forKey: base)
        }
        ud.removeObject(forKey: trainingValidSwipeCountBase)
    }

    // MARK: - Wipe local taste / history (not auth)

    @MainActor
    static func wipeSharedUserData() {
        StreamingPreferences.clearAllPersistedSelections()
        UserDefaults.standard.removeObject(forKey: "taste_profile_v2")
        DiscoverViewModel.resetTrainingProgressForFullReset()
        WatchlistStore.shared.removeAll()
        EvaluationsStore.shared.clearAll()
        MovieDetailFeedbackStore.shared.clearAll()
        MovieDetailEngineRecordStore.shared.clearAll()
        GenrePreferencesStore.shared.resetToDefaults()
    }

    // MARK: - Private

    private static func scopedKey(_ base: String, userId: String) -> String {
        "\(base)_\(userId)"
    }

    private static func postSessionDidChange() {
        NotificationCenter.default.post(name: .accountSessionDidChange, object: nil)
    }
}

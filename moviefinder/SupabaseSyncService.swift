// SupabaseSyncService.swift
// Pull / push taste profile + watchlist for signed-in users.

import Foundation
import Supabase

extension ProcessInfo {
    var isRunningXCTest: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
final class SupabaseSyncService {

    static let shared = SupabaseSyncService()

    private weak var engine: RecommendationEngine?
    private var debounceTask: Task<Void, Never>?
    private var isApplyingRemotePull = false
    private var hasPendingRegistrationPush = false
    private var isPushInProgress = false
    private var hasPendingFollowUpPush = false

    /// Coalesce rapid swipes / watchlist edits before uploading.
    private let debounceInterval: Duration = .seconds(2.5)

    private init() {}

    func register(engine: RecommendationEngine) {
        self.engine = engine
        if hasPendingRegistrationPush {
            hasPendingRegistrationPush = false
            schedulePushFromLocalChange()
        }
    }

    private struct PullResult {
        var tasteSucceeded = false
        var watchlistSucceeded = false
        var appStateSucceeded = false
    }

    /// Call after a successful login or session restore.
    func syncAfterLogin(engine: RecommendationEngine, watchlist: WatchlistStore) async {
        register(engine: engine)
        // Mirror the flushPendingPush pattern: if a push is actively making network
        // requests, await its completion rather than cancelling it — cancelling a Task
        // mid-request propagates as NSURLErrorCancelled (-999) through the URLSession task.
        if isPushInProgress {
            await debounceTask?.value
        } else {
            debounceTask?.cancel()
        }
        debounceTask = nil
        isApplyingRemotePull = true
        defer {
            isApplyingRemotePull = false
            // Fire any push that was deferred while the pull was in flight
            // (e.g. swipes made during the login sync window).
            if hasPendingFollowUpPush {
                hasPendingFollowUpPush = false
                schedulePushFromLocalChange()
            }
        }
        guard SupabaseClientProvider.isConfigured, AuthManager.shared.isLoggedIn else { return }
        guard activeUserId() != nil else { return }

        let localTasteBeforePull = hasMeaningfulTaste(engine.profile)
        let localWatchlistBeforePull = !watchlist.allIds().isEmpty

        let pull = await pullRemote(into: engine, watchlist: watchlist)

        applyEngineFromSyncedGenrePrefs(engine: engine)
        EvaluationsStore.shared.syncFromTasteProfile(engine.profile)
        ProfileStorage.shared.save(engine.profile)
        AccountLocalState.persistAllStateToScoped()

        await pushAfterLoginPull(
            engine: engine,
            watchlist: watchlist,
            pull: pull,
            hadLocalTaste: localTasteBeforePull,
            hadLocalWatchlist: localWatchlistBeforePull
        )
    }

    private func activeUserId() -> UUID? {
        AuthManager.shared.resolvedSupabaseUserId
    }

    private func activeUserIdString() -> String? {
        activeUserId()?.uuidString.lowercased()
    }

    /// Debounced upload after local taste or watchlist changes.
    func schedulePushFromLocalChange() {
        if isApplyingRemotePull {
            // A pull is in progress — queue a follow-up push for when it finishes
            // rather than silently dropping the request (which would lose swipes made
            // during the login sync window).
            hasPendingFollowUpPush = true
            return
        }
        if !SupabaseClientProvider.isConfigured { return }
        if !AuthManager.shared.isLoggedIn { return }
        if engine == nil {
            hasPendingRegistrationPush = true
            return
        }
        if isPushInProgress {
            hasPendingFollowUpPush = true
            return
        }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await performPush()
        }
    }

    /// Immediate upload (e.g. app entering background).
    func flushPendingPush() async {
        hasPendingFollowUpPush = false
        if isPushInProgress {
            // Push is actively running inside debounceTask — await it rather than
            // cancelling its in-flight network requests with CancellationError.
            await debounceTask?.value
            debounceTask = nil
        } else {
            debounceTask?.cancel()
            debounceTask = nil
        }
        if let engine {
            ProfileStorage.shared.save(engine.profile)
        }
        await performPush()
        AccountLocalState.persistAllStateToScoped()
    }

    func pushLocal(engine: RecommendationEngine, watchlist: WatchlistStore) async {
        guard SupabaseClientProvider.isConfigured, AuthManager.shared.isLoggedIn else { return }
        await pushTasteProfile(engine: engine)
        await pushWatchlist(watchlist: watchlist)
        await pushUserAppState()
    }

    // MARK: - Pull

    private func pullRemote(into engine: RecommendationEngine, watchlist: WatchlistStore) async -> PullResult {
        var result = PullResult()
        result.tasteSucceeded = await pullTasteProfile(into: engine)
        result.watchlistSucceeded = await pullWatchlist(into: watchlist)
        result.appStateSucceeded = await pullUserAppState()
        return result
    }

    @discardableResult
    private func pullTasteProfile(into engine: RecommendationEngine) async -> Bool {
        guard let client = SupabaseClientProvider.client,
              let userIdString = activeUserIdString() else { return false }
        do {
            let rows: [TasteProfileRemoteRow] = try await client
                .from("taste_profiles")
                .select()
                .eq("user_id", value: userIdString)
                .limit(1)
                .execute()
                .value
            if let row = rows.first,
               let data = row.data.data(using: .utf8),
               !row.data.isEmpty, row.data != "{}" {
                if let remote = try? JSONDecoder().decode(TasteProfile.self, from: data),
                   hasMeaningfulTaste(remote) {
                    let local = engine.profile
                    if shouldPreferRemoteTaste(remote, over: local) {
                        engine.profile = remote
                        ProfileStorage.shared.save(remote)
                    }
                } else {
                    #if DEBUG
                    print("[SupabaseSync] pull taste_profiles decode failed for user \(userIdString)")
                    #endif
                }
            }
            return true
        } catch {
            #if DEBUG
            print("[SupabaseSync] pull taste_profiles failed: \(error)")
            #endif
            return false
        }
    }

    @discardableResult
    private func pullWatchlist(into watchlist: WatchlistStore) async -> Bool {
        guard let client = SupabaseClientProvider.client,
              let userIdString = activeUserIdString() else { return false }
        do {
            let rows: [WatchlistRemoteRow] = try await client
                .from("watchlist")
                .select("tmdb_id")
                .eq("user_id", value: userIdString)
                .execute()
                .value
            guard !rows.isEmpty else { return true }
            let remoteIds = Set(rows.map(\.tmdb_id))
            let localIds = watchlist.allIds()
            if localIds.isEmpty || remoteIds.count >= localIds.count {
                watchlist.replaceAll(ids: remoteIds, suppressSyncPush: true)
                // Notify WatchlistView to reload. Its `.task` already ran (before sync)
                // with an empty store, so it needs an explicit kick after the pull fills it.
                NotificationCenter.default.post(name: .watchlistStoreDidReset, object: nil)
            }
            return true
        } catch {
            #if DEBUG
            print("[SupabaseSync] pull watchlist failed: \(error)")
            #endif
            return false
        }
    }

    @discardableResult
    private func pullUserAppState() async -> Bool {
        guard let client = SupabaseClientProvider.client,
              let userIdString = activeUserIdString() else { return false }
        do {
            let rows: [UserAppStateRemoteRow] = try await client
                .from("user_app_state")
                .select()
                .eq("user_id", value: userIdString)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first,
                  let data = row.data.data(using: .utf8),
                  !row.data.isEmpty, row.data != "{}",
                  let remote = try? JSONDecoder().decode(UserAppStatePayload.self, from: data)
            else { return true }

            UserAppStateSync.applyMergedRemote(remote)
            return true
        } catch {
            #if DEBUG
            print("[SupabaseSync] pull user_app_state failed: \(error)")
            #endif
            return false
        }
    }

    private func shouldPreferRemoteTaste(_ remote: TasteProfile, over local: TasteProfile) -> Bool {
        if !hasMeaningfulTaste(local) { return true }
        if !hasMeaningfulTaste(remote) { return false }
        return remote.totalSwipes >= local.totalSwipes
            || remote.swipeHistory.count >= local.swipeHistory.count
    }

    private func hasMeaningfulTaste(_ profile: TasteProfile) -> Bool {
        profile.totalSwipes > 0 || !profile.swipeHistory.isEmpty || !profile.likedIds.isEmpty
    }

    private func applyEngineFromSyncedGenrePrefs(engine: RecommendationEngine) {
        let prefs = GenrePreferencesStore.shared.genrePreferences
        let hasGenreChoices = prefs.values.contains { $0 != .neutral }
        guard AccountLocalState.globalBool(UserDefaultsKeys.genreOnboardingComplete) || hasGenreChoices else { return }
        let buckets = GenreCatalog.engineOnboardingGenreIds(from: prefs)
        engine.replaceOnboardingGenres(
            loved: buckets.loved,
            liked: buckets.liked,
            disliked: buckets.disliked
        )
        ProfileStorage.shared.save(engine.profile)
    }

    // MARK: - Push

    private func pushAfterLoginPull(
        engine: RecommendationEngine,
        watchlist: WatchlistStore,
        pull: PullResult,
        hadLocalTaste: Bool,
        hadLocalWatchlist: Bool
    ) async {
        let canPushTaste = pull.tasteSucceeded || hadLocalTaste || hasMeaningfulTaste(engine.profile)
        if canPushTaste {
            await pushTasteProfile(engine: engine)
        }

        let watchlistIds = watchlist.allIds()
        // Only push when local has items — never treat a successful empty pull as permission to wipe remote rows.
        let canPushWatchlist = !watchlistIds.isEmpty || hadLocalWatchlist
        if canPushWatchlist {
            await pushWatchlist(watchlist: watchlist)
        }

        let localAppState = UserAppStateSync.exportPayload()
        let canPushAppState = pull.appStateSucceeded
            || UserAppStateSync.hasMeaningfulContent(localAppState)
        if canPushAppState {
            await pushUserAppState()
        }
    }

    private func performPush() async {
        guard AuthManager.shared.isLoggedIn else { return }
        guard let engine else { return }
        isPushInProgress = true
        defer {
            isPushInProgress = false
            if hasPendingFollowUpPush {
                hasPendingFollowUpPush = false
                schedulePushFromLocalChange()
            }
        }
        await pushLocal(engine: engine, watchlist: WatchlistStore.shared)
    }

    private func pushTasteProfile(engine: RecommendationEngine) async {
        guard hasMeaningfulTaste(engine.profile) else { return }
        guard let client = SupabaseClientProvider.client,
              let userId = activeUserId() else { return }
        do {
            let json = try JSONEncoder().encode(engine.profile)
            guard let text = String(data: json, encoding: .utf8) else { return }
            let row = TasteProfileUpsertRow(user_id: userId, data: text)
            try await client.from("taste_profiles").upsert(row).execute()
        } catch {
            #if DEBUG
            print("[SupabaseSync] push taste_profiles failed: \(error)")
            #endif
        }
    }

    private func pushWatchlist(watchlist: WatchlistStore) async {
        guard let client = SupabaseClientProvider.client,
              let userId = activeUserId(),
              let userIdString = activeUserIdString() else { return }
        let ids = watchlist.allIds()
        do {
            // 1. Fetch current remote state
            let remoteRows: [WatchlistRemoteRow] = (try? await client
                .from("watchlist")
                .select("tmdb_id")
                .eq("user_id", value: userIdString)
                .execute()
                .value) ?? []
            let remoteIds = Set(remoteRows.map(\.tmdb_id))

            // Never delete remote rows when local is empty (failed restore / new device before pull).
            guard !ids.isEmpty || remoteIds.isEmpty else { return }

            // 2. Diff
            let toAdd    = ids.subtracting(remoteIds)
            let toRemove = remoteIds.subtracting(ids)

            // 3. Insert new items first (safe: crash here leaves extra rows, not zero)
            if !toAdd.isEmpty {
                let rows = toAdd.map { WatchlistInsertRow(user_id: userId, tmdb_id: $0) }
                try await client.from("watchlist").insert(rows).execute()
            }

            // 4. Delete removed items
            if !toRemove.isEmpty {
                try await client
                    .from("watchlist")
                    .delete()
                    .eq("user_id", value: userIdString)
                    .in("tmdb_id", values: toRemove.map { String($0) })
                    .execute()
            }
        } catch {
            #if DEBUG
            print("[SupabaseSync] push watchlist failed: \(error)")
            #endif
        }
    }

    private func pushUserAppState() async {
        let payload = UserAppStateSync.exportPayload()
        guard UserAppStateSync.hasMeaningfulContent(payload) else { return }
        guard let client = SupabaseClientProvider.client,
              let userId = activeUserId() else { return }
        do {
            let json = try JSONEncoder().encode(payload)
            guard let text = String(data: json, encoding: .utf8) else { return }
            let row = UserAppStateUpsertRow(user_id: userId, data: text)
            try await client.from("user_app_state").upsert(row).execute()
        } catch {
            #if DEBUG
            print("[SupabaseSync] push user_app_state failed: \(error)")
            #endif
        }
    }
}

// MARK: - Row types

private struct TasteProfileRemoteRow: Decodable {
    let user_id: UUID
    let data: String
}

private struct TasteProfileUpsertRow: Encodable {
    let user_id: UUID
    let data: String
}

private struct WatchlistRemoteRow: Decodable {
    let tmdb_id: Int
}

private struct WatchlistInsertRow: Encodable {
    let user_id: UUID
    let tmdb_id: Int
}

private struct UserAppStateRemoteRow: Decodable {
    let user_id: UUID
    let data: String
}

private struct UserAppStateUpsertRow: Encodable {
    let user_id: UUID
    let data: String
}

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

    /// Coalesce rapid swipes / watchlist edits before uploading.
    private let debounceInterval: Duration = .seconds(2.5)

    private init() {}

    func register(engine: RecommendationEngine) {
        self.engine = engine
    }

    func cancelPendingPush() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Call after a successful login or session restore.
    func syncAfterLogin(engine: RecommendationEngine, watchlist: WatchlistStore) async {
        register(engine: engine)
        cancelPendingPush()
        isApplyingRemotePull = true
        defer { isApplyingRemotePull = false }
        guard SupabaseClientProvider.isConfigured, AuthManager.shared.isLoggedIn else { return }
        await pullRemote(into: engine, watchlist: watchlist)
        await pushLocal(engine: engine, watchlist: watchlist)
    }

    /// Debounced upload after local taste or watchlist changes.
    func schedulePushFromLocalChange() {
        guard !isApplyingRemotePull,
              SupabaseClientProvider.isConfigured,
              AuthManager.shared.isLoggedIn,
              engine != nil else { return }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await performPush()
        }
    }

    /// Immediate upload (e.g. app entering background).
    func flushPendingPush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await performPush()
    }

    func pushLocal(engine: RecommendationEngine, watchlist: WatchlistStore) async {
        guard SupabaseClientProvider.isConfigured, AuthManager.shared.isLoggedIn else { return }
        await pushTasteProfile(engine: engine)
        await pushWatchlist(watchlist: watchlist)
    }

    // MARK: - Pull

    private func pullRemote(into engine: RecommendationEngine, watchlist: WatchlistStore) async {
        await pullTasteProfile(into: engine)
        await pullWatchlist(into: watchlist)
    }

    private func pullTasteProfile(into engine: RecommendationEngine) async {
        guard let client = SupabaseClientProvider.client,
              let userId = AuthManager.shared.supabaseUserId else { return }
        do {
            let rows: [TasteProfileRemoteRow] = try await client
                .from("taste_profiles")
                .select()
                .eq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            if let row = rows.first,
               let data = row.data.data(using: .utf8),
               let remote = try? JSONDecoder().decode(TasteProfile.self, from: data),
               !row.data.isEmpty, row.data != "{}" {
                engine.profile = remote
                ProfileStorage.shared.save(remote)
            }
            // No remote row / empty payload: keep local profile; push will upload it.
        } catch {
            #if DEBUG
            print("[SupabaseSync] pull taste_profiles failed: \(error)")
            #endif
        }
    }

    private func pullWatchlist(into watchlist: WatchlistStore) async {
        guard let client = SupabaseClientProvider.client,
              let userId = AuthManager.shared.supabaseUserId else { return }
        do {
            let rows: [WatchlistRemoteRow] = try await client
                .from("watchlist")
                .select("tmdb_id")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            // Empty remote: keep local bookmarks so first sync does not wipe the device list.
            guard !rows.isEmpty else { return }
            watchlist.replaceAll(ids: Set(rows.map(\.tmdb_id)), suppressSyncPush: true)
        } catch {
            #if DEBUG
            print("[SupabaseSync] pull watchlist failed: \(error)")
            #endif
        }
    }

    // MARK: - Push

    private func performPush() async {
        guard let engine else { return }
        await pushLocal(engine: engine, watchlist: WatchlistStore.shared)
    }

    private func pushTasteProfile(engine: RecommendationEngine) async {
        guard let client = SupabaseClientProvider.client,
              let userId = AuthManager.shared.supabaseUserId else { return }
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
              let userId = AuthManager.shared.supabaseUserId else { return }
        do {
            try await client
                .from("watchlist")
                .delete()
                .eq("user_id", value: userId.uuidString)
                .execute()

            let ids = watchlist.allIds()
            guard !ids.isEmpty else { return }

            let rows = ids.map { WatchlistInsertRow(user_id: userId, tmdb_id: $0) }
            try await client.from("watchlist").insert(rows).execute()
        } catch {
            #if DEBUG
            print("[SupabaseSync] push watchlist failed: \(error)")
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

// MovieDetailFeedbackStore.swift
// UI state + one-time engine recording flags for detail-screen Like / Dislike / Watchlist.

import Foundation

enum MovieDetailFeedback: String, Codable, Equatable {
    case none
    case liked
    case disliked
}

/// Persists thumbs state per movie (for toggles and highlighting).
final class MovieDetailFeedbackStore {
    static let shared = MovieDetailFeedbackStore()
    private let key = "movie_detail_feedback_v1"
    private var map: [Int: MovieDetailFeedback] = [:]

    private init() { load() }

    func feedback(for movieId: Int) -> MovieDetailFeedback {
        map[movieId] ?? .none
    }

    func set(_ movieId: Int, _ value: MovieDetailFeedback) {
        map[movieId] = value
        persist()
    }

    /// Movies the user marked thumbs-down in detail (always exclude from Watch Now even if engine state lagged).
    var dislikedMovieIds: Set<Int> {
        Set(map.filter { $0.value == .disliked }.map(\.key))
    }

    /// All movies explicitly liked via the detail screen thumbs button.
    func allLikedIds() -> [Int] {
        map.filter { $0.value == .liked }.map(\.key)
    }

    /// All movies explicitly disliked via the detail screen thumbs button.
    func allDislikedIds() -> [Int] {
        map.filter { $0.value == .disliked }.map(\.key)
    }

    func clearAll() {
        map = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode([Int: MovieDetailFeedback].self, from: data)
        else { return }
        map = d
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Ensures we don’t call `RecommendationEngine.record` twice for the same signal on the same movie.
private struct MovieEngineRecordFlags: Codable, Equatable {
    var sentLike = false
    var sentDislike = false
    var sentWatchlist = false
}

final class MovieDetailEngineRecordStore {
    static let shared = MovieDetailEngineRecordStore()
    private let key = "movie_detail_engine_records_v1"
    private var map: [Int: MovieEngineRecordFlags] = [:]

    private init() { load() }

    /// Returns `true` if the engine should receive a like for this movie (first time only).
    func consumeLikeRecord(for movieId: Int) -> Bool {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        guard !r.sentLike else { return false }
        r.sentLike = true
        map[movieId] = r
        persist()
        return true
    }

    /// Returns `true` if the engine should receive a skip (dislike) for this movie.
    func consumeDislikeRecord(for movieId: Int) -> Bool {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        guard !r.sentDislike else { return false }
        r.sentDislike = true
        map[movieId] = r
        persist()
        return true
    }

    /// Keeps `sentLike` / `sentDislike` aligned after the engine records a flip or first signal.
    func markLikeApplied(to movieId: Int) {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        r.sentLike = true
        r.sentDislike = false
        map[movieId] = r
        persist()
    }

    func markDislikeApplied(to movieId: Int) {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        r.sentDislike = true
        r.sentLike = false
        map[movieId] = r
        persist()
    }

    /// Returns `true` if the engine should receive a watchlist event (first add only).
    func consumeWatchlistRecord(for movieId: Int) -> Bool {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        guard !r.sentWatchlist else { return false }
        r.sentWatchlist = true
        map[movieId] = r
        persist()
        return true
    }

    /// After the user removes a title from the watchlist, allow the next add to call `record(.watchlist)` again.
    func revokeWatchlistTracking(for movieId: Int) {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        r.sentWatchlist = false
        map[movieId] = r
        persist()
    }

    /// Clearing Like / Dislike on the detail sheet resets one-time engine-send flags (`consumeLikeRecord` / `consumeDislikeRecord`) while keeping watchlist state.
    func revokeLikeDislikeEngineTracking(for movieId: Int) {
        var r = map[movieId] ?? MovieEngineRecordFlags()
        r.sentLike = false
        r.sentDislike = false
        map[movieId] = r
        persist()
    }

    func clearAll() {
        map = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode([Int: MovieEngineRecordFlags].self, from: data)
        else { return }
        map = d
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

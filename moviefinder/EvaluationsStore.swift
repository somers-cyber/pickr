// EvaluationsStore.swift
// Permanent, unlimited record of every like and dislike — the source of truth for Archives.
// Written on every Discover swipe and every detail-screen thumbs action.

import Foundation
import Combine

// MARK: - Model

/// Minimal movie metadata cached at swipe time so Archives never needs API calls.
struct CachedMovieMeta: Codable, Equatable {
    let title: String
    let releaseDate: String?
    let posterPath: String?
    /// Lets `TMDBMovie.posterURL` fall back to a backdrop when TMDB omits poster (common on very new releases).
    let backdropPath: String?
    let genreIds: [Int]
    let voteAverage: Double

    private static func nonemptyPath(_ path: String?) -> String? {
        guard let t = path?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return path
    }

    /// True when we can build a TMDB image URL without another fetch.
    var hasRenderableImagePath: Bool {
        Self.nonemptyPath(posterPath) != nil || Self.nonemptyPath(backdropPath) != nil
    }

    /// Prefer non-empty incoming fields without wiping richer data already on disk (e.g. poster → nil overwrite).
    static func merging(existing: CachedMovieMeta?, movie: TMDBMovie) -> CachedMovieMeta {
        guard let old = existing else {
            return CachedMovieMeta(
                title: movie.title,
                releaseDate: movie.releaseDate,
                posterPath: movie.posterPath,
                backdropPath: movie.backdropPath,
                genreIds: movie.genreIds,
                voteAverage: movie.voteAverage
            )
        }
        let poster = firstNonBlankPath(movie.posterPath, old.posterPath)
        let backdrop = firstNonBlankPath(movie.backdropPath, old.backdropPath)
        let genres = movie.genreIds.isEmpty ? old.genreIds : movie.genreIds
        return CachedMovieMeta(
            title: movie.title.isEmpty ? old.title : movie.title,
            releaseDate: movie.releaseDate ?? old.releaseDate,
            posterPath: poster,
            backdropPath: backdrop,
            genreIds: genres,
            voteAverage: movie.voteAverage
        )
    }

    /// First argument wins if trimmed non-empty; otherwise second (trimmed non-empty).
    private static func firstNonBlankPath(_ primary: String?, _ fallback: String?) -> String? {
        let a = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !a.isEmpty { return primary }
        let b = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !b.isEmpty { return fallback }
        return nil
    }
}

struct Evaluation: Codable, Equatable {
    let tmdbId: Int
    let verdict: Verdict
    let timestamp: Date
    var meta: CachedMovieMeta?

    enum Verdict: String, Codable {
        case liked
        case disliked
    }

    /// Build a lightweight TMDBMovie from cached metadata. Returns nil if no meta stored yet.
    func toTMDBMovie() -> TMDBMovie? {
        guard let m = meta else { return nil }
        return TMDBMovie(
            id: tmdbId, title: m.title, overview: "",
            releaseDate: m.releaseDate, posterPath: m.posterPath,
            backdropPath: m.backdropPath, voteAverage: m.voteAverage,
            voteCount: 0, genreIds: m.genreIds, popularity: 0
        )
    }
}

extension Evaluation {
    /// `false` when `WatchlistCard` would show only a hue placeholder without a TMDB row fetch.
    var hasRenderableArchiveImage: Bool {
        meta?.hasRenderableImagePath ?? false
    }

    /// Archives should fetch details when the grid cannot build a TMDB image URL (stricter than raw path strings).
    var needsArchiveImageFetch: Bool {
        toTMDBMovie()?.posterURL == nil
    }
}

// MARK: - Store

final class EvaluationsStore: ObservableObject {
    static let shared = EvaluationsStore()

    private let key          = "evaluations_store_v2"
    private let migratedKey  = "evaluations_migrated_v2"

    /// All evaluations, oldest first. @Published so SwiftUI views react automatically.
    @Published private(set) var all: [Evaluation] = []
    /// Bumps whenever verdicts mutate (count can stay flat when swapping liked↔disliked).
    @Published private(set) var mutationGeneration: UInt64 = 0

    private init() { load() }

    private func bumpGeneration() {
        mutationGeneration &+= 1
    }

    // MARK: - Write

    /// Record or update a verdict. Pass a TMDBMovie to cache poster/genre metadata
    /// so Archives can display cards without any API calls.
    func record(tmdbId: Int, verdict: Evaluation.Verdict, movie: TMDBMovie? = nil) {
        if let idx = all.firstIndex(where: { $0.tmdbId == tmdbId }) {
            let meta: CachedMovieMeta?
            if let mv = movie {
                meta = CachedMovieMeta.merging(existing: all[idx].meta, movie: mv)
            } else {
                meta = all[idx].meta
            }
            all[idx] = Evaluation(tmdbId: tmdbId, verdict: verdict, timestamp: Date(), meta: meta)
        } else {
            let meta = movie.map { CachedMovieMeta.merging(existing: nil, movie: $0) }
            all.append(Evaluation(tmdbId: tmdbId, verdict: verdict, timestamp: Date(), meta: meta))
        }
        bumpGeneration()
        persist()
    }

    /// Merge TMDB lookup into stored meta (fills nil poster/backdrop from older entries or incomplete records).
    func enrichMetaFromRemote(tmdbId: Int, movie: TMDBMovie) {
        guard let idx = all.firstIndex(where: { $0.tmdbId == tmdbId }) else { return }
        let e = all[idx]
        let next = CachedMovieMeta.merging(existing: e.meta, movie: movie)
        guard next != e.meta else { return }
        all[idx] = Evaluation(tmdbId: e.tmdbId, verdict: e.verdict, timestamp: e.timestamp, meta: next)
        bumpGeneration()
        persist()
    }

    /// Remove the verdict for a movie (e.g. user un-taps a thumbs button).
    func remove(tmdbId: Int) {
        all.removeAll { $0.tmdbId == tmdbId }
        bumpGeneration()
        persist()
    }

    /// Replace store with pre-swipe state (Discover “undo”).
    func restoreSwipeUndoSnapshot(_ evaluations: [Evaluation]) {
        all = evaluations
        bumpGeneration()
        persist()
    }

    /// Frozen copy for Discover swipe undo checkpoints.
    func swipeUndoSnapshot() -> [Evaluation] {
        Array(all)
    }

    // MARK: - Read

    func verdict(for tmdbId: Int) -> Evaluation.Verdict? {
        all.last(where: { $0.tmdbId == tmdbId })?.verdict
    }

    /// Liked IDs, most recent first.
    var likedIds: [Int] {
        all.filter { $0.verdict == .liked }.map(\.tmdbId).reversed()
    }

    /// Disliked IDs, most recent first.
    var dislikedIds: [Int] {
        all.filter { $0.verdict == .disliked }.map(\.tmdbId).reversed()
    }

    var likedCount: Int   { all.filter { $0.verdict == .liked    }.count }
    var dislikedCount: Int { all.filter { $0.verdict == .disliked }.count }

    // MARK: - Migration

    /// One-time import of data from older stores so existing users keep their history.
    func migrateIfNeeded(likedIds: [Int], swipeHistory: [SwipeHistoryEntry], detailFeedback: [Int: MovieDetailFeedback]) {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)

        // Use a dictionary keyed by tmdbId so newer signals win
        var merged: [Int: Evaluation] = [:]

        // 1. swipe history (oldest signal; mult > 0 = liked, mult < 0 = disliked)
        for entry in swipeHistory {
            let verdict: Evaluation.Verdict = entry.mult >= 0 ? .liked : .disliked
            merged[entry.movieId] = Evaluation(tmdbId: entry.movieId, verdict: verdict, timestamp: entry.timestamp)
        }

        // 2. likedIds from engine (more recent)
        for id in likedIds {
            merged[id] = Evaluation(tmdbId: id, verdict: .liked, timestamp: merged[id]?.timestamp ?? Date.distantPast)
        }

        // 3. detail-screen feedback (most authoritative)
        for (id, feedback) in detailFeedback {
            switch feedback {
            case .liked:    merged[id] = Evaluation(tmdbId: id, verdict: .liked,    timestamp: merged[id]?.timestamp ?? Date.distantPast)
            case .disliked: merged[id] = Evaluation(tmdbId: id, verdict: .disliked, timestamp: merged[id]?.timestamp ?? Date.distantPast)
            case .none: break
            }
        }

        // Merge into existing store without overwriting newer entries
        let existingIds = Set(all.map(\.tmdbId))
        let toAdd = merged.values.filter { !existingIds.contains($0.tmdbId) }
        all.append(contentsOf: toAdd.sorted { ($0.timestamp) < ($1.timestamp) })
        bumpGeneration()
        persist()
    }

    // MARK: - Reset

    func clearAll() {
        all = []
        bumpGeneration()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: migratedKey)
    }

    func reloadFromStorage() {
        load()
        bumpGeneration()
    }

    /// Fills Archives gaps from synced taste profile swipe history (Archives is local-only).
    func syncFromTasteProfile(_ profile: TasteProfile) {
        var merged: [Int: Evaluation] = Dictionary(uniqueKeysWithValues: all.map { ($0.tmdbId, $0) })

        for entry in profile.swipeHistory {
            let verdict: Evaluation.Verdict = entry.mult >= 0 ? .liked : .disliked
            if merged[entry.movieId] == nil {
                merged[entry.movieId] = Evaluation(
                    tmdbId: entry.movieId,
                    verdict: verdict,
                    timestamp: entry.timestamp
                )
            }
        }

        for id in profile.likedIds where merged[id] == nil {
            merged[id] = Evaluation(tmdbId: id, verdict: .liked, timestamp: Date.distantPast)
        }

        all = merged.values.sorted { $0.timestamp < $1.timestamp }
        bumpGeneration()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Evaluation].self, from: data)
        else { return }
        all = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// GenrePreferences.swift
// Cold-start genre preferences (onboarding) + helpers for ranking and discover.

import Combine
import Foundation

// MARK: - Preference Level

/// User preference for a genre. `neutral` = "open to" in the UI.
enum PreferenceLevel: String, Codable, CaseIterable, Equatable {
    case like
    case neutral
    case dislike

    /// Tap cycle: neutral → like → dislike → neutral
    mutating func advance() {
        switch self {
        case .neutral: self = .like
        case .like: self = .dislike
        case .dislike: self = .neutral
        }
    }
}

// MARK: - Catalog (display name → TMDB genre id)

struct OnboardingGenre: Identifiable, Hashable {
    let id: String
    let displayName: String
    let tmdbGenreId: Int
}

enum GenreCatalog {
    /// Nine genres for onboarding (limit 8–10).
    static let onboarding: [OnboardingGenre] = [
        OnboardingGenre(id: "action", displayName: "Action", tmdbGenreId: 28),
        OnboardingGenre(id: "comedy", displayName: "Comedy", tmdbGenreId: 35),
        OnboardingGenre(id: "drama", displayName: "Drama", tmdbGenreId: 18),
        OnboardingGenre(id: "thriller", displayName: "Thriller", tmdbGenreId: 53),
        OnboardingGenre(id: "horror", displayName: "Horror", tmdbGenreId: 27),
        OnboardingGenre(id: "romance", displayName: "Romance", tmdbGenreId: 10_749),
        OnboardingGenre(id: "scifi", displayName: "Sci-Fi", tmdbGenreId: 878),
        OnboardingGenre(id: "documentary", displayName: "Documentary", tmdbGenreId: 99),
        OnboardingGenre(id: "family", displayName: "Family", tmdbGenreId: 10_751),
    ]

    static func defaultPreferences() -> [String: PreferenceLevel] {
        var d: [String: PreferenceLevel] = [:]
        for g in onboarding {
            d[g.displayName] = .neutral
        }
        return d
    }

    static func level(for displayName: String, in prefs: [String: PreferenceLevel]) -> PreferenceLevel {
        prefs[displayName] ?? .neutral
    }

    static func tmdbIds(matching prefs: [String: PreferenceLevel], level: PreferenceLevel) -> [Int] {
        onboarding.compactMap { g in
            Self.level(for: g.displayName, in: prefs) == level ? g.tmdbGenreId : nil
        }
    }

    static func dislikedIdSet(from prefs: [String: PreferenceLevel]) -> Set<Int> {
        Set(tmdbIds(matching: prefs, level: .dislike))
    }

    /// IDs excluded from Discover ranking / Watch Now when onboarding dislikes apply.
    /// If **Family** (`10751`) is disliked, also excludes **Animation** (`16`): many kids’ titles
    /// carry Animation without Family (e.g. some animated features), while TMDB’s Family tag is missing on others.
    static func expandedDislikedGenreIdsForFiltering(_ disliked: [Int]) -> Set<Int> {
        var s = Set(disliked)
        if s.contains(10751) { s.insert(16) }
        return s
    }

    /// Watch Now genre chips — exclude onboarding “dislike” genres entirely.
    static func watchNowGenreChips(preferences prefs: [String: PreferenceLevel]) -> [OnboardingGenre] {
        onboarding.filter { level(for: $0.displayName, in: prefs) != .dislike }
    }

    /// Maps chip states → TMDB genre ID buckets for `RecommendationEngine.applyOnboardingGenres(loved:liked:disliked:)`.
    /// UI “Like” → `.like` → **loved**; “Open to” → `.neutral` → **liked**; “Don’t Like” → `.dislike` → **disliked**.
    static func engineOnboardingGenreIds(from prefs: [String: PreferenceLevel]) -> (loved: [Int], liked: [Int], disliked: [Int]) {
        (
            loved: tmdbIds(matching: prefs, level: .like),
            liked: tmdbIds(matching: prefs, level: .neutral),
            disliked: tmdbIds(matching: prefs, level: .dislike)
        )
    }

    /// Display name for any TMDB genre id (onboarding list + common extras).
    static func displayName(forTmdbGenreId id: Int) -> String? {
        if let g = onboarding.first(where: { $0.tmdbGenreId == id }) {
            return g.displayName
        }
        let extra: [Int: String] = [
            12: "Adventure", 16: "Animation", 80: "Crime", 14: "Fantasy", 36: "History",
            10402: "Music", 9648: "Mystery", 10752: "War", 37: "Western",
        ]
        return extra[id]
    }
}

// MARK: - Pure ranking (tests + Watch Now)

enum GenrePreferenceRanking {
    /// Higher = better match to stated preferences.
    static func weightScore(for movie: TMDBMovie, prefs: [String: PreferenceLevel]) -> Double {
        var score = 0.0
        let ids = Set(movie.genreIds)
        for g in GenreCatalog.onboarding {
            guard ids.contains(g.tmdbGenreId) else { continue }
            switch GenreCatalog.level(for: g.displayName, in: prefs) {
            case .like: score += 3.0
            case .neutral: score += 0.8
            case .dislike: score -= 4.0
            }
        }
        return score
    }

    /// `true` = movie touches a disliked genre (uses `GenreCatalog.expandedDislikedGenreIdsForFiltering`).
    static func hasDislikedGenre(_ movie: TMDBMovie, disliked: Set<Int>) -> Bool {
        hasDislikedGenre(movie, disliked: Array(disliked))
    }

    /// `true` = movie touches expanded disliked genres (Family dislike → also Animation).
    static func hasDislikedGenre(_ movie: TMDBMovie, disliked: [Int]) -> Bool {
        let expanded = GenreCatalog.expandedDislikedGenreIdsForFiltering(disliked)
        guard !expanded.isEmpty else { return false }
        return !Set(movie.genreIds).isDisjoint(with: expanded)
    }

    static func sortedByPreference(_ movies: [TMDBMovie], prefs: [String: PreferenceLevel]) -> [TMDBMovie] {
        movies.sorted { weightScore(for: $0, prefs: prefs) > weightScore(for: $1, prefs: prefs) }
    }
}

// MARK: - Persistence

final class GenrePreferencesStore: ObservableObject {
    static let shared = GenrePreferencesStore()

    private let key = "genre_preferences_v1"

    @Published private(set) var genrePreferences: [String: PreferenceLevel]

    init(userDefaults: UserDefaults = .standard) {
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: PreferenceLevel].self, from: data) {
            var merged = GenreCatalog.defaultPreferences()
            for (k, v) in decoded { merged[k] = v }
            genrePreferences = merged
        } else {
            genrePreferences = GenreCatalog.defaultPreferences()
        }
    }

    func set(_ displayName: String, level: PreferenceLevel) {
        var next = genrePreferences
        next[displayName] = level
        genrePreferences = next
        persist()
    }

    func cycle(_ displayName: String) {
        var level = genrePreferences[displayName] ?? .neutral
        level.advance()
        var next = genrePreferences
        next[displayName] = level
        genrePreferences = next
        persist()
    }

    func resetToDefaults() {
        genrePreferences = GenreCatalog.defaultPreferences()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(genrePreferences) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // Chip like / neutral / dislike flows through `RecommendationEngine.replaceOnboardingGenres` → `genreWeights` → `score()` only.

    /// Discover `with_genres` for swipe cold start: liked first, then neutral.
    func discoverGenreSeeds(count: Int) -> [Int] {
        let liked = GenreCatalog.tmdbIds(matching: genrePreferences, level: .like)
        if liked.count >= count { return Array(liked.prefix(count)) }
        var out = liked
        let neutral = GenreCatalog.tmdbIds(matching: genrePreferences, level: .neutral)
        for id in neutral where out.count < count {
            if !out.contains(id) { out.append(id) }
        }
        return Array(out.prefix(count))
    }
}

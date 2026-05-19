// RecommendationEngine.swift
// On-device taste profile + scoring. No ML framework, no server, fully private.

import Foundation
import Combine

// MARK: - Swipe history (for decay replay)

struct SwipeHistoryEntry: Codable, Equatable {
    var movieId: Int
    var genreIds: [Int]
    var mult: Double
    var timestamp: Date
}

// MARK: - Taste Profile

struct TasteProfile: Codable {
    var genreWeights:    [Int: Double]    = [:]
    /// Learned in `enrichWithCredits`; **not** read by `score()` or `rank()` — TMDB list rows have no cast ids here.
    var actorWeights:    [Int: Double]    = [:]
    /// Same as `actorWeights`: profile signal only; global ranking uses genres + decade + rating.
    var directorWeights: [Int: Double]    = [:]
    var decadeWeights:   [String: Double] = [:]
    var languageWeights: [String: Double] = [:]
    var seenIds:         Set<Int>         = []
    var likedIds:        [Int]            = []   // most recent first
    var ratings:         [Int: Int]       = [:]  // movieId → 1-5 stars
    var totalSwipes:     Int              = 0

    var onboardingLoved:    [Int] = []
    var onboardingLiked:    [Int] = []   // "open to" at onboarding
    var onboardingDisliked: [Int] = []
    var onboardingComplete: Bool = false

    /// Capped at last 150 entries; used for decay replay.
    var swipeHistory: [SwipeHistoryEntry] = []

    /// genreId → count of strong skips (detail / long-press rejections).
    var strongSkipCounts: [Int: Int] = [:]

    /// genreId → count of signal direction flips (like↔skip/strongSkip). Dampens learning when contradictory.
    var genreVolatility: [Int: Int] = [:]

    /// genreId → last swipe multiplier direction for that genre’s movie (positive = up, negative = down).
    var lastGenreMultDirection: [Int: Double] = [:]

    var isEmpty: Bool { totalSwipes < 5 }

    enum CodingKeys: String, CodingKey {
        case genreWeights, actorWeights, directorWeights, decadeWeights, languageWeights
        case seenIds, likedIds, ratings, totalSwipes
        case onboardingLoved, onboardingLiked, onboardingDisliked, onboardingComplete
        case swipeHistory, strongSkipCounts, genreVolatility, lastGenreMultDirection
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genreWeights = try c.decodeIfPresent([Int: Double].self, forKey: .genreWeights) ?? [:]
        actorWeights = try c.decodeIfPresent([Int: Double].self, forKey: .actorWeights) ?? [:]
        directorWeights = try c.decodeIfPresent([Int: Double].self, forKey: .directorWeights) ?? [:]
        decadeWeights = try c.decodeIfPresent([String: Double].self, forKey: .decadeWeights) ?? [:]
        languageWeights = try c.decodeIfPresent([String: Double].self, forKey: .languageWeights) ?? [:]
        seenIds = try c.decodeIfPresent(Set<Int>.self, forKey: .seenIds) ?? []
        likedIds = try c.decodeIfPresent([Int].self, forKey: .likedIds) ?? []
        ratings = try c.decodeIfPresent([Int: Int].self, forKey: .ratings) ?? [:]
        totalSwipes = try c.decodeIfPresent(Int.self, forKey: .totalSwipes) ?? 0
        onboardingLoved = try c.decodeIfPresent([Int].self, forKey: .onboardingLoved) ?? []
        onboardingLiked = try c.decodeIfPresent([Int].self, forKey: .onboardingLiked) ?? []
        onboardingDisliked = try c.decodeIfPresent([Int].self, forKey: .onboardingDisliked) ?? []
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        swipeHistory = try c.decodeIfPresent([SwipeHistoryEntry].self, forKey: .swipeHistory) ?? []
        strongSkipCounts = try c.decodeIfPresent([Int: Int].self, forKey: .strongSkipCounts) ?? [:]
        genreVolatility = try c.decodeIfPresent([Int: Int].self, forKey: .genreVolatility) ?? [:]
        lastGenreMultDirection = try c.decodeIfPresent([Int: Double].self, forKey: .lastGenreMultDirection) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(genreWeights, forKey: .genreWeights)
        try c.encode(actorWeights, forKey: .actorWeights)
        try c.encode(directorWeights, forKey: .directorWeights)
        try c.encode(decadeWeights, forKey: .decadeWeights)
        try c.encode(languageWeights, forKey: .languageWeights)
        try c.encode(seenIds, forKey: .seenIds)
        try c.encode(likedIds, forKey: .likedIds)
        try c.encode(ratings, forKey: .ratings)
        try c.encode(totalSwipes, forKey: .totalSwipes)
        try c.encode(onboardingLoved, forKey: .onboardingLoved)
        try c.encode(onboardingLiked, forKey: .onboardingLiked)
        try c.encode(onboardingDisliked, forKey: .onboardingDisliked)
        try c.encode(onboardingComplete, forKey: .onboardingComplete)
        try c.encode(swipeHistory, forKey: .swipeHistory)
        try c.encode(strongSkipCounts, forKey: .strongSkipCounts)
        try c.encode(genreVolatility, forKey: .genreVolatility)
        try c.encode(lastGenreMultDirection, forKey: .lastGenreMultDirection)
    }
}

// MARK: - Types

struct SwipeEvent {
    enum Action { case like, skip, strongSkip, watchlist, rated(Int) }
    let movieId:   Int
    let action:    Action
    let movie:     TMDBMovieDetail
    let timestamp: Date
}

struct TMDBPerson: Decodable, Identifiable {
    let id:          Int
    let name:        String
    let job:         String?
    let character:   String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job, character
        case profilePath = "profile_path"
    }
}

// MARK: - Profile Storage

class ProfileStorage {
    static let shared = ProfileStorage()
    private let key = "taste_profile_v2"

    func save(_ profile: TasteProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load() -> TasteProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(TasteProfile.self, from: data)
        else { return TasteProfile() }
        return p
    }
}

// MARK: - Recommendation Engine

class RecommendationEngine: ObservableObject {
    @Published var profile: TasteProfile
    private let storage: ProfileStorage

    private struct Weights {
        static let genre     = 0.35
        static let actor     = 0.20
        static let director  = 0.20
        static let decade    = 0.15   // raised from 0.10: era preference now audible
        static let language  = 0.05
        static let rating    = 0.10
        // popularity removed: redundant with voteAverage; biases against niche films
    }

    /// Extra scoring / dampening — kept separate from `Weights` so core TMDB weights stay stable.
    private enum ScoreTuning {
        /// Any movie genre with a negative learned weight multiplies the whole score (ranking, not only filter).
        static let negativeGenreMultiplier = 0.42
        /// Mature profiles: weak summed genre signal lets rating dominate too much — soft down-rank.
        static let weakGenreOverlapMinSwipes = 15
        static let weakGenreSigmoidCap     = 0.535
        static let weakGenreScoreMultiplier = 0.52
        /// Drama/Romance up vs Action/Sci‑Fi/Adventure down → dampen rating using TMDB popularity for niche leaners.
        static let nicheMinSwipes          = 8
        static let nicheDramaRomanceIds: [Int] = [18, 10749]
        static let nicheSpectacleIds: [Int]    = [28, 878, 12]
    }

    init(storage: ProfileStorage = .shared) {
        self.storage = storage
        self.profile = storage.load()
    }

    private func persistProfile() {
        storage.save(profile)
        scheduleCloudSyncIfNeeded()
    }

    private func scheduleCloudSyncIfNeeded() {
        guard !ProcessInfo.processInfo.isRunningXCTest else { return }
        Task { @MainActor in
            SupabaseSyncService.shared.schedulePushFromLocalChange()
        }
    }

    // MARK: Onboarding genres (explicit anchors, no learningRate)

    /// Call once after onboarding; stores IDs and applies anchor weights at full strength.
    func applyOnboardingGenres(loved: [Int], liked: [Int], disliked: [Int]) {
        guard !profile.onboardingComplete else { return }
        profile.onboardingLoved = loved
        profile.onboardingLiked = liked
        profile.onboardingDisliked = disliked
        profile.onboardingComplete = true
        applyOnboardingAnchorWeightsToGenreWeights()
        persistProfile()
    }

    /// After onboarding is complete (e.g. user edits genre preferences in Settings). Replays swipe history onto fresh anchors.
    func replaceOnboardingGenres(loved: [Int], liked: [Int], disliked: [Int]) {
        profile.onboardingLoved = loved
        profile.onboardingLiked = liked
        profile.onboardingDisliked = disliked
        profile.onboardingComplete = true
        recalculateWeightsFromHistory()
        persistProfile()
    }

    private func applyOnboardingAnchorWeightsToGenreWeights() {
        for id in profile.onboardingLoved {
            profile.genreWeights[id] = max(-1, min(1, (profile.genreWeights[id] ?? 0) + 0.6))
        }
        for id in profile.onboardingLiked {
            profile.genreWeights[id] = max(-1, min(1, (profile.genreWeights[id] ?? 0) + 0.25))
        }
        for id in profile.onboardingDisliked {
            profile.genreWeights[id] = max(-1, min(1, (profile.genreWeights[id] ?? 0) - 0.5))
        }
    }

    // MARK: Record

    func record(_ event: SwipeEvent) {
        // Every recorded swipe (including left / dislike) removes the title from future ranked pools.
        profile.seenIds.insert(event.movieId)
        profile.totalSwipes += 1

        // Action multipliers: strong reject (strongSkip) is much stronger than mild skip; watchlist is a moderate positive.
        let mult: Double
        switch event.action {
        case .like:             mult =  1.0
        case .watchlist:        mult =  0.45
        case .skip:             mult = -0.25
        case .strongSkip:       mult = -1.0
        case .rated(let stars): mult = (Double(stars) - 3.0) * 0.5
            profile.ratings[event.movieId] = stars
        }

        let topGenreId = profile.genreWeights.max(by: { $0.value < $1.value })?.key

        if case .like = event.action {
            profile.likedIds.insert(event.movieId, at: 0)
            if profile.likedIds.count > 50 { profile.likedIds = Array(profile.likedIds.prefix(50)) }
        }
        if case .skip = event.action {
            profile.likedIds.removeAll { $0 == event.movieId }
        }
        if case .strongSkip = event.action {
            profile.likedIds.removeAll { $0 == event.movieId }
        }

        let confidence = swipeConfidence()
        let genreIds = event.movie.genres.map(\.id)
        profile.swipeHistory.append(SwipeHistoryEntry(
            movieId: event.movieId,
            genreIds: genreIds,
            mult: mult,
            timestamp: event.timestamp
        ))
        if profile.swipeHistory.count > 150 {
            profile.swipeHistory.removeFirst(profile.swipeHistory.count - 150)
        }

        let weightedMult = mult * confidence

        // Genre updates: divide positive deltas by genre count so Comedy does not fully ride a Drama/Romance like.
        // Within the same movie, genres with higher existing weights get a larger share (tierBoost).
        // Graduated recovery for mildly vs deeply negative weights; contradiction dampening after repeated flips.
        let genres = event.movie.genres
        let genreCount = max(genres.count, 1)
        let genreIdsForTier = genres.map(\.id)
        let maxW = genreIdsForTier.map { profile.genreWeights[$0] ?? 0 }.max() ?? 0
        let minW = genreIdsForTier.map { profile.genreWeights[$0] ?? 0 }.min() ?? 0
        let span = max(maxW - minW, 0.05)

        for genre in genres {
            let w = profile.genreWeights[genre.id] ?? 0
            var delta = weightedMult * Weights.genre
            if mult > 0 {
                delta /= Double(genreCount)
                if w < -0.3 {
                    delta *= 0.5
                } else if w < 0 {
                    delta *= 0.75
                }
                let tierBoost: Double
                if genreIdsForTier.count <= 1 {
                    tierBoost = 1.0
                } else {
                    let relative = (w - minW) / span
                    tierBoost = 0.65 + 0.35 * max(0, min(1, relative))
                }
                delta *= tierBoost
            }
            let isLoved = profile.onboardingLoved.contains(genre.id)
            let momentum: Double = ((isLoved || genre.id == topGenreId) && mult > 0) ? 1.2 : 1.0

            let prevDirection = profile.lastGenreMultDirection[genre.id] ?? 0
            if prevDirection != 0, (prevDirection > 0 && mult < 0) || (prevDirection < 0 && mult > 0) {
                profile.genreVolatility[genre.id, default: 0] += 1
            }
            profile.lastGenreMultDirection[genre.id] = mult
            let volatilityDampen: Double = (profile.genreVolatility[genre.id, default: 0] >= 3) ? 0.5 : 1.0

            adjust(&profile.genreWeights, key: genre.id, delta: delta * momentum * volatilityDampen)
        }
        if case .strongSkip = event.action {
            for genre in event.movie.genres {
                profile.strongSkipCounts[genre.id, default: 0] += 1
                let isLovedGenre = profile.onboardingLoved.contains(genre.id)
                let threshold = isLovedGenre ? 4 : 2
                let weightFloor: Double = isLovedGenre ? -0.2 : -0.5
                if profile.strongSkipCounts[genre.id, default: 0] >= threshold {
                    profile.genreWeights[genre.id] = max(-1.0,
                        min((profile.genreWeights[genre.id] ?? 0) - 0.3, weightFloor))
                }
            }
        }
        if let ds = event.movie.releaseDate, let y = Int(ds.prefix(4)) {
            adjust(&profile.decadeWeights, key: "\(y / 10 * 10)s", delta: weightedMult * Weights.decade)
        }

        if profile.totalSwipes % 25 == 0 {
            recalculateWeightsFromHistory()
        }

        persistProfile()
    }

    /// Nudges actor/director weights after a swipe (detail / credits). Does **not** change `score(_:)`:
    /// `TMDBMovie` in Discover/feed has no per-person ids, so ranking stays genre-era-rating only.
    /// Seeds like “Because you liked …” use **movie id** recommendations from TMDB, not these weights.
    func enrichWithCredits(movieId: Int, cast: [TMDBPerson], crew: [TMDBPerson], wasLiked: Bool) {
        let mult: Double = wasLiked ? 1.0 : -0.2
        let confidence = swipeConfidence()
        let weightedMult = mult * confidence
        for a in cast.prefix(3) {
            adjust(&profile.actorWeights, key: a.id, delta: weightedMult * Weights.actor)
        }
        for d in crew.filter({ $0.job == "Director" }) {
            adjust(&profile.directorWeights, key: d.id, delta: weightedMult * Weights.director)
        }
        persistProfile()
    }

    /// Restores the full taste profile (used by Discover “undo last swipe”).
    func restoreProfile(_ snapshot: TasteProfile) {
        profile = snapshot
        persistProfile()
        objectWillChange.send()
    }

    // MARK: Score / Rank

    /// Batch ranking signal for `TMDBMovie`: genre blend, decade, rating (+ tuning). **No** actor/director
    /// terms — those live in the profile from `enrichWithCredits` but are not applicable to list candidates.
    func score(_ m: TMDBMovie) -> Double {
        guard !profile.seenIds.contains(m.id) else { return -1 }
        var s = 0.0
        // Onboarding is represented only in `genreWeights` (anchors from `applyOnboardingGenres`,
        // then updated by swipes / `recalculateWeightsFromHistory`). We intentionally do **not**
        // add a separate per-genre onboarding bonus here — that double-counted the same signal
        // (once in weights, again in score). Cold-start strength stays in the anchored weights;
        // swipes can move `genreWeights` over time via `adjust` and periodic replay.
        // Normalize by √(genre count) so multi-tag blockbusters do not inflate genreSig vs single-genre films.
        let rawGenreSum = m.genreIds.compactMap { profile.genreWeights[$0] }.reduce(0, +)
        let genreDenom = max(1.0, sqrt(Double(max(1, m.genreIds.count))))
        let gs = rawGenreSum / genreDenom
        if profile.totalSwipes >= 10 && m.genreIds.compactMap({ profile.genreWeights[$0] }).isEmpty {
            return 0.001
        }
        let genreSig = sigmoid(gs)
        s += genreSig * Weights.genre

        if let y = Int(m.year) {
            s += (profile.decadeWeights["\(y / 10 * 10)s"] ?? 0) * Weights.decade
        }
        // Rating only (no standalone popularity weight). Niche-leaning users: dampen rating for
        // very popular TMDB titles so blockbusters do not outrank weak-but-relevant genre matches.
        var ratingContrib = (m.voteAverage / 10.0) * Weights.rating
        if nicheLeaningUser() {
            let pop = max(0, m.popularity)
            let dampen = min(1.0, pop / 200.0)
            ratingContrib *= 1.0 - 0.38 * dampen
        }
        s += ratingContrib

        if m.genreIds.contains(where: { (profile.genreWeights[$0] ?? 0) < 0 }) {
            s *= ScoreTuning.negativeGenreMultiplier
        }
        if profile.totalSwipes >= ScoreTuning.weakGenreOverlapMinSwipes,
           !m.genreIds.compactMap({ profile.genreWeights[$0] }).isEmpty,
           genreSig < ScoreTuning.weakGenreSigmoidCap {
            s *= ScoreTuning.weakGenreScoreMultiplier
        }

        if SuperheroMovieTuning.isLikelySuperheroCluster(genreIds: m.genreIds) {
            s *= SuperheroMovieTuning.popularityGateMultiplier(popularity: m.popularity)
        }
        return max(0, s)
    }

    /// Hard gate for onboarding “don’t like” genres: still excludes if that genre id’s **current**
    /// `genreWeights` value is ≤ 0; once swipes push it above 0, the lane is no longer binding.
    /// Uses `expandedDislikedGenreIdsForFiltering` (e.g. Family dislike also considers Animation).
    func isHardExcludedByOnboardingDislikes(_ movie: TMDBMovie) -> Bool {
        let expanded = GenreCatalog.expandedDislikedGenreIdsForFiltering(profile.onboardingDisliked)
        guard !expanded.isEmpty else { return false }
        for gid in movie.genreIds where expanded.contains(gid) {
            if (profile.genreWeights[gid] ?? 0) <= 0 { return true }
        }
        return false
    }

    // MARK: - Rank a Batch of Candidates

    func rank(_ movies: [TMDBMovie]) -> [TMDBMovie] {
        // Step 1a: remove already-seen movies
        // Step 1b: onboarding dislike gate (expanded genres + live weight; see `isHardExcludedByOnboardingDislikes`)
        let scored = movies
            .filter { !profile.seenIds.contains($0.id) }
            .filter { !isHardExcludedByOnboardingDislikes($0) }
            .sorted { score($0) > score($1) }

        // Step 2: diversity pass — limit how often any one TMDB genre appears in the top window.
        // Counts every genre id on each accepted movie (not only genreIds.first), so secondary
        // tags like Drama on Thriller/Drama still contribute to saturation.
        // Movies that would push any genre past `genreCap` are held back and appended after the window.
        let windowSize = 20
        let genreCap   = 4   // max movies in the first `windowSize` that share any one genre id

        var result:       [TMDBMovie] = []
        var overflow:     [TMDBMovie] = []
        var genreCounts:  [Int: Int]  = [:]

        for movie in scored {
            guard result.count < windowSize else {
                // Beyond the diversity window — append directly
                result.append(movie)
                continue
            }
            let anyGenreCapped = movie.genreIds.contains { genreCounts[$0, default: 0] >= genreCap }
            if !anyGenreCapped {
                result.append(movie)
                for gid in movie.genreIds {
                    genreCounts[gid, default: 0] += 1
                }
            } else {
                overflow.append(movie)
            }
        }

        // Append held-back movies after the diversity window
        result.append(contentsOf: overflow)
        return result
    }

    func recommendationSeeds(count: Int = 5) -> [Int] { Array(profile.likedIds.prefix(count)) }

    func topGenreIds(count: Int = 3) -> [Int] {
        profile.genreWeights.sorted { $0.value > $1.value }.prefix(count).map { $0.key }
    }

    // MARK: Recalibration

    func resetForRecalibration() {
        let seen = profile.seenIds
        let ratings = profile.ratings
        let obLoved = profile.onboardingLoved
        let obLiked = profile.onboardingLiked
        let obDis = profile.onboardingDisliked
        let obDone = profile.onboardingComplete
        let history = profile.swipeHistory
        let totalSwipes = profile.totalSwipes

        profile = TasteProfile()
        profile.seenIds = seen
        profile.ratings = ratings
        profile.onboardingLoved = obLoved
        profile.onboardingLiked = obLiked
        profile.onboardingDisliked = obDis
        profile.onboardingComplete = obDone
        profile.swipeHistory = history
        profile.totalSwipes = totalSwipes

        recalculateWeightsFromHistory()
        persistProfile()
    }

    func fullReset() { profile = TasteProfile(); persistProfile() }

    /// Called when the user removes a movie from their watchlist.
    /// Re-surfaces the title in ranked pools by dropping `seenIds` only; does not change `likedIds` or learned weights.
    func removeFromSeen(movieId: Int) {
        profile.seenIds.remove(movieId)
        persistProfile()
    }

    /// Removes **all** swipe-history rows for this movie id (Discover + detail), rewinds swipe counters,
    /// drops `likedIds` / `ratings`, clears `seenIds` so ranking can surface the title again, replays genre
    /// weights from remaining history (+ onboarding anchors), and rebuilds `strongSkipCounts` from history.
    /// Decade / actor / director deltas from those swipes are not reversed (those paths are incremental only).
    func revokeSwipeSignalsForMovie(movieId: Int) {
        let removedEntries = profile.swipeHistory.filter { $0.movieId == movieId }
        let removedCount = removedEntries.count

        profile.swipeHistory.removeAll { $0.movieId == movieId }
        if removedCount > 0 {
            profile.totalSwipes = max(0, profile.totalSwipes - removedCount)
        }

        profile.likedIds.removeAll { $0 == movieId }
        profile.ratings.removeValue(forKey: movieId)
        profile.seenIds.remove(movieId)

        Self.rebuildStrongSkipCountsReplacing(profile: &profile)

        recalculateWeightsFromHistory()
        persistProfile()
        objectWillChange.send()
    }

    private static func rebuildStrongSkipCountsReplacing(profile: inout TasteProfile) {
        var counts: [Int: Int] = [:]
        for entry in profile.swipeHistory where entry.mult <= -0.9 {
            for gid in entry.genreIds {
                counts[gid, default: 0] += 1
            }
        }
        profile.strongSkipCounts = counts
    }

    // MARK: History replay + decay

    func recalculateWeightsFromHistory() {
        profile.genreWeights = [:]
        // Preserve contradiction memory across replays (e.g. every-25-swipe recalc), but decay so profiles can recover.
        profile.genreVolatility = profile.genreVolatility.mapValues { max(0, $0 / 2) }
        profile.lastGenreMultDirection = [:]
        applyOnboardingAnchorWeightsToGenreWeights()
        for entry in profile.swipeHistory {
            let ageInDays = Date().timeIntervalSince(entry.timestamp) / 86_400
            let decayFactor = exp(-0.005 * ageInDays)
            let decayedMult = entry.mult * decayFactor
            let mult = entry.mult
            let gids = entry.genreIds
            let n = max(gids.count, 1)
            let maxW = gids.map { profile.genreWeights[$0] ?? 0 }.max() ?? 0
            let minW = gids.map { profile.genreWeights[$0] ?? 0 }.min() ?? 0
            let span = max(maxW - minW, 0.05)
            for gid in gids {
                let w = profile.genreWeights[gid] ?? 0
                var d = decayedMult * Weights.genre
                if decayedMult > 0 {
                    d /= Double(n)
                    if w < -0.3 {
                        d *= 0.5
                    } else if w < 0 {
                        d *= 0.75
                    }
                    let tierBoost: Double
                    if gids.count <= 1 {
                        tierBoost = 1.0
                    } else {
                        let relative = (w - minW) / span
                        tierBoost = 0.65 + 0.35 * max(0, min(1, relative))
                    }
                    d *= tierBoost
                }
                let prevDirection = profile.lastGenreMultDirection[gid] ?? 0
                if prevDirection != 0, (prevDirection > 0 && mult < 0) || (prevDirection < 0 && mult > 0) {
                    profile.genreVolatility[gid, default: 0] += 1
                }
                profile.lastGenreMultDirection[gid] = mult
                let volatilityDampen: Double = (profile.genreVolatility[gid, default: 0] >= 3) ? 0.5 : 1.0
                d *= volatilityDampen
                let next = (profile.genreWeights[gid] ?? 0) + d
                profile.genreWeights[gid] = max(-1, min(1, next))
            }
        }
    }

    // MARK: Helpers

    /// Niche-leaning: Drama/Romance weights clearly above Action/Sci‑Fi/Adventure — used only to soften rating+popularity.
    private func nicheLeaningUser() -> Bool {
        guard profile.totalSwipes >= ScoreTuning.nicheMinSwipes else { return false }
        let dr = ScoreTuning.nicheDramaRomanceIds
            .map { profile.genreWeights[$0] ?? 0 }
            .reduce(0, +) / Double(ScoreTuning.nicheDramaRomanceIds.count)
        let sp = ScoreTuning.nicheSpectacleIds
            .map { profile.genreWeights[$0] ?? 0 }
            .reduce(0, +) / Double(ScoreTuning.nicheSpectacleIds.count)
        return dr >= 0.22 && (dr - sp) >= 0.12
    }

    private func swipeConfidence() -> Double {
        switch profile.totalSwipes {
        case 0..<5:   return 0.4
        case 5..<20:  return 0.7
        case 20..<50: return 1.0
        default:      return 1.2
        }
    }

    private func adjust<K: Hashable>(_ dict: inout [K: Double], key: K, delta: Double) {
        // Soft-clamped via tanh — preserves score differentiation across many swipes
        let current = dict[key] ?? 0.0
        let raw = current + delta * learningRate()

        // Soft compression via tanh: maps the full real line smoothly into (-1, 1).
        // Unlike a hard clamp, tanh stays meaningful across many interactions:
        //   raw ≈ 0.5  → compressed ≈ 0.46   (a few early likes)
        //   raw ≈ 1.0  → compressed ≈ 0.76   (solidly liked)
        //   raw ≈ 2.0  → compressed ≈ 0.96   (strongly preferred)
        //   raw ≈ 3.0  → compressed ≈ 0.995  (dominant — approaches but never hits 1.0)
        // The 1.2 multiplier keeps early-session movement fast and responsive.
        dict[key] = tanh(raw * 1.2)
    }

    /// Learning rate decreases as profile matures; floor 0.15 keeps mature profiles responsive.
    /// Surprise boost: recent swipes ignore top genre → temporarily higher rate to pivot taste.
    private func learningRate() -> Double {
        let base = max(0.15, 1.0 / (1.0 + Double(max(profile.totalSwipes, 1)) / 10.0))
        if profile.totalSwipes >= 20, profile.swipeHistory.count >= 5,
           let topGid = profile.genreWeights.max(by: { $0.value < $1.value })?.key {
            let recentGenres = profile.swipeHistory.suffix(5).flatMap { $0.genreIds }
            let topFrequency = recentGenres.filter { $0 == topGid }.count
            if topFrequency == 0 {
                return min(base * 2.0, 0.5)
            }
        }
        return base
    }

    private func sigmoid(_ x: Double) -> Double { 1.0 / (1.0 + exp(-x)) }
}

// MARK: - Recommendation Feed ViewModel

@MainActor
class RecommendationFeedViewModel: ObservableObject {
    @Published var sections: [Section] = []
    @Published var isLoading = false

    struct Section: Identifiable {
        let id       = UUID()
        let title:   String
        let subtitle: String
        let movies:  [TMDBMovie]
    }

    let engine: RecommendationEngine
    let prefs:  StreamingPreferences

    init(engine: RecommendationEngine, prefs: StreamingPreferences) {
        self.engine = engine; self.prefs = prefs
    }

    #if DEBUG
    /// Log line for SIM parity (`evaluate_personalized_section` / Avery snapshots). Console in Xcode only.
    private func logPersonalizedParity(avgTop5: Double, sectionTitle: String, movies: [TMDBMovie]) {
        let ids = movies.prefix(3).map(\.id)
        print("RecommendationFeed.personalized avgTop5=\(String(format: "%.4f", avgTop5)) title=\"\(sectionTitle)\" n=\(movies.count) first3_ids=\(ids)")
    }
    #endif

    func load() async {
        isLoading = true; sections = []
        await withTaskGroup(of: Section?.self) { g in
            g.addTask { await self.personalized() }
            let seeds = self.engine.recommendationSeeds(count: 3)
            if !seeds.isEmpty {
                g.addTask { await self.fetchBecauseYouLiked(seedIds: seeds) }
            }
            g.addTask { await self.trending() }
            g.addTask { await self.gems() }
            for await s in g { if let s { sections.append(s) } }
        }
        sections.sort { a, b in a.title == "For You" && b.title != "For You" }
        isLoading = false
    }

    private func personalized() async -> Section? {
        guard let r = try? await TMDBService.shared.discoverStreamingMovies(
            providerIds: prefs.selectedServiceIds,
            genreIds: engine.topGenreIds(), minRating: 6.5, sortBy: "vote_average.desc"
        ) else { return nil }
        let ranked = engine.rank(r.results)
        guard !ranked.isEmpty else { return nil }

        let topForConfidence = Array(ranked.prefix(5))
        let topScores = topForConfidence.map { engine.score($0) }
        let avgTopScore = topScores.reduce(0, +) / Double(topScores.count)
        if avgTopScore < 0.10 {
            let fallback = r.results
                .filter { !engine.profile.seenIds.contains($0.id) }
                .filter { !engine.isHardExcludedByOnboardingDislikes($0) }
                .sorted { $0.voteAverage > $1.voteAverage }
            guard !fallback.isEmpty else { return nil }
            let fallbackMovies = Array(fallback.prefix(20))
            #if DEBUG
            logPersonalizedParity(avgTop5: avgTopScore, sectionTitle: "Top Rated on Your Services", movies: fallbackMovies)
            #endif
            return Section(
                title: "Top Rated on Your Services",
                subtitle: "While we learn your taste",
                movies: fallbackMovies
            )
        }

        let forYouMovies = Array(ranked.prefix(20))
        #if DEBUG
        logPersonalizedParity(avgTop5: avgTopScore, sectionTitle: "For You", movies: forYouMovies)
        #endif
        return Section(
            title: "For You",
            subtitle: "Based on your taste",
            movies: forYouMovies
        )
    }

    private func fetchBecauseYouLiked(seedIds: [Int]) async -> Section? {
        guard let primarySeedId = seedIds.first else { return nil }
        do {
            // Fetch TMDB recommendations for each seed in parallel
            var allMovies: [TMDBMovie] = []
            try await withThrowingTaskGroup(of: [TMDBMovie].self) { group in
                for seedId in seedIds {
                    group.addTask {
                        let response = try await TMDBService.shared.fetchMovieRecommendations(id: seedId)
                        return response.results
                    }
                }
                for try await movies in group {
                    allMovies.append(contentsOf: movies)
                }
            }

            // Deduplicate by movie ID, filter seen movies
            var seenInBatch = Set<Int>()
            let unique = allMovies.filter { movie in
                guard !engine.profile.seenIds.contains(movie.id) else { return false }
                return seenInBatch.insert(movie.id).inserted
            }

            // Cross-rank against taste profile for best matches
            let ranked = engine.rank(unique)
            guard !ranked.isEmpty else { return nil }

            // Use the primary seed's title for the section header
            let detail = try await TMDBService.shared.fetchMovieDetail(id: primarySeedId)
            return Section(
                title: "Because you liked \(detail.title)",
                subtitle: "On your streaming services",
                movies: Array(ranked.prefix(20))
            )
        } catch {
            return nil
        }
    }

    private func trending() async -> Section? {
        guard let r = try? await TMDBService.shared.discoverStreamingMovies(
            providerIds: prefs.selectedServiceIds, sortBy: "popularity.desc"
        ) else { return nil }
        let unseen = r.results.filter { !engine.profile.seenIds.contains($0.id) }
        return unseen.isEmpty ? nil : Section(title: "Trending on Your Services", subtitle: "Popular right now", movies: Array(unseen.prefix(20)))
    }

    private func gems() async -> Section? {
        guard let r = try? await TMDBService.shared.discoverStreamingMovies(
            providerIds: prefs.selectedServiceIds, minRating: 7.5, sortBy: "vote_average.desc"
        ) else { return nil }
        let gems = r.results.filter { $0.popularity < 50 && !engine.profile.seenIds.contains($0.id) }
                             .sorted { $0.voteAverage > $1.voteAverage }
        return gems.isEmpty ? nil : Section(title: "Hidden Gems", subtitle: "Highly rated, lesser known", movies: Array(gems.prefix(20)))
    }
}

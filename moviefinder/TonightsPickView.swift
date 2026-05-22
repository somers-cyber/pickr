// TonightsPickView.swift
// "Watch Now" — decide what to watch in under 10 seconds.
// Exactly 3 options. No infinite scrolling. No browsing.
//
// Wires into existing project:
//   TMDBService.swift          → TMDBMovie, tmdbPosterURL
//   MovieDetailView.swift      → MovieDetailView
//   RecommendationEngine.swift → RecommendationEngine

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Watch Now layout (8 / 12 / 16 / 20 rhythm + single filter accent)

private enum WatchNowChrome {
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    /// Selected runtime chips — matches `AppTheme.brand` (Pickr red).
    static var accent: Color { AppTheme.brand }
    static let hairline = Color.primary.opacity(0.08)
    static let headerShadow = Color.black.opacity(0.05)
}

// MARK: - Filter Enums

enum TimeSlot: String, CaseIterable, Identifiable {
    case any      = "Any Length"
    case under120 = "Under 2hr"
    case under90  = "Under 90m"

    var id: String { rawValue }

    var maxMinutes: Int {
        switch self {
        case .any:      return Int.max
        case .under90:  return 90
        case .under120: return 120
        }
    }

    /// Compact chip labels; `.any` uses `rawValue` (“Any Length”) with no clock icon.
    fileprivate var watchNowChipTitle: String {
        switch self {
        case .any: return rawValue
        case .under90: return "Under 90m"
        case .under120: return "Under 2h"
        }
    }

    fileprivate var watchNowChipShowsIcon: Bool {
        self != .any
    }
}

private func estimatedRuntime(for slot: TimeSlot) -> Int {
    switch slot {
    case .any:      return 110
    case .under90:  return 88
    case .under120: return 110
    }
}

// MARK: - Models

struct PickItem: Identifiable {
    let id: UUID
    let movie:         WatchNowMovie
    let reason:        String
    let platform:      String
    let platformColor: Color

    init(id: UUID = UUID(), movie: WatchNowMovie, reason: String, platform: String, platformColor: Color) {
        self.id = id
        self.movie = movie
        self.reason = reason
        self.platform = platform
        self.platformColor = platformColor
    }
}

/// TMDB-backed row model for Watch Now cards (no local mock catalog).
struct WatchNowMovie: Identifiable {
    let id:          Int
    let title:       String
    let year:        String
    let runtimeMin:  Int
    let posterPath:  String?
    let voteAverage: Double
    let genreIds:    [Int]

    var posterURL: URL? {
        guard let p = posterPath else { return nil }
        return tmdbPosterURL(p)
    }

    var runtimeFormatted: String {
        let h = runtimeMin / 60
        let m = runtimeMin % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    init(tmdb: TMDBMovie, detail: TMDBMovieDetail?, timeSlot: TimeSlot) {
        id = tmdb.id
        title = tmdb.title
        year = tmdb.year
        if let r = detail?.runtime {
            runtimeMin = r
        } else {
            runtimeMin = estimatedRuntime(for: timeSlot)
        }
        posterPath = tmdb.posterPath ?? detail?.posterPath ?? detail?.backdropPath
        voteAverage = tmdb.voteAverage
        genreIds = tmdb.genreIds
    }
}

// MARK: - Watch Now explanations (user-facing)

/// TMDB genre id → display name for taste / card labels (catalog + common TMDB ids).
private func tmdbGenreDisplayNameIfKnown(_ id: Int) -> String? {
    if let g = GenreCatalog.onboarding.first(where: { $0.tmdbGenreId == id }) {
        return g.displayName
    }
    let extra: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Sci-Fi",
        53: "Thriller", 10752: "War", 37: "Western",
    ]
    return extra[id]
}

/// Short taste line — genre-only label when taste matches (no “Because you like …” prefix).
private func genreTasteExplanationLine(movie: TMDBMovie, profile: TasteProfile) -> String? {
    for gid in movie.genreIds where profile.onboardingLoved.contains(gid) {
        if let name = tmdbGenreDisplayNameIfKnown(gid) {
            return name
        }
    }
    var bestId: Int?
    var bestW = -Double.infinity
    for g in movie.genreIds {
        let w = profile.genreWeights[g] ?? 0
        if w > bestW {
            bestW = w
            bestId = g
        }
    }
    if let gid = bestId, bestW > 0.06, let name = tmdbGenreDisplayNameIfKnown(gid) {
        return name
    }
    for gid in movie.genreIds where profile.onboardingLiked.contains(gid) {
        if let name = tmdbGenreDisplayNameIfKnown(gid) {
            return name
        }
    }
    return nil
}

private func watchNowPickExplanation(
    movie: TMDBMovie,
    runtimeMin: Int,
    time: TimeSlot,
    engine: RecommendationEngine,
    onYourServices: Bool,
    selectedGenreId: Int?
) -> String {
    if let gid = selectedGenreId, let chipLabel = GenreCatalog.displayName(forTmdbGenreId: gid) {
        return chipLabel
    }

    let profile = engine.profile

    if let line = genreTasteExplanationLine(movie: movie, profile: profile) {
        return line
    }

    if time != .any, runtimeMin <= time.maxMinutes + 5 {
        switch time {
        case .under90: return "Short and easy watch"
        case .under120: return "Fits the time you have tonight"
        default: break
        }
    }

    if movie.voteAverage >= 7.5 {
        return "Highly rated by viewers"
    }
    if movie.voteAverage >= 6.5 {
        return "Well reviewed by viewers"
    }

    if movie.popularity > 80 {
        return "Trending right now"
    }
    if movie.popularity > 35 {
        return "Popular right now"
    }

    if onYourServices {
        return "Popular on your streaming services"
    }

    return "Matched to what you enjoy"
}

// MARK: - Recommendation Logic (TMDB + engine)

/// Base taste score from the engine, then a **genre chip layer** so the same profile doesn’t yield identical
/// top-3 when different onboarding genres are selected.

/// Combined rank for Watch Now: `RecommendationEngine.score` × genre alignment when a genre chip is set.
private func watchNowRankScore(_ m: TMDBMovie, selectedGenreId: Int?, engine: RecommendationEngine) -> Double {
    let base = engine.score(m)
    guard let gid = selectedGenreId else { return base }
    guard base >= 0 else { return base }
    let overlap = Set(m.genreIds).intersection([gid]).count
    if overlap == 0 {
        return base * 0.78
    }
    let t = Double(overlap)
    return base * (1.0 + 0.22 * min(1.0, t))
}

private func moviesRankedForWatchNow(_ movies: [TMDBMovie], selectedGenreId: Int?, engine: RecommendationEngine) -> [TMDBMovie] {
    movies.sorted {
        watchNowRankScore($0, selectedGenreId: selectedGenreId, engine: engine)
            > watchNowRankScore($1, selectedGenreId: selectedGenreId, engine: engine)
    }
}

private func fetchDiscoverCandidates(
    providerIds: Set<Int>,
    genreIds: [Int],
    maxRuntime: Int?,
    seenIds: Set<Int>,
    excluding: Set<Int>,
    minVoteCount: Int = 500,
    pageRange: ClosedRange<Int> = 1...6,
    sortBy: String = "popularity.desc"
) async throws -> [TMDBMovie] {
    var pool: [TMDBMovie] = []
    var seenInPool = Set<Int>()
    for page in pageRange {
        let response = try await TMDBService.shared.discoverStreamingMovies(
            providerIds: providerIds,
            genreIds: genreIds,
            minRating: 0,
            sortBy: sortBy,
            page: page,
            maxRuntime: maxRuntime,
            minVoteCount: minVoteCount
        )
        for m in response.results {
            guard !seenIds.contains(m.id) else { continue }
            guard !excluding.contains(m.id) else { continue }
            guard !seenInPool.contains(m.id) else { continue }
            seenInPool.insert(m.id)
            pool.append(m)
        }
        if pool.count >= 48 { break }
    }
    return pool
}

/// When the main discover pulls return nothing (or we need more titles), stay on **provider-filtered**
/// discover — never use global trending, which ignores `with_watch_providers` and breaks “Netflix only” etc.
private func fetchDiscoverFallbackCandidates(
    providerIds: Set<Int>,
    maxRuntime: Int?,
    seenIds: Set<Int>,
    excluding: Set<Int>,
    genreIds: [Int] = []
) async throws -> [TMDBMovie] {
    try await fetchDiscoverCandidates(
        providerIds: providerIds,
        genreIds: genreIds,
        maxRuntime: maxRuntime,
        seenIds: seenIds,
        excluding: excluding,
        minVoteCount: 300
    )
}

/// TMDB `/movie/{id}/recommendations` for Watch Now — deduped against discover, `seenIds`, and `excluding`.
/// Only runs when the user has at least 3 likes; uses the 2 most recently liked titles as seeds.
private func fetchWatchNowRecommendationCandidates(
    engine: RecommendationEngine,
    seenIds: Set<Int>,
    excluding: Set<Int>,
    existingIds: Set<Int>
) async -> [TMDBMovie] {
    let liked = engine.profile.likedIds.filter { !seenIds.contains($0) }
    guard liked.count >= 3 else { return [] }
    let seedIds = Array(liked.prefix(2))
    guard seedIds.count == 2 else { return [] }

    async let r0 = try? await TMDBService.shared.fetchMovieRecommendations(id: seedIds[0], page: 1)
    async let r1 = try? await TMDBService.shared.fetchMovieRecommendations(id: seedIds[1], page: 1)
    let responses = await [r0, r1]

    var taken = existingIds
    var out: [TMDBMovie] = []
    out.reserveCapacity(40)
    for res in responses {
        guard let res else { continue }
        for m in res.results {
            guard !seenIds.contains(m.id), !excluding.contains(m.id), !taken.contains(m.id) else { continue }
            taken.insert(m.id)
            out.append(m)
        }
    }
    return out
}

/// Caps recommendation-sourced rows at **at most 50%** of the final `prefix(72)` pool (max 36 recs).
/// Trims discover first so recommendation rows are never more than half of `discTake + recTake`.
private func mergeDiscoverWithRecommendationCandidates(
    discoverPool: [TMDBMovie],
    recs: [TMDBMovie]
) -> [TMDBMovie] {
    guard !recs.isEmpty else { return discoverPool }
    let recTake = min(recs.count, discoverPool.count, 36)
    guard recTake > 0 else { return discoverPool }
    let discTake = min(discoverPool.count, 72 - recTake)
    let dPart = Array(discoverPool.prefix(discTake))
    let rPart = Array(recs.prefix(recTake))
    return dPart + rPart
}

/// Extra provider-filtered pages when we already have a pool but need more titles (e.g. runtime / genre filters removed most candidates).
private func fetchDiscoverExtraCandidatesForMerge(
    providerIds: Set<Int>,
    maxRuntime: Int?,
    seenIds: Set<Int>,
    excluding: Set<Int>,
    genreIds: [Int] = []
) async throws -> [TMDBMovie] {
    try await fetchDiscoverCandidates(
        providerIds: providerIds,
        genreIds: genreIds,
        maxRuntime: maxRuntime,
        seenIds: seenIds,
        excluding: excluding,
        minVoteCount: 300,
        pageRange: 7...12,
        sortBy: "vote_average.desc"
    )
}

/// Parallel detail fetch for the first `limit` unique movies in order (caps network fan-out).
/// Fetches in batches of `batchSize` to avoid overwhelming TMDB rate limits.
private func fetchMovieDetailsMap(for orderedMovies: [TMDBMovie], limit: Int = 60, batchSize: Int = 20) async -> [Int: TMDBMovieDetail] {
    var seen = Set<Int>()
    var ids: [Int] = []
    ids.reserveCapacity(min(limit, orderedMovies.count))
    for m in orderedMovies {
        if ids.count >= limit { break }
        if seen.insert(m.id).inserted { ids.append(m.id) }
    }
    var map: [Int: TMDBMovieDetail] = [:]
    for batchStart in stride(from: 0, to: ids.count, by: batchSize) {
        let batch = Array(ids[batchStart ..< min(batchStart + batchSize, ids.count)])
        await withTaskGroup(of: (Int, TMDBMovieDetail?).self) { group in
            for id in batch {
                group.addTask {
                    (id, try? await TMDBService.shared.fetchMovieDetail(id: id))
                }
            }
            for await (id, detail) in group {
                if let detail { map[id] = detail }
            }
        }
    }
    return map
}

// MARK: - Diversity + exploration (final 3 picks)

/// Penalizes redundancy when a candidate shares genres with picks already chosen (10% / 25%).
private func diversityMultiplier(genreIds: [Int], usedGenreIds: Set<Int>) -> Double {
    let overlap = Set(genreIds).intersection(usedGenreIds).count
    if overlap == 0 { return 1.0 }
    if overlap == 1 { return 0.90 }
    return 0.75
}

private func unifiedGenreIds(movie: TMDBMovie, detail: TMDBMovieDetail?) -> Set<Int> {
    var ids = Set(movie.genreIds)
    if let d = detail {
        ids.formUnion(d.genres.map(\.id))
    }
    return ids
}

/// Filters to titles that pass runtime (when strict) and the same live-weight onboarding gate as `rank()`.
/// When streamer filters apply, TMDB `/discover` can disagree with `/movie/{id}` watch providers—we require detail match so badges and UX stay honest.
private func eligibleForWatchNowPicks(
    movies: [TMDBMovie],
    detailMap: [Int: TMDBMovieDetail],
    strictRuntime: Int?,
    selectedGenreId: Int?,
    providerIds: Set<Int>,
    engine: RecommendationEngine
) -> [TMDBMovie] {
    movies.filter { m in
        if let gid = selectedGenreId {
            let gids = unifiedGenreIds(movie: m, detail: detailMap[m.id])
            guard gids.contains(gid) else { return false }
        }
        if !providerIds.isEmpty {
            guard let d = detailMap[m.id],
                  let flat = d.watchProviders?.results["US"]?.flatrate,
                  flat.contains(where: { providerIds.contains($0.providerId) })
            else { return false }
        }
        if engine.isHardExcludedByOnboardingDislikes(m) { return false }
        if let d = detailMap[m.id], let dr = d.runtime, dr < TMDBDiscoverDefaults.minimumRuntimeMinutes { return false }
        if let cap = strictRuntime {
            guard let d = detailMap[m.id], let dr = d.runtime, dr <= cap + 5 else { return false }
        }
        return true
    }
}

/// After `watchNowRankScore` ordering: pick 1 = best; pick 2 = diversity-adjusted vs pick 1;
/// pick 3 = exploration above a quality floor.
private func selectFinalWatchNowMovies(
    from movies: [TMDBMovie],
    detailMap: [Int: TMDBMovieDetail],
    strictRuntime: Int?,
    selectedGenreId: Int?,
    providerIds: Set<Int>,
    engine: RecommendationEngine
) -> [TMDBMovie] {
    let eligible = eligibleForWatchNowPicks(
        movies: movies,
        detailMap: detailMap,
        strictRuntime: strictRuntime,
        selectedGenreId: selectedGenreId,
        providerIds: providerIds,
        engine: engine
    )
    guard !eligible.isEmpty else { return [] }

    let sorted = eligible.sorted {
        watchNowRankScore($0, selectedGenreId: selectedGenreId, engine: engine)
            > watchNowRankScore($1, selectedGenreId: selectedGenreId, engine: engine)
    }
    let topScore = watchNowRankScore(sorted[0], selectedGenreId: selectedGenreId, engine: engine)

    let first = sorted[0]
    let usedGenres = Set(first.genreIds)

    if sorted.count == 1 { return [first] }

    var bestSecond: TMDBMovie?
    var bestAdjusted = -Double.infinity
    for m in sorted where m.id != first.id {
        let adj = watchNowRankScore(m, selectedGenreId: selectedGenreId, engine: engine)
            * diversityMultiplier(genreIds: m.genreIds, usedGenreIds: usedGenres)
        if adj > bestAdjusted {
            bestAdjusted = adj
            bestSecond = m
        } else if adj == bestAdjusted, let cur = bestSecond,
                  watchNowRankScore(m, selectedGenreId: selectedGenreId, engine: engine)
                    > watchNowRankScore(cur, selectedGenreId: selectedGenreId, engine: engine) {
            bestSecond = m
        }
    }
    guard let second = bestSecond else { return [first] }

    if sorted.count == 2 { return [first, second] }

    let dominant = Set(first.genreIds).union(second.genreIds)
    let remaining = sorted.filter { $0.id != first.id && $0.id != second.id }
    let qualityFloor = max(0.06, topScore * 0.72)

    func explorationTieBreak(_ m: TMDBMovie) -> Double {
        var rank = watchNowRankScore(m, selectedGenreId: selectedGenreId, engine: engine)
        let stretch = !Set(m.genreIds).subtracting(dominant).isEmpty
        if stretch { rank += 0.04 }
        for g in m.genreIds {
            if abs(engine.profile.genreWeights[g] ?? 0) <= 0.2 { rank += 0.025 }
            if engine.profile.onboardingLiked.contains(g) { rank += 0.02 }
        }
        return rank
    }

    let explorationPool = remaining.filter {
        watchNowRankScore($0, selectedGenreId: selectedGenreId, engine: engine) >= qualityFloor
    }
    let stretched = explorationPool.filter { !Set($0.genreIds).subtracting(dominant).isEmpty }
    let thirdSource = stretched.isEmpty ? explorationPool : stretched
    guard let third = thirdSource.max(by: { explorationTieBreak($0) < explorationTieBreak($1) })
        ?? remaining.max(by: {
            watchNowRankScore($0, selectedGenreId: selectedGenreId, engine: engine)
                < watchNowRankScore($1, selectedGenreId: selectedGenreId, engine: engine)
        })
    else { return [first, second] }

    return [first, second, third]
}

private func makePickItems(
    from ordered: [TMDBMovie],
    detailMap: [Int: TMDBMovieDetail],
    time: TimeSlot,
    providerIds: Set<Int>,
    selectedGenreId: Int?,
    engine: RecommendationEngine
) -> [PickItem] {
    ordered.map { movie in
        let detail = detailMap[movie.id]
        let flatrateProviders = detail?.watchProviders?.results["US"]?.flatrate ?? []
        let provider: TMDBMovieDetail.WatchProvider? = providerIds.isEmpty
            ? flatrateProviders.first
            : flatrateProviders.first(where: { providerIds.contains($0.providerId) })
        let onYourServices = flatrateProviders.contains(where: { providerIds.contains($0.providerId) })
        let platformColor = StreamingService.all
            .first(where: { $0.name == provider?.providerName })?.color ?? Color.gray
        let wm = WatchNowMovie(tmdb: movie, detail: detail, timeSlot: time)
        let explanation = watchNowPickExplanation(
            movie: movie,
            runtimeMin: wm.runtimeMin,
            time: time,
            engine: engine,
            onYourServices: onYourServices,
            selectedGenreId: selectedGenreId
        )
        return PickItem(
            movie: wm,
            reason: explanation,
            platform: provider?.providerName ?? "Streaming",
            platformColor: platformColor
        )
    }
}

/// Fetches TMDB candidates for Watch Now.
/// Genre chips send a **single** `with_genres` id (`discoverStreamingMovies` uses `|` → OR among listed ids).
/// We never mix a chip genre with taste `topGenreIds` — that OR would surface unrelated genres (e.g. Horror on Comedy chip).
private func gatherWatchNowPool(
    activeGenreIds: [Int],
    selectedGenreId: Int?,
    maxRuntime: Int?,
    providerIds: Set<Int>,
    seenIds: Set<Int>,
    excluding: Set<Int>,
    engine: RecommendationEngine
) async throws -> (movies: [TMDBMovie], discoverHadResults: Bool) {
    var seenInPool = Set<Int>()
    var pool: [TMDBMovie] = []

    func appendMovies(_ movies: [TMDBMovie]) {
        for m in movies {
            guard !seenIds.contains(m.id), !excluding.contains(m.id), !seenInPool.contains(m.id) else { continue }
            seenInPool.insert(m.id)
            pool.append(m)
        }
    }

    func pull(genreIds: [Int]) async throws {
        let batch = try await fetchDiscoverCandidates(
            providerIds: providerIds,
            genreIds: genreIds,
            maxRuntime: maxRuntime,
            seenIds: seenIds,
            excluding: excluding
        )
        appendMovies(batch)
    }

    // Tier 1 — selected onboarding genre, else taste-weighted genres (same as former “Any” path).
    if !activeGenreIds.isEmpty {
        try await pull(genreIds: activeGenreIds)
    } else {
        let top = engine.topGenreIds(count: 5)
        if !top.isEmpty { try await pull(genreIds: top) }
    }

    if activeGenreIds.isEmpty, pool.count < 48 {
        try await pull(genreIds: [])
    }

    let discoverHadResults = !pool.isEmpty

    if pool.isEmpty {
        let fallback = try await fetchDiscoverFallbackCandidates(
            providerIds: providerIds,
            maxRuntime: maxRuntime,
            seenIds: seenIds,
            excluding: excluding,
            genreIds: activeGenreIds.isEmpty ? [] : activeGenreIds
        )
        appendMovies(fallback)
    }

    if pool.isEmpty, activeGenreIds.isEmpty {
        let fallback = try await fetchDiscoverFallbackCandidates(
            providerIds: providerIds,
            maxRuntime: maxRuntime,
            seenIds: seenIds,
            excluding: excluding,
            genreIds: []
        )
        appendMovies(fallback)
    }

    let rawRecCandidates = await fetchWatchNowRecommendationCandidates(
        engine: engine,
        seenIds: seenIds,
        excluding: excluding,
        existingIds: Set(pool.map(\.id))
    )
    let recCandidates: [TMDBMovie] = selectedGenreId.map { gid in
        rawRecCandidates.filter { $0.genreIds.contains(gid) }
    } ?? rawRecCandidates
    pool = mergeDiscoverWithRecommendationCandidates(discoverPool: pool, recs: recCandidates)

    let ranked = moviesRankedForWatchNow(pool, selectedGenreId: selectedGenreId, engine: engine)
    return (Array(ranked.prefix(72)), discoverHadResults)
}

/// Live picks: discover → taste + optional genre rank → detail filter for runtime.
func recommendPicks(
    selectedGenreId: Int?,
    time: TimeSlot,
    providerIds: Set<Int>,
    seenIds: Set<Int>,
    excluding: Set<Int>,
    engine: RecommendationEngine
) async -> [PickItem] {
    let activeGenreIds: [Int] = selectedGenreId.map { [$0] } ?? []
    let maxRuntime: Int? = (time == .any) ? nil : time.maxMinutes
    let strictRuntime = time == .any ? nil : time.maxMinutes

    do {
        let (pool, discoverHadResults) = try await gatherWatchNowPool(
            activeGenreIds: activeGenreIds,
            selectedGenreId: selectedGenreId,
            maxRuntime: maxRuntime,
            providerIds: providerIds,
            seenIds: seenIds,
            excluding: excluding,
            engine: engine
        )

        guard !pool.isEmpty else { return [] }

        var detailMap = await fetchMovieDetailsMap(for: pool, limit: 60)

        guard !Task.isCancelled else { return [] }

        func buildPicks(from movies: [TMDBMovie]) -> [PickItem] {
            let chosen = selectFinalWatchNowMovies(
                from: movies,
                detailMap: detailMap,
                strictRuntime: strictRuntime,
                selectedGenreId: selectedGenreId,
                providerIds: providerIds,
                engine: engine
            )
            return makePickItems(
                from: chosen,
                detailMap: detailMap,
                time: time,
                providerIds: providerIds,
                selectedGenreId: selectedGenreId,
                engine: engine
            )
        }

        var mergedPool = pool
        var built = buildPicks(from: mergedPool)

        func mergeDiscoverFallbackIfNeeded() async throws {
            guard built.count < 3 else { return }
            let extraExclude = excluding
                .union(Set(built.map(\.movie.id)))
                .union(Set(mergedPool.map(\.id)))
            let more = try await fetchDiscoverExtraCandidatesForMerge(
                providerIds: providerIds,
                maxRuntime: maxRuntime,
                seenIds: seenIds,
                excluding: extraExclude,
                genreIds: activeGenreIds.isEmpty ? [] : activeGenreIds
            )
            guard !more.isEmpty else { return }
            let rankedMore = moviesRankedForWatchNow(more, selectedGenreId: selectedGenreId, engine: engine)
            var seen = Set(mergedPool.map(\.id))
            for m in rankedMore where !seen.contains(m.id) {
                mergedPool.append(m)
                seen.insert(m.id)
            }
            let extraDetails = await fetchMovieDetailsMap(for: mergedPool, limit: 72)
            for (id, d) in extraDetails { detailMap[id] = d }
            built = buildPicks(from: mergedPool)
        }

        if built.count < 3, discoverHadResults {
            try await mergeDiscoverFallbackIfNeeded()
        }
        if built.count < 3 {
            try await mergeDiscoverFallbackIfNeeded()
        }

        return built
    } catch {
        #if DEBUG
        print("[WatchNow recommendPicks] \(error.localizedDescription)")
        #endif
        return []
    }
}

// MARK: - ViewModel

@MainActor
final class WatchNowViewModel: ObservableObject {
    @Published var picks:           [PickItem] = []
    @Published var selectedGenreId: Int?     = nil  // nil = Any / no filter
    @Published var selectedTime:    TimeSlot  = .any
    @Published var isRefreshing:    Bool      = false

    private var seed = 0
    /// Bumps on each `scheduleGeneratePicks()` so stale async completions don’t overwrite `picks` or `isRefreshing`.
    private var generation = 0
    private var shownMovieIds: Set<Int> = []
    private var providerIds: Set<Int> = []
    private var generateTask: Task<Void, Never>?
    private let engine: RecommendationEngine
    private let prefs: StreamingPreferences

    init(engine: RecommendationEngine, prefs: StreamingPreferences) {
        self.engine = engine
        self.prefs = prefs
    }

    func generatePicks(generation gen: Int) async {
        guard !Task.isCancelled else { return }
        // Always align with persisted streaming prefs (fixes stale / empty provider filter).
        setProviderIds(prefs.selectedServiceIds)
        isRefreshing = true
        defer {
            // Don’t clear loading state if a newer run has started (cancelled tasks still run defer).
            if gen == generation { isRefreshing = false }
        }

        let blocked = engine.profile.seenIds.union(MovieDetailFeedbackStore.shared.dislikedMovieIds)
        var generated = await recommendPicks(
            selectedGenreId: selectedGenreId,
            time: selectedTime,
            providerIds: providerIds,
            seenIds: blocked,
            excluding: shownMovieIds,
            engine: engine
        )
        guard !Task.isCancelled else { return }
        guard gen == generation else { return }

        if generated.isEmpty {
            shownMovieIds.removeAll()
            guard gen == generation else { return }
            generated = await recommendPicks(
                selectedGenreId: selectedGenreId,
                time: selectedTime,
                providerIds: providerIds,
                seenIds: blocked,
                excluding: [],
                engine: engine
            )
        }
        guard !Task.isCancelled else { return }
        guard gen == generation else { return }

        picks = generated
        shownMovieIds.formUnion(generated.map(\.movie.id))
        seed += 1
    }

    func setProviderIds(_ ids: Set<Int>) {
        providerIds = ids
    }

    /// All Watch Now filters at defaults: All Streamers, Any Genre, Any Length.
    func resetFiltersToDefaults() {
        generateTask?.cancel()
        selectedGenreId = nil
        selectedTime = .any
        providerIds = []
    }

    /// Clears rotation memory when filters change so a new query isn’t starved by old exclusions.
    func resetShownMovieIdsForNewFilters() {
        shownMovieIds.removeAll()
    }

    func applyGenre(_ genreId: Int?) {
        selectedGenreId = genreId
        seed = 0
        shownMovieIds = Set(picks.map(\.movie.id))
        scheduleGeneratePicks()
    }

    func applyTime(_ slot: TimeSlot) {
        selectedTime = slot
        seed = 0
        shownMovieIds = Set(picks.map(\.movie.id))
        scheduleGeneratePicks()
    }

    /// User explicitly wants a new trio — exclude the current three so ranking can’t return the same titles.
    func shufflePicks() {
        shownMovieIds.formUnion(picks.map(\.movie.id))
        seed += 1
        scheduleGeneratePicks()
    }

    /// Wraps `generatePicks()` so SwiftUI views avoid `Task` / `SwiftUI.Task` ambiguity.
    /// Cancels any in-flight generation so rapid filter changes don’t apply stale results.
    func scheduleGeneratePicks() {
        generateTask?.cancel()
        generation += 1
        let gen = generation
        generateTask = Task { @MainActor in
            await self.generatePicks(generation: gen)
        }
    }
}

// MARK: - Main View

struct WatchNowView: View {
    @ObservedObject var vm: WatchNowViewModel
    /// Parent sets `true` when the user selects the Watch Now tab for the first time (see `MainTabView`).
    @Binding private var triggerServicesIntroFromTab: Bool
    @EnvironmentObject var engine: RecommendationEngine
    @EnvironmentObject var prefs: StreamingPreferences
    @ObservedObject private var genrePrefsStore = GenrePreferencesStore.shared
    @AppStorage("genre_onboarding_complete") private var genreOnboardingComplete = false
    @AppStorage("watch_now_info_coach_dismissed") private var watchNowInfoCoachDismissed = false
    @AppStorage("watch_now_services_intro_complete") private var watchNowServicesIntroComplete = false
    @State private var watchNowInfoCoachVisible = false
    @State private var watchNowInfoCoachManualOpen = false
    @State private var firstLaunchWatchNowCoachWork: DispatchWorkItem?
    @State private var selectedPick: PickItem?
    @State private var showSearchSheet = false
    /// Same Genre Preferences flow as Curate (`film.stack`).
    @State private var showGenreSheet = false
    /// Set after the search sheet closes so `MovieDetailView` can present cleanly.
    @State private var pendingDetailFromSearch: TMDBMovie?
    @State private var movieDetailFromSearch: TMDBMovie?

    init(vm: WatchNowViewModel, triggerServicesIntroFromTab: Binding<Bool> = .constant(false)) {
        _vm = ObservedObject(wrappedValue: vm)
        _triggerServicesIntroFromTab = triggerServicesIntroFromTab
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: WatchNowChrome.s12) {
                        header
                        streamingServicesRow
                        genreRow
                        timeRow
                    }
                    .padding(.bottom, 10)
                    .background(Color(.systemGroupedBackground))
                    .shadow(color: WatchNowChrome.headerShadow, radius: 8, x: 0, y: 3)

                    Rectangle()
                        .fill(WatchNowChrome.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, WatchNowChrome.s20)

                    pickList
                        .padding(.top, 10)

                    shuffleButton
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay {
                if watchNowInfoCoachVisible && genreOnboardingComplete && (!watchNowInfoCoachDismissed || watchNowInfoCoachManualOpen) {
                    WatchNowInfoCoachOverlay(onDismiss: dismissWatchNowInfoCoach)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .zIndex(200)
                }
            }
            .sheet(item: $selectedPick) { pick in
                WatchNowDetailBridge(pick: pick, engine: engine)
            }
            .sheet(isPresented: $showSearchSheet, onDismiss: presentPendingSearchDetailIfNeeded) {
                WatchNowMovieSearchView(onSelectMovie: handleSearchMovieSelected)
            }
            .sheet(item: $movieDetailFromSearch) { movie in
                MovieDetailView(movie: movie, engine: engine)
                    .environmentObject(WatchlistStore.shared)
            }
            .sheet(isPresented: $showGenreSheet) {
                NavigationStack {
                    GenreOnboardingView(
                        genrePrefs: GenrePreferencesStore.shared,
                        primaryButtonTitle: "Save",
                        showMarketingSubtitle: false
                    ) {
                        let gp = GenrePreferencesStore.shared.genrePreferences
                        let buckets = GenreCatalog.engineOnboardingGenreIds(from: gp)
                        engine.replaceOnboardingGenres(
                            loved: buckets.loved,
                            liked: buckets.liked,
                            disliked: buckets.disliked
                        )
                        showGenreSheet = false
                        vm.resetShownMovieIdsForNewFilters()
                        vm.scheduleGeneratePicks()
                    }
                    .environmentObject(engine)
                    .environmentObject(prefs)
                    .navigationTitle("Genre Preferences")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showGenreSheet = false }
                        }
                    }
                }
            }
            .onAppear {
                vm.setProviderIds(prefs.selectedServiceIds)
                if vm.picks.isEmpty {
                    vm.scheduleGeneratePicks()
                }
                consumeServicesIntroTriggerIfNeeded()
                scheduleFirstLaunchWatchNowInfoCoachIfNeeded()
                clearWatchNowGenreIfDislikedByPreferences()
            }
            .onChange(of: genreOnboardingComplete) { _, done in
                if done { scheduleFirstLaunchWatchNowInfoCoachIfNeeded() }
            }
            .onChange(of: triggerServicesIntroFromTab, initial: false) { _, _ in
                consumeServicesIntroTriggerIfNeeded()
            }
            // Re-fetch when streaming filters change — reset rotation so TMDB isn’t over‑excluded.
            .onChange(of: prefs.selectedServiceIds, initial: false) { _, newIds in
                vm.setProviderIds(newIds)
                vm.resetShownMovieIdsForNewFilters()
                vm.scheduleGeneratePicks()
            }
            .onChange(of: genrePrefsStore.genrePreferences) { _, _ in
                clearWatchNowGenreIfDislikedByPreferences()
            }
        }
    }

    /// If the onboarding genre for the current chip became “dislike”, fall back to Any Genre and refresh picks.
    private func clearWatchNowGenreIfDislikedByPreferences() {
        guard let gid = vm.selectedGenreId else { return }
        guard let name = GenreCatalog.onboarding.first(where: { $0.tmdbGenreId == gid })?.displayName else {
            vm.applyGenre(nil)
            return
        }
        if GenreCatalog.level(for: name, in: genrePrefsStore.genrePreferences) == .dislike {
            vm.applyGenre(nil)
        }
    }

    private func consumeServicesIntroTriggerIfNeeded() {
        guard triggerServicesIntroFromTab else { return }
        DispatchQueue.main.async {
            triggerServicesIntroFromTab = false
        }
        // Services are on the main row now — no modal on first visit.
        if !watchNowServicesIntroComplete {
            watchNowServicesIntroComplete = true
        }
    }

    private func scheduleFirstLaunchWatchNowInfoCoachIfNeeded() {
        guard genreOnboardingComplete, !watchNowInfoCoachDismissed else { return }
        firstLaunchWatchNowCoachWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                watchNowInfoCoachManualOpen = false
                watchNowInfoCoachVisible = true
            }
        }
        firstLaunchWatchNowCoachWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    private func openWatchNowInfoCoachFromInfo() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        firstLaunchWatchNowCoachWork?.cancel()
        firstLaunchWatchNowCoachWork = nil
        watchNowInfoCoachManualOpen = true
        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
            watchNowInfoCoachVisible = true
        }
    }

    private func dismissWatchNowInfoCoach() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        withAnimation(.easeOut(duration: 0.22)) {
            watchNowInfoCoachVisible = false
            watchNowInfoCoachManualOpen = false
            watchNowInfoCoachDismissed = true
        }
        AccountLocalState.persistOnboardingFlag("watch_now_info_coach_dismissed", value: true)
    }

    private func handleSearchMovieSelected(_ movie: TMDBMovie) {
        pendingDetailFromSearch = movie
        showSearchSheet = false
    }

    private func presentPendingSearchDetailIfNeeded() {
        guard let m = pendingDetailFromSearch else { return }
        pendingDetailFromSearch = nil
        movieDetailFromSearch = m
    }

    // MARK: Header

    private func chromeIconButton(icon: String, accessibility: String, compact: Bool = false, action: @escaping () -> Void) -> some View {
        let side: CGFloat = compact ? 36 : 38
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: compact ? 15 : 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: side, height: side)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: AppTheme.chromeIconShadow, radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text("Watch Now")
                .font(AppTheme.titleLarge)
                .tracking(-0.35)
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 8) {
                chromeIconButton(icon: "magnifyingglass", accessibility: "Search movies", compact: true) {
                    showSearchSheet = true
                }
                if genreOnboardingComplete {
                    chromeIconButton(icon: "film.stack", accessibility: "Genre preferences", compact: true) {
                        showGenreSheet = true
                    }
                }
                chromeIconButton(icon: "info.circle", accessibility: "Watch Now guide", compact: true) {
                    openWatchNowInfoCoachFromInfo()
                }
            }
        }
        .padding(.horizontal, WatchNowChrome.s20)
        .padding(.top, 14)
        .padding(.bottom, WatchNowChrome.s8)
    }

    // MARK: Streaming services row

    private var streamingServicesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: WatchNowChrome.s8) {
                WatchNowStreamingServiceChip(
                    title: "All Streamers",
                    showIcon: false,
                    iconTint: Color(white: 0.45),
                    selectionFill: WatchNowChrome.accent,
                    isSelected: prefs.selectedServiceIds.isEmpty
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        prefs.clearAll()
                    }
                }
                .accessibilityLabel("All streamers, no service filter")
                ForEach(StreamingService.all) { svc in
                    WatchNowStreamingServiceChip(
                        title: svc.watchNowChipTitle,
                        systemImage: svc.logoSymbol,
                        iconTint: svc.color,
                        selectionFill: svc.color,
                        isSelected: prefs.isSelected(svc)
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            prefs.toggle(svc)
                        }
                    }
                }
            }
            .padding(.horizontal, WatchNowChrome.s20)
        }
    }

    // MARK: Genre row

    private var genreRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                GenreFilterChip(
                    label: "Any Genre",
                    color: Color(white: 0.55),
                    isSelected: vm.selectedGenreId == nil
                ) {
                    guard vm.selectedGenreId != nil else { return }
                    vm.applyGenre(nil)
                }

                ForEach(GenreCatalog.watchNowGenreChips(preferences: genrePrefsStore.genrePreferences)) { genre in
                    GenreFilterChip(
                        label: genre.displayName,
                        color: genreColor(for: genre.tmdbGenreId),
                        isSelected: vm.selectedGenreId == genre.tmdbGenreId
                    ) {
                        vm.applyGenre(vm.selectedGenreId == genre.tmdbGenreId ? nil : genre.tmdbGenreId)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func genreColor(for tmdbGenreId: Int) -> Color {
        switch tmdbGenreId {
        case 28:     return Color(red: 0.95, green: 0.32, blue: 0.32)
        case 35:     return Color(red: 0.98, green: 0.80, blue: 0.18)
        case 18:     return Color(red: 0.45, green: 0.65, blue: 0.95)
        case 53:     return Color(red: 0.75, green: 0.35, blue: 0.90)
        case 27:     return Color(red: 0.50, green: 0.68, blue: 0.90)
        case 10749:  return Color(red: 0.95, green: 0.55, blue: 0.70)
        case 878:    return Color(red: 0.18, green: 0.82, blue: 0.72)
        case 99:     return Color(red: 0.88, green: 0.56, blue: 0.26)
        case 10751:  return Color(red: 0.35, green: 0.82, blue: 0.58)
        default:     return Color(white: 0.55)
        }
    }

    // MARK: Time Row

    private var timeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: WatchNowChrome.s8) {
                ForEach(TimeSlot.allCases) { slot in
                    TimeChip(slot: slot, isSelected: vm.selectedTime == slot) {
                        vm.applyTime(vm.selectedTime == slot ? .any : slot)
                    }
                }
            }
            .padding(.horizontal, WatchNowChrome.s20)
        }
    }

    // MARK: Pick List

    private var pickList: some View {
        Group {
            if vm.isRefreshing && vm.picks.isEmpty {
                VStack(spacing: WatchNowChrome.s12) {
                    ProgressView()
                    Text("Finding picks for you…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if !vm.isRefreshing && vm.picks.isEmpty {
                VStack(spacing: WatchNowChrome.s16) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No picks yet")
                        .font(.headline.weight(.semibold))
                    Text("Check your filters or try another shuffle.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(.horizontal, WatchNowChrome.s20)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(vm.picks.enumerated()), id: \.element.id) { index, pick in
                        PickCard(pick: pick, index: index, isRefreshing: vm.isRefreshing)
                            .onTapGesture { selectedPick = pick }
                    }
                }
                .padding(.horizontal, WatchNowChrome.s20)
            }
        }
    }

    // MARK: Shuffle Button

    private var shuffleButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                vm.shufflePicks()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                Text(vm.isRefreshing ? "Finding picks…" : "Something else")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(vm.isRefreshing ? 0.35 : 0.88))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: AppTheme.chromeIconShadow.opacity(0.85), radius: 10, x: 0, y: 4)
        }
        .disabled(vm.isRefreshing)
    }
}

// MARK: - Watch Now info coach (first launch + header info — matches Discover swipe coach chrome)

private struct WatchNowInfoCoachOverlay: View {
    let onDismiss: () -> Void
    @State private var didFinish = false

    private func dismissOnce() {
        guard !didFinish else { return }
        didFinish = true
        onDismiss()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 18) {
                    Text("Three picks, fast")
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .tracking(-0.4)
                        .foregroundStyle(.primary)

                    VStack(spacing: 4) {
                        Text("Filter by streamers, genre, length")
                        Text("Pickr suggests three films to watch tonight")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(AppTheme.brand.opacity(0.95))
                            Text("Tap a poster for details; bookmark or review from the card")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 8) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.55))
                            Text("Something else swaps in fresh picks")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.55))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Need more ideas?")
                                Text("Swipe more on the Curate tab.")
                            }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 2)

                    Button(action: dismissOnce) {
                        Text("Got it")
                            .font(.system(size: 17, weight: .semibold, design: .default))
                            .tracking(-0.2)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(AppTheme.brand)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                            )
                            .shadow(color: AppTheme.brand.opacity(0.45), radius: 12, x: 0, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel("Got it")
                    .accessibilityHint("Dismisses this guide.")
                }
                .padding(26)
                .frame(maxWidth: 360)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.72))
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.42),
                                        Color.white.opacity(0.12),
                                        Color(red: 0.88, green: 0.72, blue: 0.28).opacity(0.55),
                                        Color.white.opacity(0.08),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                }
                .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 18)
                .shadow(color: AppTheme.brand.opacity(0.12), radius: 40, x: 0, y: 12)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

}

// MARK: - Watch Now filter chips (shared capsule metrics)

private enum WatchNowChipCapsuleMetrics {
    static let hPad: CGFloat = 12
    static let vPad: CGFloat = 8
    static let iconLabelSpacing: CGFloat = 6
    static let labelFont = Font.system(size: 12, weight: .semibold)
    static let iconFont = Font.system(size: 12, weight: .semibold)
    static let minLabelScale: CGFloat = 0.72
}

// MARK: - Watch Now streaming chip (top row)

private struct WatchNowStreamingServiceChip: View {
    let title: String
    var systemImage: String = ""
    var showIcon: Bool = true
    let iconTint: Color
    /// Filled capsule when selected — service brand color, or `WatchNowChrome.accent` for “All”.
    let selectionFill: Color
    let isSelected: Bool
    let onTap: () -> Void

    private var selectedForeground: Color {
        Self.foregroundOnBrandFill(selectionFill)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: showIcon ? WatchNowChipCapsuleMetrics.iconLabelSpacing : 0) {
                if showIcon {
                    Image(systemName: systemImage)
                        .font(WatchNowChipCapsuleMetrics.iconFont)
                        .foregroundStyle(isSelected ? selectedForeground : iconTint)
                }
                Text(title)
                    .font(WatchNowChipCapsuleMetrics.labelFont)
                    .foregroundStyle(isSelected ? selectedForeground : Color.primary.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(WatchNowChipCapsuleMetrics.minLabelScale)
            }
            .padding(.horizontal, WatchNowChipCapsuleMetrics.hPad)
            .padding(.vertical, WatchNowChipCapsuleMetrics.vPad)
            .background(isSelected ? selectionFill : Color(.secondarySystemFill))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.white.opacity(0.22) : WatchNowChrome.hairline,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    /// Picks light or dark label/icon on top of saturated brand fills (e.g. Peacock yellow).
    private static func foregroundOnBrandFill(_ fill: Color) -> Color {
        #if canImport(UIKit)
        let ui = UIColor(fill)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            return lum > 0.58 ? Color.black.opacity(0.9) : Color.white
        }
        #endif
        return .white
    }
}

// MARK: - Genre filter chip (Watch Now)

struct GenreFilterChip: View {
    let label:      String
    let color:      Color
    let isSelected: Bool
    let onTap:      () -> Void

    private var selectedForeground: Color {
        Self.foregroundOnSaturatedFill(color)
    }

    private var isNeutralChip: Bool {
        label == "Any Genre"
    }

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? selectedForeground : Color.primary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isSelected ? color : Color(.secondarySystemFill))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        isSelected
                            ? Color.white.opacity(0.22)
                            : (isNeutralChip ? WatchNowChrome.hairline : color.opacity(0.32)),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    /// Matches `WatchNowStreamingServiceChip` — readable label on bright fills (e.g. Comedy yellow).
    private static func foregroundOnSaturatedFill(_ fill: Color) -> Color {
        #if canImport(UIKit)
        let ui = UIColor(fill)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            return lum > 0.58 ? Color.black.opacity(0.9) : Color.white
        }
        #endif
        return .white
    }
}

// MARK: - Time Chip

struct TimeChip: View {
    let slot:       TimeSlot
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: slot.watchNowChipShowsIcon ? WatchNowChipCapsuleMetrics.iconLabelSpacing : 0) {
                if slot.watchNowChipShowsIcon {
                    Image(systemName: "clock")
                        .font(WatchNowChipCapsuleMetrics.iconFont)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.secondary)
                }
                Text(slot.watchNowChipTitle)
                    .font(WatchNowChipCapsuleMetrics.labelFont)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(WatchNowChipCapsuleMetrics.minLabelScale)
            }
            .padding(.horizontal, WatchNowChipCapsuleMetrics.hPad)
            .padding(.vertical, WatchNowChipCapsuleMetrics.vPad)
            .background(isSelected ? WatchNowChrome.accent : Color(.secondarySystemFill))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.clear : WatchNowChrome.hairline,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(slot == .any ? "Any length, no maximum runtime" : slot.rawValue)
    }
}

// MARK: - Pick Card

/// Dark “cinema” card on the otherwise light Watch Now screen (not tied to system dark mode).
private enum PickCardDarkStyle {
    static let fill = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let title = Color.white
    static let secondary = Color(white: 0.62)
    static let rank = Color(white: 0.32)
    static let stroke = Color.white.opacity(0.10)
    static let posterStroke = Color.white.opacity(0.12)
}

private enum PickCardLayout {
    static let posterWidth: CGFloat = 74
    static let posterHeight: CGFloat = 111
    /// Fixed row height — three equal tiles; sized to balance space above vs. tab bar below “Something else”.
    static let rowHeight: CGFloat = 130
    static let cardCorner: CGFloat = 15
    static let posterCorner: CGFloat = 9
    static let quickFeedbackDiameter: CGFloat = 34
    static let quickFeedbackSpacing: CGFloat = 8
}

struct PickCard: View {
    let pick:         PickItem
    let index:        Int
    let isRefreshing: Bool

    @EnvironmentObject private var engine: RecommendationEngine
    @EnvironmentObject private var watchlistStore: WatchlistStore
    @ObservedObject private var evaluationsStore = EvaluationsStore.shared
    @State private var feedback: MovieDetailFeedback = .none
    @State private var appeared = false

    private var tmdbMovie: TMDBMovie { pick.movie.asTMDBMovie() }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            posterView
                .frame(width: PickCardLayout.posterWidth, height: PickCardLayout.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: PickCardLayout.posterCorner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PickCardLayout.posterCorner, style: .continuous)
                    .stroke(PickCardDarkStyle.posterStroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(pick.movie.title)
                        .font(.system(size: 16, weight: .bold, design: .default))
                        .foregroundColor(PickCardDarkStyle.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 4)
                    Text("\(index + 1)")
                        .font(.system(size: 20, weight: .heavy, design: .default))
                        .foregroundColor(PickCardDarkStyle.rank)
                        .padding(.leading, 2)
                }
                .padding(.bottom, 5)

                HStack(spacing: 7) {
                    Label(pick.movie.runtimeFormatted, systemImage: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PickCardDarkStyle.secondary)
                        .labelStyle(.titleAndIcon)

                    Text(pick.platform)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(pick.platformColor.opacity(0.55))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 7)

                HStack(alignment: .center, spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", pick.movie.voteAverage))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(PickCardDarkStyle.title.opacity(0.92))
                    }

                    if !pick.reason.isEmpty {
                        Text(pick.reason)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PickCardDarkStyle.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    WatchNowQuickFeedbackRow(
                        movie: tmdbMovie,
                        feedback: $feedback,
                        engine: engine,
                        watchlistStore: watchlistStore,
                        buttonDiameter: PickCardLayout.quickFeedbackDiameter,
                        spacing: PickCardLayout.quickFeedbackSpacing
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
        .frame(height: PickCardLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: PickCardLayout.cardCorner, style: .continuous)
                .fill(PickCardDarkStyle.fill)
                .overlay(RoundedRectangle(cornerRadius: PickCardLayout.cardCorner, style: .continuous)
                    .stroke(PickCardDarkStyle.stroke, lineWidth: 1))
                .shadow(color: AppTheme.cardShadowColor.opacity(0.5), radius: 9, x: 0, y: 5)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(.easeOut(duration: 0.38).delay(Double(index) * 0.05)) {
                appeared = true
            }
        }
        .onChange(of: isRefreshing, initial: false) { _, refreshing in
            if refreshing {
                withAnimation(.easeIn(duration: 0.15)) { appeared = false }
            } else {
                withAnimation(.easeOut(duration: 0.38).delay(Double(index) * 0.05)) {
                    appeared = true
                }
            }
        }
        .onAppear { syncFeedback() }
        .onChange(of: evaluationsStore.mutationGeneration) { _, _ in syncFeedback() }
        .onChange(of: pick.movie.id) { _, _ in syncFeedback() }
    }

    private func syncFeedback() {
        feedback = MovieFeedbackActions.resolvedFeedback(movieId: pick.movie.id, engine: engine)
    }

    @ViewBuilder
    private var posterView: some View {
        if let url = pick.movie.posterURL {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase { img.resizable().scaledToFill() }
                else { posterFallback }
            }
        } else {
            posterFallback
        }
    }

    private var posterFallback: some View {
        Rectangle()
            .fill(Color.stablePlaceholderHue(for: pick.movie.id, saturation: 0.4, brightness: 0.32))
            .overlay(Image(systemName: "film").font(.title2).foregroundColor(.white.opacity(0.22)))
    }
}

// MARK: - TMDB search sheet (same modal pattern as `ServicesTabView`)

private enum WatchNowSearchLayout {
    static let posterW: CGFloat = 48
    static let posterH: CGFloat = 72
}

struct WatchNowMovieSearchView: View {
    var onSelectMovie: (TMDBMovie) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [TMDBMovie] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchSequence: UInt = 0
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if trimmedQuery.isEmpty {
                    // Pinned below the nav bar (not vertically centered in the full view) so the keyboard
                    // doesn’t nudge this block when `.searchable` would resize the container.
                    watchNowSearchHeroEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 32)
                } else {
                    List {
                        if isSearching && results.isEmpty {
                            Section {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Searching…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                        if let errorMessage, !errorMessage.isEmpty, results.isEmpty, !isSearching {
                            Section {
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                        }
                        Section {
                            ForEach(results) { movie in
                                Button {
                                    onSelectMovie(movie)
                                } label: {
                                    watchNowSearchResultRow(movie)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if !isSearching && results.isEmpty && !trimmedQuery.isEmpty && errorMessage == nil {
                            Section {
                                Text("No results. Try a different spelling or shorter phrase.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Custom field keeps inline title + Done visible; `.searchable` collapses the nav when focused.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                watchNowSearchBottomBar
            }
        }
        .onChange(of: query) { _, newValue in
            scheduleDebouncedSearch(newValue)
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    /// Fixed composition (no `ContentUnavailableView`) so size/placement stay stable when the keyboard appears.
    private var watchNowSearchHeroEmptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 10) {
                Text("Search for any title")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("Select a movie to add to your watchlist")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Like or dislike to improve picks")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var watchNowSearchBottomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Movie title", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleDebouncedSearch(_ raw: String) {
        debounceTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }
        searchSequence += 1
        let token = searchSequence
        isSearching = true
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(query: q, sequence: token)
        }
    }

    @MainActor
    private func runSearch(query q: String, sequence token: UInt) async {
        errorMessage = nil
        do {
            let page = try await TMDBService.shared.searchMovies(query: q, page: 1)
            guard token == searchSequence else { return }
            results = page.results
        } catch {
            guard token == searchSequence else { return }
            results = []
            errorMessage = error.localizedDescription
        }
        guard token == searchSequence else { return }
        isSearching = false
    }

    @ViewBuilder
    private func watchNowSearchResultRow(_ movie: TMDBMovie) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = movie.posterURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        searchPosterPlaceholder(movie)
                    default:
                        searchPosterPlaceholder(movie)
                    }
                }
                .frame(width: WatchNowSearchLayout.posterW, height: WatchNowSearchLayout.posterH)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                searchPosterPlaceholder(movie)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(movie.year)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if !movie.overview.isEmpty {
                    Text(movie.overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
    }

    private func searchPosterPlaceholder(_ movie: TMDBMovie) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.stablePlaceholderHue(for: movie.id, saturation: 0.4, brightness: 0.32))
            .frame(width: WatchNowSearchLayout.posterW, height: WatchNowSearchLayout.posterH)
            .overlay {
                Image(systemName: "film")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.28))
            }
    }
}

// MARK: - Bridge to MovieDetailView

struct WatchNowDetailBridge: View {
    let pick:   PickItem
    let engine: RecommendationEngine

    var body: some View {
        MovieDetailView(movie: bridgeMovie, engine: engine)
    }

    private var bridgeMovie: TMDBMovie {
        let year = pick.movie.year
        let releaseDate = (year.isEmpty || year == "—") ? nil : "\(year)-01-01"
        return TMDBMovie(id: pick.movie.id, title: pick.movie.title,
                         overview: "",
                         releaseDate: releaseDate,
                         posterPath: pick.movie.posterPath, backdropPath: nil,
                         voteAverage: pick.movie.voteAverage, voteCount: 0,
                         genreIds: pick.movie.genreIds, popularity: 50.0)
    }
}

// MARK: - Preview

#Preview {
    WatchNowView(vm: WatchNowViewModel(engine: RecommendationEngine(), prefs: StreamingPreferences()))
        .environmentObject(RecommendationEngine())
        .environmentObject(StreamingPreferences())
        .environmentObject(WatchlistStore.shared)
}

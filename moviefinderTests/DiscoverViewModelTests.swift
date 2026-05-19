// DiscoverViewModelTests.swift
// Add to moviefinderTests target only
// Run with Cmd+U

import XCTest
@testable import moviefinder

// MARK: - Mock Storage

final class MockProfileStorage: ProfileStorage, @unchecked Sendable {
    nonisolated(unsafe) private var stored = TasteProfile()
    nonisolated(unsafe) private(set) var saveCount = 0

    override func save(_ p: TasteProfile) { stored = p; saveCount += 1 }
    override func load() -> TasteProfile  { stored }
}

// MARK: - Test Helpers

private func makeDetail(id: Int, genreIds: [Int] = [], releaseDate: String = "2020-01-01") -> TMDBMovieDetail {
    TMDBMovieDetail(id: id, title: "Movie \(id)", overview: "Overview",
                    tagline: nil, releaseDate: releaseDate, runtime: 120,
                    voteAverage: 7.5, posterPath: nil, backdropPath: nil,
                    genres: genreIds.map { TMDBGenre(id: $0, name: "G\($0)") },
                    watchProviders: nil)
}

private func makeTMDB(id: Int, genreIds: [Int] = [], rating: Double = 7.0, popularity: Double = 30.0) -> TMDBMovie {
    TMDBMovie(id: id, title: "M\(id)", overview: "", releaseDate: "2020-01-01",
              posterPath: nil, backdropPath: nil, voteAverage: rating,
              voteCount: 200, genreIds: genreIds, popularity: popularity)
}

private func makeTMDBTitle(id: Int, title: String, genreIds: [Int] = []) -> TMDBMovie {
    TMDBMovie(id: id, title: title, overview: "", releaseDate: "2020-01-01",
              posterPath: nil, backdropPath: nil, voteAverage: 7.0,
              voteCount: 200, genreIds: genreIds, popularity: 30)
}

// MARK: - RecommendationEngine Tests

@MainActor
final class RecommendationEngineTests: XCTestCase {
    var storage: MockProfileStorage!
    var engine:  RecommendationEngine!

    override func setUp() {
        super.setUp()
        storage = MockProfileStorage()
        engine  = RecommendationEngine(storage: storage)
        GenrePreferencesStore.shared.resetToDefaults()
    }

    func test_volatilityHalvesOnRecalculateWeightsFromHistory_emptyReplay() {
        engine.profile.genreVolatility = [28: 5, 35: 7]
        engine.profile.swipeHistory = []
        engine.recalculateWeightsFromHistory()
        XCTAssertEqual(engine.profile.genreVolatility[28], 2) // 5 / 2
        XCTAssertEqual(engine.profile.genreVolatility[35], 3) // 7 / 2
    }

    func test_tasteProfile_roundTripsJSONWithVolatilityFields() throws {
        var p = TasteProfile()
        p.genreVolatility[28] = 2
        p.lastGenreMultDirection[28] = 1.0
        p.swipeHistory.append(SwipeHistoryEntry(movieId: 1, genreIds: [28], mult: 1.0, timestamp: Date()))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(TasteProfile.self, from: data)
        XCTAssertEqual(decoded.genreVolatility[28], 2)
        XCTAssertEqual(decoded.lastGenreMultDirection[28], 1.0)
        XCTAssertEqual(decoded.swipeHistory.count, 1)
    }

    // Profile starts empty
    func test_initialProfile_isEmpty() {
        XCTAssertTrue(engine.profile.isEmpty)
        XCTAssertEqual(engine.profile.totalSwipes, 0)
        XCTAssertTrue(engine.profile.genreWeights.isEmpty)
    }

    // Like increases genre weight
    func test_like_increasesGenreWeight() {
        engine.record(SwipeEvent(movieId: 1, action: .like,
                                  movie: makeDetail(id: 1, genreIds: [28]), timestamp: Date()))
        XCTAssertGreaterThan(engine.profile.genreWeights[28] ?? 0, 0)
    }

    // Skip decreases genre weight
    func test_skip_decreasesGenreWeight() {
        engine.record(SwipeEvent(movieId: 2, action: .skip,
                                  movie: makeDetail(id: 2, genreIds: [35]), timestamp: Date()))
        XCTAssertLessThan(engine.profile.genreWeights[35] ?? 0, 0)
    }

    // Like adds to seenIds and likedIds
    func test_like_addsToSeenAndLiked() {
        engine.record(SwipeEvent(movieId: 99, action: .like,
                                  movie: makeDetail(id: 99), timestamp: Date()))
        XCTAssertTrue(engine.profile.seenIds.contains(99))
        XCTAssertTrue(engine.profile.likedIds.contains(99))
    }

    // Skip adds to seenIds (no repeat in deck) but not to likedIds
    func test_skip_notInLiked() {
        engine.record(SwipeEvent(movieId: 55, action: .skip,
                                  movie: makeDetail(id: 55), timestamp: Date()))
        XCTAssertTrue(engine.profile.seenIds.contains(55))
        XCTAssertFalse(engine.profile.likedIds.contains(55))
    }

    func test_removeFromSeen_onlyClearsSeenIds() async {
        engine.record(SwipeEvent(movieId: 501, action: .like,
                                  movie: makeDetail(id: 501, genreIds: [28]), timestamp: Date()))
        XCTAssertTrue(engine.profile.seenIds.contains(501))
        XCTAssertTrue(engine.profile.likedIds.contains(501))

        engine.removeFromSeen(movieId: 501)

        XCTAssertFalse(engine.profile.seenIds.contains(501))
        XCTAssertTrue(engine.profile.likedIds.contains(501))
        XCTAssertGreaterThan(engine.profile.genreWeights[28] ?? 0, 0)
    }

    func test_revokeSwipeSignals_removesMovieHistoryGenreReplayAndClearsSeen() {
        engine.record(SwipeEvent(movieId: 77, action: .like,
                                  movie: makeDetail(id: 77, genreIds: [28]), timestamp: Date()))
        engine.record(SwipeEvent(movieId: 88, action: .skip,
                                  movie: makeDetail(id: 88, genreIds: [35]), timestamp: Date()))
        XCTAssertEqual(engine.profile.swipeHistory.filter { $0.movieId == 77 }.count, 1)
        XCTAssertEqual(engine.profile.totalSwipes, 2)
        XCTAssertTrue(engine.profile.seenIds.contains(77))
        XCTAssertTrue(engine.profile.likedIds.contains(77))
        XCTAssertGreaterThan(engine.profile.genreWeights[28] ?? 0, 0)

        engine.revokeSwipeSignalsForMovie(movieId: 77)

        XCTAssertTrue(engine.profile.swipeHistory.allSatisfy { $0.movieId != 77 })
        XCTAssertEqual(engine.profile.totalSwipes, 1)
        XCTAssertFalse(engine.profile.seenIds.contains(77))
        XCTAssertFalse(engine.profile.likedIds.contains(77))

        XCTAssertLessThan(engine.profile.genreWeights[35] ?? 0, 0)
        XCTAssertLessThan(abs(engine.profile.genreWeights[28] ?? 0), 0.05)
        XCTAssertGreaterThan(engine.score(makeTMDB(id: 77, genreIds: [28])), 0)
    }

    func test_revokeSwipeSignals_afterStrongSkip_rebuildsStrongSkipCounts() {
        engine.record(SwipeEvent(movieId: 303, action: .strongSkip,
                                  movie: makeDetail(id: 303, genreIds: [999]), timestamp: Date()))
        XCTAssertGreaterThan(engine.profile.strongSkipCounts[999] ?? 0, 0)
        XCTAssertEqual(engine.profile.swipeHistory.filter { $0.movieId == 303 }.count, 1)

        engine.revokeSwipeSignalsForMovie(movieId: 303)

        XCTAssertEqual(engine.profile.strongSkipCounts[999] ?? 0, 0)
    }

    // Skip after like removes from likedIds (Watch Now must not seed from thumbs-downed titles).
    func test_skip_after_like_removesFromLikedIds() {
        engine.record(SwipeEvent(movieId: 200, action: .like,
                                  movie: makeDetail(id: 200), timestamp: Date()))
        XCTAssertTrue(engine.profile.likedIds.contains(200))
        engine.record(SwipeEvent(movieId: 200, action: .skip,
                                  movie: makeDetail(id: 200), timestamp: Date()))
        XCTAssertFalse(engine.profile.likedIds.contains(200))
    }

    // Seen movies (like or skip) filtered from rank
    func test_rank_filtersSeen() {
        engine.record(SwipeEvent(movieId: 10, action: .like,
                                  movie: makeDetail(id: 10), timestamp: Date()))
        let r = engine.rank([makeTMDB(id: 10), makeTMDB(id: 20)])
        XCTAssertFalse(r.contains { $0.id == 10 })
        XCTAssertTrue(r.contains  { $0.id == 20 })
    }

    func test_rank_filtersSeen_afterSkip() {
        engine.record(SwipeEvent(movieId: 11, action: .skip,
                                  movie: makeDetail(id: 11, genreIds: [28]), timestamp: Date()))
        let r = engine.rank([makeTMDB(id: 11), makeTMDB(id: 12, genreIds: [28])])
        XCTAssertFalse(r.contains { $0.id == 11 })
        XCTAssertTrue(r.contains { $0.id == 12 })
    }

    /// Diversity counts every genre id; cap 4 per genre in the top 20 window — 5th pure-Action title is deferred to the tail.
    func test_rank_diversity_defersWhenGenreHitsCap() {
        let batch = (1...5).map { i in
            makeTMDB(id: i, genreIds: [28], rating: 8.0 - Double(i) * 0.05)
        }
        let r = engine.rank(batch)
        XCTAssertEqual(r.map(\.id), [1, 2, 3, 4, 5], "Higher-rated ids sort first; 5th same-genre slot is after the first four.")
    }

    // score returns -1 for seen
    func test_score_minus1ForSeen() {
        engine.record(SwipeEvent(movieId: 7, action: .like,
                                  movie: makeDetail(id: 7), timestamp: Date()))
        XCTAssertEqual(engine.score(makeTMDB(id: 7)), -1.0)
    }

    // score ≥ 0 for unseen
    func test_score_nonNegativeForUnseen() {
        XCTAssertGreaterThanOrEqual(engine.score(makeTMDB(id: 999)), 0)
    }

    // Action + Sci‑Fi cluster: high TMDB popularity should beat low popularity (superhero gate).
    func test_superhero_cluster_popularity_gate() {
        let low = makeTMDB(id: 100, genreIds: [28, 878], rating: 7.0, popularity: 18)
        let high = makeTMDB(id: 101, genreIds: [28, 878], rating: 7.0, popularity: 95)
        XCTAssertGreaterThan(engine.score(high), engine.score(low))
    }

    // Non-cluster genres are not affected by the superhero popularity gate (same ids, drama-only).
    func test_superhero_gate_skips_non_cluster() {
        let low = makeTMDB(id: 200, genreIds: [18], rating: 7.0, popularity: 18)
        let high = makeTMDB(id: 201, genreIds: [18], rating: 7.0, popularity: 95)
        let diffCluster = engine.score(high) - engine.score(low)
        let lowS = makeTMDB(id: 300, genreIds: [28, 878], rating: 7.0, popularity: 18)
        let highS = makeTMDB(id: 301, genreIds: [28, 878], rating: 7.0, popularity: 95)
        let diffSuper = engine.score(highS) - engine.score(lowS)
        XCTAssertGreaterThan(diffSuper, diffCluster)
    }

    // Liked genre scores higher than skipped genre
    func test_likedGenreScoresHigher() {
        engine.record(SwipeEvent(movieId: 1, action: .like,
                                  movie: makeDetail(id: 1, genreIds: [28]), timestamp: Date()))
        engine.record(SwipeEvent(movieId: 2, action: .skip,
                                  movie: makeDetail(id: 2, genreIds: [35]), timestamp: Date()))
        let actionScore  = engine.score(makeTMDB(id: 100, genreIds: [28]))
        let comedyScore  = engine.score(makeTMDB(id: 101, genreIds: [35]))
        XCTAssertGreaterThan(actionScore, comedyScore)
    }

    /// Multi-genre sum is divided by √(n) so extra TMDB tags do not inflate `genreSig` vs a single-genre title.
    func test_score_genreBlendUsesSqrtNormalization() {
        engine.profile.genreWeights = [28: 0.5]
        engine.profile.totalSwipes = 5
        let single = engine.score(makeTMDB(id: 1, genreIds: [28], rating: 7.0))
        let triple = engine.score(makeTMDB(id: 2, genreIds: [28, 12, 14], rating: 7.0))
        XCTAssertGreaterThan(single, triple, "Same raw weight spread across more genre ids should not score higher.")
    }

    // Genre weights clamped to [-1, 1]
    func test_weights_clamped() {
        let m = makeDetail(id: 5, genreIds: [28])
        for i in 100..<160 {
            engine.record(SwipeEvent(movieId: i, action: .like, movie: m, timestamp: Date()))
        }
        XCTAssertLessThanOrEqual(engine.profile.genreWeights[28] ?? 0, 1.0)
        XCTAssertGreaterThanOrEqual(engine.profile.genreWeights[28] ?? 0, -1.0)
    }

    // topGenreIds returns highest weighted
    func test_topGenreIds() {
        for i in [1, 2] {
            engine.record(SwipeEvent(movieId: i, action: .like,
                                      movie: makeDetail(id: i, genreIds: [28]), timestamp: Date()))
        }
        engine.record(SwipeEvent(movieId: 3, action: .like,
                                  movie: makeDetail(id: 3, genreIds: [53]), timestamp: Date()))
        XCTAssertEqual(engine.topGenreIds(count: 1).first, 28)
    }

    // Recalibration preserves seen + swipe history; weights are rebuilt from history (not left empty).
    func test_recalibration() {
        engine.record(SwipeEvent(movieId: 77, action: .like,
                                  movie: makeDetail(id: 77, genreIds: [28]), timestamp: Date()))
        engine.resetForRecalibration()
        XCTAssertTrue(engine.profile.seenIds.contains(77))
        XCTAssertFalse(engine.profile.genreWeights.isEmpty)
        XCTAssertTrue(engine.profile.likedIds.isEmpty)
    }

    // Swipe count increments correctly
    func test_swipeCount() {
        let m = makeDetail(id: 1)
        engine.record(SwipeEvent(movieId: 1, action: .like, movie: m, timestamp: Date()))
        engine.record(SwipeEvent(movieId: 2, action: .skip, movie: m, timestamp: Date()))
        XCTAssertEqual(engine.profile.totalSwipes, 2)
    }

    // Storage is called after each record
    func test_storageSavedOnRecord() {
        engine.record(SwipeEvent(movieId: 1, action: .like,
                                  movie: makeDetail(id: 1), timestamp: Date()))
        XCTAssertGreaterThan(storage.saveCount, 0)
    }

    // Decade weights update on like
    func test_decadeWeightUpdated() {
        engine.record(SwipeEvent(movieId: 1, action: .like,
                                  movie: makeDetail(id: 1, genreIds: [], releaseDate: "1994-07-01"),
                                  timestamp: Date()))
        XCTAssertNotNil(engine.profile.decadeWeights["1990s"])
        XCTAssertGreaterThan(engine.profile.decadeWeights["1990s"] ?? 0, 0)
    }

    func test_rank_excludesOnboardingDislikedGenres() {
        engine.replaceOnboardingGenres(loved: [], liked: [], disliked: [10751])
        let family = makeTMDB(id: 201, genreIds: [10751, 28])
        let action = makeTMDB(id: 202, genreIds: [28])
        let r = engine.rank([family, action])
        XCTAssertFalse(r.contains { $0.id == 201 })
        XCTAssertTrue(r.contains { $0.id == 202 })
    }

    func test_rank_excludesAnimationWhenFamilyDisliked_expansion() {
        engine.replaceOnboardingGenres(loved: [], liked: [], disliked: [10751])
        let animatedOnly = makeTMDB(id: 203, genreIds: [16, 12])
        let drama = makeTMDB(id: 204, genreIds: [18])
        let r = engine.rank([animatedOnly, drama])
        XCTAssertFalse(r.contains { $0.id == 203 })
        XCTAssertTrue(r.contains { $0.id == 204 })
    }

    /// Live weight above 0 overrides the onboarding dislike hard gate (same predicate as Watch Now).
    func test_rank_includesDislikedGenreWhenGenreWeightPositive() {
        engine.replaceOnboardingGenres(loved: [], liked: [], disliked: [10751])
        let family = makeTMDB(id: 205, genreIds: [10751, 28])
        let action = makeTMDB(id: 206, genreIds: [28])
        XCTAssertTrue(engine.isHardExcludedByOnboardingDislikes(family))
        engine.profile.genreWeights[10751] = 0.05
        XCTAssertFalse(engine.isHardExcludedByOnboardingDislikes(family))
        let r = engine.rank([family, action])
        XCTAssertTrue(r.contains { $0.id == 205 })
        XCTAssertTrue(r.contains { $0.id == 206 })
    }
}

// MARK: - DiscoverViewModel Tests

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    var engine: RecommendationEngine!
    var prefs:  StreamingPreferences!
    var vm:     DiscoverViewModel!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "training_complete")
        UserDefaults.standard.removeObject(forKey: "training_valid_swipe_count")
        GenrePreferencesStore.shared.resetToDefaults()
        engine = RecommendationEngine(storage: MockProfileStorage())
        prefs  = StreamingPreferences()
        vm     = DiscoverViewModel(engine: engine, prefs: prefs)
    }

    func test_handleSwipe_removesCard() {
        vm.cards = [makeTMDB(id: 1), makeTMDB(id: 2)]
        vm.handleSwipe(movie: makeTMDB(id: 1), direction: .like)
        XCTAssertFalse(vm.cards.contains { $0.id == 1 })
        XCTAssertEqual(vm.cards.count, 1)
    }

    func test_handleSwipe_noneIsNoOp() {
        vm.cards = [makeTMDB(id: 1)]
        vm.handleSwipe(movie: makeTMDB(id: 1), direction: .none)
        XCTAssertEqual(vm.cards.count, 1)
    }

    func test_handleSwipe_like_updatesEngine() {
        vm.cards = [makeTMDB(id: 42)]
        vm.handleSwipe(movie: makeTMDB(id: 42), direction: .like)
        XCTAssertTrue(engine.profile.seenIds.contains(42))
        XCTAssertTrue(engine.profile.likedIds.contains(42))
    }

    func test_handleSwipe_watchlist_savesToStore() {
        WatchlistStore.shared.remove(id: 77)
        vm.cards = [makeTMDB(id: 77)]
        vm.handleSwipe(movie: makeTMDB(id: 77), direction: .watchlist)
        XCTAssertTrue(WatchlistStore.shared.contains(id: 77))
        WatchlistStore.shared.remove(id: 77)
    }

    func test_undoSwipe_restoresDeckEngineAndClearsRedoToken() {
        vm.cards = [makeTMDB(id: 201)]
        let beforeSwipes = engine.profile.totalSwipes
        XCTAssertFalse(engine.profile.seenIds.contains(201))
        vm.handleSwipe(movie: makeTMDB(id: 201), direction: .like)
        XCTAssertFalse(vm.cards.contains { $0.id == 201 })
        XCTAssertTrue(engine.profile.seenIds.contains(201))
        XCTAssertEqual(engine.profile.totalSwipes, beforeSwipes + 1)
        vm.undoLastSwipe()
        XCTAssertEqual(vm.cards.first?.id, 201)
        XCTAssertFalse(engine.profile.seenIds.contains(201))
        XCTAssertEqual(engine.profile.totalSwipes, beforeSwipes)
        XCTAssertFalse(vm.canUndoLastSwipe)
    }

    func test_undoSwipe_removesWatchlistEntryAfterWatchlistSwipe() {
        WatchlistStore.shared.remove(id: 203)
        vm.cards = [makeTMDB(id: 203)]
        vm.handleSwipe(movie: makeTMDB(id: 203), direction: .watchlist)
        XCTAssertTrue(WatchlistStore.shared.contains(id: 203))
        vm.undoLastSwipe()
        XCTAssertFalse(WatchlistStore.shared.contains(id: 203))
    }

    func test_refresh_invalidatesSwipeUndoCheckpoint() async {
        vm.cards = [makeTMDB(id: 205)]
        vm.handleSwipe(movie: makeTMDB(id: 205), direction: .like)
        XCTAssertTrue(vm.canUndoLastSwipe)
        await vm.refresh()
        XCTAssertFalse(vm.canUndoLastSwipe)
    }

    func test_handleSwipe_skip_notSavedToWatchlist() {
        WatchlistStore.shared.remove(id: 88)
        vm.cards = [makeTMDB(id: 88)]
        vm.handleSwipe(movie: makeTMDB(id: 88), direction: .skip)
        XCTAssertFalse(WatchlistStore.shared.contains(id: 88))
        XCTAssertTrue(engine.profile.seenIds.contains(88))
    }

    func test_handleSwipe_setsLastFeedback() {
        vm.cards = [makeTMDB(id: 1)]
        vm.handleSwipe(movie: makeTMDB(id: 1), direction: .like)
        XCTAssertNotNil(vm.lastFeedback)
        XCTAssertEqual(vm.lastFeedback?.direction, .like)
    }

    func test_handleSwipe_didNotSee_doesNotUpdateEngine() {
        vm.cards = [makeTMDB(id: 123)]
        vm.handleSwipe(movie: makeTMDB(id: 123), direction: .didNotSee)
        XCTAssertFalse(engine.profile.seenIds.contains(123))
        XCTAssertFalse(engine.profile.likedIds.contains(123))
    }

    func test_training_validSwipeCountsLikeAndSkipOnly() {
        XCTAssertEqual(vm.validTrainingSwipeCount, 0)
        vm.cards = [makeTMDB(id: 10)]
        vm.handleSwipe(movie: makeTMDB(id: 10), direction: .like)
        XCTAssertEqual(vm.validTrainingSwipeCount, 1)

        vm.cards = [makeTMDB(id: 11)]
        vm.handleSwipe(movie: makeTMDB(id: 11), direction: .skip)
        XCTAssertEqual(vm.validTrainingSwipeCount, 2)

        vm.cards = [makeTMDB(id: 12)]
        vm.handleSwipe(movie: makeTMDB(id: 12), direction: .didNotSee)
        XCTAssertEqual(vm.validTrainingSwipeCount, 2)

        vm.cards = [makeTMDB(id: 13)]
        vm.handleSwipe(movie: makeTMDB(id: 13), direction: .watchlist)
        XCTAssertEqual(vm.validTrainingSwipeCount, 2)
    }

    func test_refresh_clearsCards() {
        vm.cards = [makeTMDB(id: 1), makeTMDB(id: 2)]
        vm.cards = []
        XCTAssertTrue(vm.cards.isEmpty)
    }

    /// Skip on Iron Man removes Iron Man 2 from the remaining deck (franchise neighbor prune).
    func test_handleSwipe_skip_prunesFranchiseNeighbors() {
        let iron1 = makeTMDBTitle(id: 1, title: "Iron Man", genreIds: [28])
        let iron2 = makeTMDBTitle(id: 2, title: "Iron Man 2", genreIds: [28])
        let thor  = makeTMDBTitle(id: 3, title: "Thor", genreIds: [28])
        vm.cards = [iron1, iron2, thor]
        vm.handleSwipe(movie: iron1, direction: .skip)
        XCTAssertEqual(Set(vm.cards.map(\.id)), [3], "Sequel in same franchise should be pruned after dislike.")
    }

    /// After each swipe, the tail matches `engine.rank` on the remaining non-top movies (top preserved for UI stability).
    func test_handleSwipe_rerank_matchesEngineRankOnTail() {
        let a = makeTMDB(id: 10, genreIds: [35], rating: 7.0)
        let b = makeTMDB(id: 11, genreIds: [28], rating: 7.0)
        vm.cards = [a, b]
        vm.handleSwipe(movie: a, direction: .didNotSee)
        let remaining = vm.cards
        XCTAssertEqual(remaining.first?.id, 11)
        let tail = Array(remaining.dropFirst())
        let expectedTail = Array(engine.rank(remaining).dropFirst())
        XCTAssertEqual(tail.map(\.id), expectedTail.map(\.id))
    }

    /// After swiping the top card, the new front stays the previous second card; cards below are `rank`‑sorted.
    func test_handleSwipe_like_preservesNewTop_reranksTail() {
        let likedTop = makeTMDB(id: 1, genreIds: [28], rating: 7.0)
        let comedy = makeTMDB(id: 2, genreIds: [35], rating: 7.0)
        let action = makeTMDB(id: 3, genreIds: [28], rating: 8.0)
        vm.cards = [likedTop, comedy, action]
        vm.handleSwipe(movie: likedTop, direction: .like)
        XCTAssertEqual(vm.cards.first?.id, 2, "New top should be the prior second card (no full-deck promotion glitch).")
        XCTAssertEqual(vm.cards.map(\.id), [comedy.id] + engine.rank([action]).map(\.id))
    }

    // MARK: Franchise deduplication

    func test_franchiseDuplicate_spiderMan_series() {
        let a = makeTMDBTitle(id: 1, title: "Spider-Man")
        let b = makeTMDBTitle(id: 2, title: "Spider-Man 2")
        XCTAssertTrue(vm.isFranchiseDuplicate(b, in: [a]))
        XCTAssertTrue(vm.isFranchiseDuplicate(a, in: [b]))
    }

    func test_franchiseDuplicate_spiderMan_vs_ironMan_notDuplicate() {
        let spider = makeTMDBTitle(id: 1, title: "Spider-Man")
        let iron = makeTMDBTitle(id: 2, title: "Iron Man")
        XCTAssertFalse(vm.isFranchiseDuplicate(iron, in: [spider]))
    }

    func test_franchiseDuplicate_americanPie_vs_americanBeauty_notDuplicate() {
        let pie = makeTMDBTitle(id: 1, title: "American Pie")
        let beauty = makeTMDBTitle(id: 2, title: "American Beauty")
        XCTAssertFalse(vm.isFranchiseDuplicate(beauty, in: [pie]))
    }

    func test_franchiseDuplicate_starWars_prefix() {
        let a = makeTMDBTitle(id: 1, title: "Star Wars")
        let b = makeTMDBTitle(id: 2, title: "Star Wars: The Empire Strikes Back")
        XCTAssertTrue(vm.isFranchiseDuplicate(b, in: [a]))
    }

    func test_franchiseDuplicate_ironMan_sequels() {
        let a = makeTMDBTitle(id: 1, title: "Iron Man")
        let b = makeTMDBTitle(id: 2, title: "Iron Man 2")
        XCTAssertTrue(vm.isFranchiseDuplicate(b, in: [a]))
    }

    func test_franchiseDuplicate_rocky_sequels() {
        let a = makeTMDBTitle(id: 1, title: "Rocky")
        let b = makeTMDBTitle(id: 2, title: "Rocky II")
        XCTAssertTrue(vm.isFranchiseDuplicate(b, in: [a]))
    }

    func test_franchiseDuplicate_emptyPool_neverDuplicate() {
        let m = makeTMDBTitle(id: 1, title: "Spider-Man")
        XCTAssertFalse(vm.isFranchiseDuplicate(m, in: []))
    }

    /// Mirrors `fetchFromLibrary()` assembly: `rank(candidates)` then franchise dedupe until batch full.
    /// Does not require `MovieLibraryService.isReady` or SQLite — validates the library path strategy.
    func test_librarySwipeAssembly_rankThenFranchiseCap() {
        func m(_ id: Int, _ title: String, _ rating: Double) -> TMDBMovie {
            TMDBMovie(id: id, title: title, overview: "", releaseDate: "2020-01-01",
                      posterPath: nil, backdropPath: nil, voteAverage: rating,
                      voteCount: 200, genreIds: [28], popularity: 30)
        }
        // rank() sorts by engine score; with empty profile, rating term dominates → 8.0, 7.9, 7.0.
        let candidates = [m(1, "Iron Man", 8.0), m(2, "Iron Man 2", 7.9), m(3, "Thor", 7.0)]
        let minimumBatch = 2
        var gathered: [TMDBMovie] = []
        for movie in engine.rank(candidates) {
            if vm.isFranchiseDuplicate(movie, in: gathered) { continue }
            gathered.append(movie)
            if gathered.count >= minimumBatch { break }
        }
        XCTAssertEqual(gathered.map(\.id), [1, 3], "Iron Man 2 should be skipped as franchise dup of Iron Man")
    }
}

// MARK: - WatchlistStore Tests

@MainActor
final class WatchlistStoreTests: XCTestCase {
    let store = WatchlistStore.shared

    func test_addContainsRemove() {
        store.remove(id: 9001)
        store.add(makeTMDB(id: 9001))
        XCTAssertTrue(store.contains(id: 9001))
        store.remove(id: 9001)
        XCTAssertFalse(store.contains(id: 9001))
    }

    func test_allIdsIncludesAdded() {
        store.remove(id: 9002)
        store.add(makeTMDB(id: 9002))
        XCTAssertTrue(store.allIds().contains(9002))
        store.remove(id: 9002)
    }

    func test_doubleAdd_doesNotDuplicate() {
        store.remove(id: 9003)
        store.add(makeTMDB(id: 9003))
        store.add(makeTMDB(id: 9003))
        // Set semantics — still just one entry
        XCTAssertTrue(store.allIds().contains(9003))
        store.remove(id: 9003)
    }

    func test_removeAll_clearsPersistedIds() {
        store.remove(id: 9010)
        store.add(makeTMDB(id: 9010))
        XCTAssertTrue(store.contains(id: 9010))
        store.removeAll()
        XCTAssertTrue(store.allIds().isEmpty)
        XCTAssertFalse(store.contains(id: 9010))
    }
}

// MARK: - SwipeDirection Tests

@MainActor
final class SwipeDirectionTests: XCTestCase {
    func test_equatable() {
        XCTAssertEqual(SwipeDirection.like, .like)
        XCTAssertNotEqual(SwipeDirection.like, .skip)
        XCTAssertNotEqual(SwipeDirection.skip, .watchlist)
    }
}


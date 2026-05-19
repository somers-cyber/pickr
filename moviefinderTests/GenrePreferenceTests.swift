import XCTest
@testable import moviefinder

final class GenrePreferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GenrePreferencesStore.shared.resetToDefaults()
    }

    func testPreferenceLevel_cyclesNeutralLikeDislike() {
        var p = PreferenceLevel.neutral
        p.advance()
        XCTAssertEqual(p, .like)
        p.advance()
        XCTAssertEqual(p, .dislike)
        p.advance()
        XCTAssertEqual(p, .neutral)
    }

    /// Mock: user strongly dislikes horror — horror title scores lower than a liked comedy.
    func testWeightScore_strongDislikeHorror_vs_likedComedy() {
        var prefs = GenreCatalog.defaultPreferences()
        prefs["Horror"] = .dislike
        prefs["Comedy"] = .like

        let horror = makeTMDB(id: 1, genreIds: [27])
        let comedy = makeTMDB(id: 2, genreIds: [35])

        let h = GenrePreferenceRanking.weightScore(for: horror, prefs: prefs)
        let c = GenrePreferenceRanking.weightScore(for: comedy, prefs: prefs)
        XCTAssertGreaterThan(c, h)
    }

    /// Mock: mixed likes — higher score when more liked genres match.
    func testWeightScore_mixedPreferences() {
        var prefs = GenreCatalog.defaultPreferences()
        prefs["Action"] = .like
        prefs["Drama"] = .neutral
        prefs["Sci-Fi"] = .dislike

        let actionOnly = makeTMDB(id: 10, genreIds: [28])
        let actionAndScifi = makeTMDB(id: 11, genreIds: [28, 878])

        let a = GenrePreferenceRanking.weightScore(for: actionOnly, prefs: prefs)
        let b = GenrePreferenceRanking.weightScore(for: actionAndScifi, prefs: prefs)
        XCTAssertGreaterThan(a, b)
    }

    /// Mock: all neutral — scores are equal for same structure.
    func testWeightScore_allNeutral_similarTitles() {
        let prefs = GenreCatalog.defaultPreferences()
        let m1 = makeTMDB(id: 20, genreIds: [28, 35])
        let m2 = makeTMDB(id: 21, genreIds: [18, 53])
        let s1 = GenrePreferenceRanking.weightScore(for: m1, prefs: prefs)
        let s2 = GenrePreferenceRanking.weightScore(for: m2, prefs: prefs)
        XCTAssertEqual(s1, s2, accuracy: 0.001)
    }

    func testHasDislikedGenre() {
        var prefs = GenreCatalog.defaultPreferences()
        prefs["Horror"] = .dislike
        let disliked = GenreCatalog.dislikedIdSet(from: prefs)
        let horror = makeTMDB(id: 1, genreIds: [27])
        XCTAssertTrue(GenrePreferenceRanking.hasDislikedGenre(horror, disliked: disliked))
    }

    func testExpandedDisliked_includesAnimationWhenFamilyDisliked() {
        let s = GenreCatalog.expandedDislikedGenreIdsForFiltering([10751])
        XCTAssertTrue(s.contains(10751))
        XCTAssertTrue(s.contains(16))
    }

    func testExpandedDisliked_doesNotAddAnimationWithoutFamily() {
        let s = GenreCatalog.expandedDislikedGenreIdsForFiltering([27])
        XCTAssertTrue(s.contains(27))
        XCTAssertFalse(s.contains(16))
    }

    func testDiscoverGenreSeeds_prefersLikedOverNeutral() {
        GenrePreferencesStore.shared.resetToDefaults()
        GenrePreferencesStore.shared.set("Comedy", level: .like)
        GenrePreferencesStore.shared.set("Drama", level: .neutral)
        let seeds = GenrePreferencesStore.shared.discoverGenreSeeds(count: 2)
        XCTAssertTrue(seeds.contains(35))
    }
}

private func makeTMDB(id: Int, genreIds: [Int]) -> TMDBMovie {
    TMDBMovie(id: id, title: "M\(id)", overview: "", releaseDate: "2020-01-01",
              posterPath: nil, backdropPath: nil, voteAverage: 7.0,
              voteCount: 200, genreIds: genreIds, popularity: 30.0)
}

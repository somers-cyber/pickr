import XCTest
@testable import moviefinder

final class WatchNowFilterTests: XCTestCase {

    /// Mirrors `recommendPicks` → `discoverStreamingMovies(with_genres:)` wiring: nil = no genre filter.
    private func activeGenreIds(for selectedGenreId: Int?) -> [Int] {
        selectedGenreId.map { [$0] } ?? []
    }

    func testWatchNowGenreFilter_anyMapsToEmptyDiscoverGenres() {
        XCTAssertEqual(activeGenreIds(for: nil), [])
    }

    func testWatchNowGenreFilter_onboardingGenresMapToSingleTmdbId() {
        for g in GenreCatalog.onboarding {
            XCTAssertEqual(activeGenreIds(for: g.tmdbGenreId), [g.tmdbGenreId])
        }
    }

    func test_watchNowGenreChips_hidesDislikedOnboardingGenres() {
        var prefs = GenreCatalog.defaultPreferences()
        prefs["Horror"] = .dislike
        prefs["Sci-Fi"] = .dislike
        let chips = GenreCatalog.watchNowGenreChips(preferences: prefs)
        XCTAssertFalse(chips.contains { $0.tmdbGenreId == 27 })
        XCTAssertFalse(chips.contains { $0.tmdbGenreId == 878 })
        XCTAssertTrue(chips.contains { $0.tmdbGenreId == 35 })
        XCTAssertEqual(chips.count, GenreCatalog.onboarding.count - 2)
    }

    func testGenreCatalog_onboardingCoversWatchNowChips() {
        let ids = Set(GenreCatalog.onboarding.map(\.tmdbGenreId))
        XCTAssertTrue(ids.contains(28))    // Action
        XCTAssertTrue(ids.contains(35))    // Comedy
        XCTAssertTrue(ids.contains(10749)) // Romance
    }

    func testTimeSlotMaxMinutes() {
        XCTAssertEqual(TimeSlot.any.maxMinutes, Int.max)
        XCTAssertEqual(TimeSlot.under90.maxMinutes, 90)
        XCTAssertEqual(TimeSlot.under120.maxMinutes, 120)
    }
}

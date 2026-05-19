import XCTest
@testable import moviefinder

/// Exercises real SQLite + `fetchSwipeQueue` using bundled `pickr_library_minimal.db` (regenerate: `python3 scripts/make_minimal_library_fixture.py`).
@MainActor
final class MovieLibraryServiceSQLiteTests: XCTestCase {

    private var service: MovieLibraryService!

    override func setUp() async throws {
        try await super.setUp()
        let bundle = Bundle(for: MovieLibraryServiceSQLiteTests.self)
        guard let url = bundle.url(forResource: "pickr_library_minimal", withExtension: "db") else {
            XCTFail("Missing moviefinderTests/pickr_library_minimal.db — run: python3 scripts/make_minimal_library_fixture.py")
            return
        }
        service = MovieLibraryService(libraryFileURLForTesting: url)
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    func test_fixtureOpensAndIsReady() {
        XCTAssertTrue(service.isReady, "Fixture should open read-only")
    }

    func test_fetchSwipeQueue_likedAction_returnsHighestPopularityFirst() {
        let rows = service.fetchSwipeQueue(
            likedGenreIds: [28],
            dislikedGenreIds: [],
            excludingIds: [],
            limit: 10
        )
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.first?.id, 100_001)
        XCTAssertEqual(rows.first?.title, "Fixture Action Alpha")
    }

    func test_fetchSwipeQueue_excludingIds_filtersMovie() {
        let rows = service.fetchSwipeQueue(
            likedGenreIds: [28],
            dislikedGenreIds: [],
            excludingIds: [100_001],
            limit: 10
        )
        XCTAssertFalse(rows.contains { $0.id == 100_001 })
    }

    func test_fetchSwipeQueue_dislikedGenre_excludesTitlesWithThatGenre() {
        let rows = service.fetchSwipeQueue(
            likedGenreIds: [35],
            dislikedGenreIds: [27],
            excludingIds: [],
            limit: 10
        )
        XCTAssertTrue(rows.contains { $0.id == 100_002 })
        XCTAssertFalse(rows.contains { $0.id == 100_003 })
    }
}

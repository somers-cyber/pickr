import XCTest
@testable import moviefinder

@MainActor
final class MovieDetailIntegrationTests: XCTestCase {

    func test_watchlistStore_addDoesNotDuplicateIds() {
        let store = WatchlistStore.shared
        store.remove(id: 42_001)
        store.remove(id: 42_002)
        let m = makeMovie(id: 42_001)
        store.add(m)
        store.add(m)
        XCTAssertEqual(store.allIds().filter { $0 == 42_001 }.count, 1)
        store.remove(id: 42_001)
    }

    func test_evaluation_needsArchiveImageFetch_whenPosterURLWouldBeNil() {
        let ev = EvaluationsStore.shared
        let id = 99_002
        ev.remove(tmdbId: id)
        let noPoster = TMDBMovie(
            id: id, title: "B", overview: "", releaseDate: "2024-01-01",
            posterPath: nil, backdropPath: nil, voteAverage: 7.2, voteCount: 1,
            genreIds: [27], popularity: 1
        )
        ev.record(tmdbId: id, verdict: .liked, movie: noPoster)
        guard let row = ev.all.last(where: { $0.tmdbId == id }) else {
            XCTFail("missing evaluation"); return
        }
        XCTAssertTrue(row.needsArchiveImageFetch)
        XCTAssertFalse(row.hasRenderableArchiveImage)
        ev.remove(tmdbId: id)
    }

    /// Same path as MovieDetail `record(.like)` / `record(.skip)` — genreWeights and swipeHistory update.
    /// `async` so the body runs on the main actor (`RecommendationEngine` is module-default `@MainActor`).
    func test_recordLikeAndSkip_updatesProfile() async {
        let storage = MockProfileStorage()
        let engine = RecommendationEngine(storage: storage)
        let likeDetail = makeDetail(id: 7, genreIds: [35])
        engine.record(SwipeEvent(movieId: 7, action: .like, movie: likeDetail, timestamp: Date()))
        XCTAssertEqual(engine.profile.totalSwipes, 1)
        XCTAssertFalse(engine.profile.swipeHistory.isEmpty)

        let skipDetail = makeDetail(id: 8, genreIds: [27])
        engine.record(SwipeEvent(movieId: 8, action: .skip, movie: skipDetail, timestamp: Date()))
        XCTAssertEqual(engine.profile.totalSwipes, 2)
    }

    /// Ensures a second `record` with a movie missing `posterPath` does not wipe a previously cached poster.
    func test_evaluationsRecord_mergingKeepsPosterWhenUpdateHasNilPoster() {
        let ev = EvaluationsStore.shared
        let id = 99_001
        ev.remove(tmdbId: id)
        let withPoster = TMDBMovie(
            id: id, title: "A", overview: "", releaseDate: "2020-01-01",
            posterPath: "/p1.jpg", backdropPath: nil, voteAverage: 6, voteCount: 1,
            genreIds: [28], popularity: 1
        )
        ev.record(tmdbId: id, verdict: .liked, movie: withPoster)
        let stripped = TMDBMovie(
            id: id, title: "A", overview: "", releaseDate: "2020-01-01",
            posterPath: nil, backdropPath: "/bd.jpg", voteAverage: 6.5, voteCount: 1,
            genreIds: [28], popularity: 1
        )
        ev.record(tmdbId: id, verdict: .liked, movie: stripped)
        let movie = ev.all.last { $0.tmdbId == id }?.toTMDBMovie()
        XCTAssertEqual(movie?.posterPath, "/p1.jpg")
        XCTAssertEqual(movie?.backdropPath, "/bd.jpg")
        ev.remove(tmdbId: id)
    }
}

private func makeMovie(id: Int) -> TMDBMovie {
    TMDBMovie(id: id, title: "T\(id)", overview: "o", releaseDate: "2020-01-01",
              posterPath: nil, backdropPath: nil, voteAverage: 7, voteCount: 100,
              genreIds: [28], popularity: 10)
}

private func makeDetail(id: Int, genreIds: [Int]) -> TMDBMovieDetail {
    TMDBMovieDetail(
        id: id, title: "M\(id)", overview: "o", tagline: nil, releaseDate: "2020-01-01",
        runtime: 100, voteAverage: 7, posterPath: nil, backdropPath: nil,
        genres: genreIds.map { TMDBGenre(id: $0, name: "G") }, watchProviders: nil
    )
}

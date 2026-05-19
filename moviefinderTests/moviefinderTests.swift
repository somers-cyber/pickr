//
//  moviefinderTests.swift
//  moviefinderTests
//

import XCTest
@testable import moviefinder

final class moviefinderTests: XCTestCase {

    func testTMDBMovieYearFromReleaseDate() throws {
        let json = """
        {"id":1,"title":"T","overview":"","vote_average":7,"vote_count":1,"genre_ids":[],"popularity":1,"release_date":"2020-05-01"}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(TMDBMovie.self, from: json)
        XCTAssertEqual(m.year, "2020")
    }

    func testTMDBDiscoverDefaultsMinimumRuntime() {
        XCTAssertGreaterThanOrEqual(TMDBDiscoverDefaults.minimumRuntimeMinutes, 60)
    }
}

// TMDBServiceTests.swift
// Offline decoding via URLProtocol + injectable URLSession.

import XCTest
@testable import moviefinder

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class TMDBServiceTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try await super.tearDown()
    }

    func test_fetchTrendingMovies_decodesPagedResults() async throws {
        let json = """
        {"page":1,"results":[
          {"id":42,"title":"Test Movie","overview":"Hi","release_date":"2021-06-01",
           "poster_path":null,"backdrop_path":null,"vote_average":7.5,"vote_count":100,
           "genre_ids":[28,12],"popularity":50.0}
        ],"total_pages":1,"total_results":1}
        """
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.contains("/trending/movie/week") == true)
            let data = Data(json.utf8)
            let res = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, res)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = TMDBService(urlSession: session)
        let page: TMDBPagedResponse<TMDBMovie> = try await service.fetchTrendingMovies()
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results.first?.id, 42)
        XCTAssertEqual(page.results.first?.title, "Test Movie")
        XCTAssertEqual(page.results.first?.year, "2021")
    }

    func test_searchMovies_decodesPagedResults() async throws {
        let json = """
        {"page":1,"results":[
          {"id":99,"title":"Search Hit","overview":"A hit","release_date":"2022-03-15",
           "poster_path":"/p.jpg","backdrop_path":null,"vote_average":6.2,"vote_count":50,
           "genre_ids":[35],"popularity":12.0}
        ],"total_pages":1,"total_results":1}
        """
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.contains("/search/movie") == true)
            XCTAssertTrue(req.url?.query?.contains("query=hello") == true)
            let data = Data(json.utf8)
            let res = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, res)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = TMDBService(urlSession: URLSession(configuration: config))
        let page: TMDBPagedResponse<TMDBMovie> = try await service.searchMovies(query: "hello")
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results.first?.id, 99)
        XCTAssertEqual(page.results.first?.title, "Search Hit")
    }

    func test_apiError_mapsStatusCode() async throws {
        MockURLProtocol.handler = { req in
            let data = Data(#"{"status_message":"Invalid"}"#.utf8)
            let res = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = TMDBService(urlSession: URLSession(configuration: config))
        do {
            let _: TMDBPagedResponse<TMDBMovie> = try await service.fetchTrendingMovies()
            XCTFail("Expected TMDBError.apiError")
        } catch let e as TMDBError {
            if case .apiError(let code, _) = e {
                XCTAssertEqual(code, 401)
            } else {
                XCTFail("Wrong error \(e)")
            }
        }
    }
}

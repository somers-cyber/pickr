// TMDBService.swift
// TMDB API — Swift 5 + Swift 6 safe
// Get a free API key: https://www.themoviedb.org/settings/api

import Foundation

// MARK: - Config

/// Opts out of target `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` so networking/decoding stays usable from `actor TMDBService`.
nonisolated enum TMDBConfig: Sendable {
    static let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String,
              !key.isEmpty, key != "$(TMDB_API_KEY)"
        else { fatalError("TMDB_API_KEY missing from Info.plist — add it to Secrets.xcconfig") }
        return key
    }()
    static let baseURL = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p/"
}

/// Shared discover rules (`/discover/movie`).
nonisolated enum TMDBDiscoverDefaults: Sendable {
    /// `with_runtime.gte` — exclude shorts / TV specials listed as movies (minutes).
    static let minimumRuntimeMinutes = 60
}

nonisolated func tmdbPosterURL(_ path: String, size: String = "w500") -> URL? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return URL(string: trimmed)
    }
    let normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    return URL(string: "\(TMDBConfig.imageBase)\(size)\(normalized)")
}

// MARK: - Errors

nonisolated enum TMDBError: LocalizedError {
    case invalidURL
    case invalidResponse
    case decodingFailed(Error)
    case apiError(Int, String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:                   return "Invalid URL"
        case .invalidResponse:              return "Invalid server response"
        case .decodingFailed(let e):        return "Decoding failed: \(e.localizedDescription)"
        case .apiError(let code, let msg):  return "API error \(code): \(msg)"
        case .networkError(let e):          return "Network error: \(e.localizedDescription)"
        }
    }
}

// MARK: - Models

nonisolated struct TMDBPagedResponse<T: Decodable>: Decodable {
    let page: Int
    let results: [T]
    let totalPages: Int
    let totalResults: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages   = "total_pages"
        case totalResults = "total_results"
    }
}

nonisolated struct TMDBMovie: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let overview: String
    let releaseDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double
    let voteCount: Int
    let genreIds: [Int]
    let popularity: Double

    enum CodingKeys: String, CodingKey {
        case id, title, overview, popularity
        case releaseDate  = "release_date"
        case posterPath   = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage  = "vote_average"
        case voteCount    = "vote_count"
        case genreIds     = "genre_ids"
    }

    var year: String { String(releaseDate?.prefix(4) ?? "—") }
    var posterURL: URL? {
        if let p = posterPath, let url = tmdbPosterURL(p) {
            return url
        }
        if let b = backdropPath, let url = tmdbPosterURL(b, size: "w780") {
            return url
        }
        return nil
    }
}

nonisolated struct TMDBTVShow: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let overview: String
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double
    let voteCount: Int
    let genreIds: [Int]
    let popularity: Double

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity
        case firstAirDate = "first_air_date"
        case posterPath   = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage  = "vote_average"
        case voteCount    = "vote_count"
        case genreIds     = "genre_ids"
    }

    var year: String { String(firstAirDate?.prefix(4) ?? "—") }
}

nonisolated struct TMDBGenre: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
}

nonisolated struct TMDBMovieDetail: Decodable, Sendable {
    let id: Int
    let title: String
    let overview: String
    let tagline: String?
    let releaseDate: String?
    let runtime: Int?
    let voteAverage: Double
    let posterPath: String?
    let backdropPath: String?
    let genres: [TMDBGenre]
    let watchProviders: WatchProviderResult?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, tagline, runtime, genres
        case releaseDate    = "release_date"
        case voteAverage    = "vote_average"
        case posterPath     = "poster_path"
        case backdropPath   = "backdrop_path"
        case watchProviders = "watch/providers"
    }

    nonisolated struct WatchProviderResult: Decodable, Sendable {
        let results: [String: WatchProviderRegion]
    }
    nonisolated struct WatchProviderRegion: Decodable, Sendable {
        let flatrate: [WatchProvider]?
        let rent: [WatchProvider]?
        let buy: [WatchProvider]?
    }
    nonisolated struct WatchProvider: Decodable, Identifiable, Sendable {
        let providerId: Int
        let providerName: String
        let logoPath: String?
        var id: Int { providerId }
        enum CodingKeys: String, CodingKey {
            case providerId   = "provider_id"
            case providerName = "provider_name"
            case logoPath     = "logo_path"
        }
    }
}

nonisolated struct TMDBSearchResult: Decodable, Identifiable, Sendable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let overview: String
    let posterPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?

    var displayTitle: String { title ?? name ?? "Unknown" }
    var year: String { String((releaseDate ?? firstAirDate ?? "").prefix(4)) }
    var posterURL: URL? {
        guard let p = posterPath else { return nil }
        return tmdbPosterURL(p)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType    = "media_type"
        case posterPath   = "poster_path"
        case voteAverage  = "vote_average"
        case releaseDate  = "release_date"
        case firstAirDate = "first_air_date"
    }
}

nonisolated struct MovieCredits: Sendable {
    let cast: [TMDBPerson]
    let crew: [TMDBPerson]
}

// MARK: - TMDBService

actor TMDBService {
    static let shared = TMDBService()

    private let decoder = JSONDecoder()
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // nonisolated so SwiftUI views can call it without MainActor warnings
    nonisolated func makeURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        var c = URLComponents(string: TMDBConfig.baseURL + path)!
        c.queryItems = [
            URLQueryItem(name: "api_key",  value: TMDBConfig.apiKey),
            URLQueryItem(name: "language", value: "en-US"),
        ] + queryItems
        return c.url
    }

    func request<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let url = makeURL(path: path, queryItems: queryItems) else {
            throw TMDBError.invalidURL
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            throw TMDBError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw TMDBError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["status_message"] ?? "Unknown"
            throw TMDBError.apiError(http.statusCode, msg)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decodingFailed(error)
        }
    }

    // MARK: Trending

    func fetchTrendingMovies(page: Int = 1) async throws -> TMDBPagedResponse<TMDBMovie> {
        try await request(path: "/trending/movie/week",
                          queryItems: [URLQueryItem(name: "page", value: "\(page)")])
    }

    func fetchTrendingTV(page: Int = 1) async throws -> TMDBPagedResponse<TMDBTVShow> {
        try await request(path: "/trending/tv/week",
                          queryItems: [URLQueryItem(name: "page", value: "\(page)")])
    }

    // MARK: Search

    func searchMulti(query: String, page: Int = 1) async throws -> TMDBPagedResponse<TMDBSearchResult> {
        try await request(path: "/search/multi", queryItems: [
            URLQueryItem(name: "query",         value: query),
            URLQueryItem(name: "page",          value: "\(page)"),
            URLQueryItem(name: "include_adult", value: "false"),
        ])
    }

    /// Full TMDB movie search (any title in the catalog). Used by Watch Now search sheet.
    func searchMovies(query: String, page: Int = 1) async throws -> TMDBPagedResponse<TMDBMovie> {
        try await request(path: "/search/movie", queryItems: [
            URLQueryItem(name: "query",         value: query),
            URLQueryItem(name: "page",          value: "\(page)"),
            URLQueryItem(name: "include_adult", value: "false"),
        ])
    }

    // MARK: Discover

    func discoverMovies(genreIds: [Int] = [], minRating: Double = 0,
                        sortBy: String = "popularity.desc", page: Int = 1) async throws -> TMDBPagedResponse<TMDBMovie> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "include_adult",    value: "false"),
            URLQueryItem(name: "with_runtime.gte", value: "\(TMDBDiscoverDefaults.minimumRuntimeMinutes)"),
            URLQueryItem(name: "sort_by",          value: sortBy),
            URLQueryItem(name: "vote_average.gte", value: "\(minRating)"),
            URLQueryItem(name: "vote_count.gte",   value: "100"),
            URLQueryItem(name: "page",             value: "\(page)"),
        ]
        if !genreIds.isEmpty {
            items.append(URLQueryItem(name: "with_genres",
                                      value: genreIds.map(String.init).joined(separator: ",")))
        }
        return try await request(path: "/discover/movie", queryItems: items)
    }

    func discoverStreamingMovies(providerIds: Set<Int>, region: String = "US",
                                  genreIds: [Int] = [], minRating: Double = 0,
                                  sortBy: String = "popularity.desc", page: Int = 1,
                                  maxRuntime: Int? = nil,
                                  minVoteCount: Int = 500) async throws -> TMDBPagedResponse<TMDBMovie> {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -180, to: Date()) ?? Date()
        let cutoffDateString = cutoffDate.formatted(.iso8601.year().month().day())

        var items: [URLQueryItem] = [
            URLQueryItem(name: "include_adult",                 value: "false"),
            URLQueryItem(name: "with_runtime.gte",            value: "\(TMDBDiscoverDefaults.minimumRuntimeMinutes)"),
            URLQueryItem(name: "sort_by",                       value: sortBy),
            URLQueryItem(name: "vote_average.gte",              value: "\(minRating)"),
            URLQueryItem(name: "vote_count.gte",                value: "\(minVoteCount)"),
            URLQueryItem(name: "watch_region",                  value: region),
            URLQueryItem(name: "with_watch_monetization_types", value: "flatrate"),
            URLQueryItem(name: "primary_release_date.lte",      value: cutoffDateString),
            URLQueryItem(name: "page",                          value: "\(page)"),
        ]
        if !providerIds.isEmpty {
            items.append(URLQueryItem(name: "with_watch_providers",
                                      value: providerIds.map(String.init).joined(separator: "|")))
        }
        if !genreIds.isEmpty {
            // Pipe separator = OR logic: a movie needs to match ANY of the genres, not ALL.
            // Comma separator would mean AND (every genre must be present), which returns near-zero results.
            items.append(URLQueryItem(name: "with_genres",
                                      value: genreIds.map(String.init).joined(separator: "|")))
        }
        if let maxRuntime {
            items.append(URLQueryItem(name: "with_runtime.lte", value: "\(maxRuntime)"))
        }
        return try await request(path: "/discover/movie", queryItems: items)
    }

    // MARK: Detail

    func fetchMovieDetail(id: Int) async throws -> TMDBMovieDetail {
        try await request(path: "/movie/\(id)",
                          queryItems: [URLQueryItem(name: "append_to_response", value: "watch/providers")])
    }

    // MARK: Recommendations

    func fetchMovieRecommendations(id: Int, page: Int = 1) async throws -> TMDBPagedResponse<TMDBMovie> {
        try await request(path: "/movie/\(id)/recommendations",
                          queryItems: [URLQueryItem(name: "page", value: "\(page)")])
    }

    func fetchSimilarMovies(id: Int, page: Int = 1) async throws -> TMDBPagedResponse<TMDBMovie> {
        try await request(path: "/movie/\(id)/similar",
                          queryItems: [URLQueryItem(name: "page", value: "\(page)")])
    }

    // MARK: Genres

    func fetchMovieGenres() async throws -> [TMDBGenre] {
        struct R: Decodable { let genres: [TMDBGenre] }
        let r: R = try await request(path: "/genre/movie/list")
        return r.genres
    }

    // MARK: Credits

    func fetchMovieCredits(id: Int) async throws -> MovieCredits {
        struct Raw: Decodable { let cast: [TMDBPerson]; let crew: [TMDBPerson] }
        let raw: Raw = try await request(path: "/movie/\(id)/credits")
        return MovieCredits(cast: raw.cast, crew: raw.crew)
    }
}

// MovieLibraryService.swift
// Pickr — On-device movie library (SQLite, downloaded once on first launch).
//
// Library file: hosted on GitHub (raw). Rebuild with scripts/build_pickr_library.py when updating.

import Combine
import Foundation
import SQLite3

// MARK: - Download State

enum LibraryDownloadState: Equatable {
    case idle
    case downloading(progress: Double) // 0.0 – 1.0
    case ready
    case failed(String)
}

// MARK: - MovieLibraryService

@MainActor
final class MovieLibraryService: ObservableObject {

    // CDN URL for the current library build.
    // VERSIONING: When refreshing the library (annually or on schema change),
    // bump the filename (e.g. pickr_library_v2.db) AND add logic here to detect
    // and replace a stale on-device version. Without this, returning users who
    // already have v1 will never download the updated file — isReady returns true
    // and downloadIfNeeded() no-ops immediately.
    // TODO: Add a lightweight version-check endpoint or embed a build date in the
    // DB and compare against a remote manifest before deciding to skip download.
    private let cdnURL = URL(string: "https://raw.githubusercontent.com/somers-cyber/pickr-library/main/pickr_library_v1.db")!

    /// Path to the SQLite file on disk (Application Support in production; bundle/temp in tests).
    private let libraryFileURL: URL

    @Published private(set) var downloadState: LibraryDownloadState = .idle

    /// C handle; not actor-isolated so `deinit` can close without crossing MainActor.
    private nonisolated(unsafe) var db: OpaquePointer?
    private var observation: NSKeyValueObservation?

    private init(libraryFileURL: URL, openExistingFile: Bool) {
        self.libraryFileURL = libraryFileURL
        if openExistingFile, FileManager.default.fileExists(atPath: libraryFileURL.path) {
            openDatabase()
        }
    }

    /// Production singleton: `Application Support/pickr_library_v1.db`.
    static let shared: MovieLibraryService = {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pickr_library_v1.db")
        return MovieLibraryService(libraryFileURL: url, openExistingFile: true)
    }()

    /// Unit tests: opens read‑only library at `url` (e.g. `Bundle` fixture). Not used by the app at runtime.
    internal convenience init(libraryFileURLForTesting url: URL) {
        self.init(libraryFileURL: url, openExistingFile: true)
    }

    // MARK: - Public

    var isReady: Bool {
        if case .ready = downloadState { return true }
        return false
    }

    /// Starts the download if the library isn't already on device.
    /// Safe to call multiple times — no-ops if already downloading or ready.
    func downloadIfNeeded() async {
        guard !isReady else { return }
        guard case .idle = downloadState else { return }

        try? FileManager.default.createDirectory(
            at: libraryFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        await runCDNLibraryDownload(replacingExistingDatabase: false)
    }

    /// Force a fresh download of the on-device catalog (e.g. Curate ran out of unseen titles after a server-side library expand).
    /// Does **not** touch watchlist, Archives (`EvaluationsStore`), or the taste profile — only replaces the SQLite movie list file.
    func redownloadLibraryReplacingExisting() async {
        if case .downloading = downloadState { return }
        observation?.invalidate()
        observation = nil

        if db != nil {
            sqlite3_close(db)
            db = nil
        }

        try? FileManager.default.createDirectory(
            at: libraryFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        downloadState = .idle
        await runCDNLibraryDownload(replacingExistingDatabase: true)
    }

    /// Shared URLSession download → replace file → open read-only DB.
    private func runCDNLibraryDownload(replacingExistingDatabase: Bool) async {
        downloadState = .downloading(progress: 0)

        await withCheckedContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: cdnURL) { [weak self] tempURL, _, error in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.observation?.invalidate()
                    self.observation = nil

                    if let error {
                        self.downloadState = .failed(error.localizedDescription)
                        if replacingExistingDatabase {
                            self.openDatabaseIfExistingFileOnDisk()
                        }
                        continuation.resume()
                        return
                    }
                    guard let tempURL else {
                        self.downloadState = .failed("Download returned no file.")
                        if replacingExistingDatabase {
                            self.openDatabaseIfExistingFileOnDisk()
                        }
                        continuation.resume()
                        return
                    }
                    do {
                        if FileManager.default.fileExists(atPath: self.libraryFileURL.path) {
                            try FileManager.default.removeItem(at: self.libraryFileURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: self.libraryFileURL)
                        self.openDatabase()
                    } catch {
                        self.downloadState = .failed(error.localizedDescription)
                        if replacingExistingDatabase {
                            self.openDatabaseIfExistingFileOnDisk()
                        }
                    }
                    continuation.resume()
                }
            }

            observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.downloadState else { return }
                    self.downloadState = .downloading(progress: progress.fractionCompleted)
                }
            }

            task.resume()
        }
    }

    /// After a failed replace download, try to keep Curate working with the previous file if it still exists.
    private func openDatabaseIfExistingFileOnDisk() {
        guard FileManager.default.fileExists(atPath: libraryFileURL.path) else {
            downloadState = .failed("Could not restore movie library.")
            return
        }
        openDatabase()
    }

    // MARK: - Query

    /// Returns up to `limit` TMDBMovies for the swipe queue.
    /// Liked-genre movies come first; disliked genres are excluded entirely.
    /// Already-seen and ignored IDs are filtered out.
    func fetchSwipeQueue(
        likedGenreIds: [Int],
        dislikedGenreIds: [Int],
        excludingIds: Set<Int>,
        limit: Int = 80
    ) -> [TMDBMovie] {
        guard let db else { return [] }

        let allGenreIds = GenreCatalog.onboarding.map(\.tmdbGenreId)
        let neutralGenreIds = allGenreIds.filter {
            !likedGenreIds.contains($0) && !dislikedGenreIds.contains($0)
        }

        var results: [TMDBMovie] = []

        if !likedGenreIds.isEmpty {
            let liked = query(
                db: db,
                includeGenreIds: likedGenreIds,
                excludeGenreIds: dislikedGenreIds,
                excludeMovieIds: excludingIds,
                limit: limit
            )
            results.append(contentsOf: liked)
        }

        if results.count < limit, !neutralGenreIds.isEmpty {
            let usedIds = excludingIds.union(Set(results.map(\.id)))
            let neutral = query(
                db: db,
                includeGenreIds: neutralGenreIds,
                excludeGenreIds: dislikedGenreIds,
                excludeMovieIds: usedIds,
                limit: limit - results.count
            )
            results.append(contentsOf: neutral)
        }

        return results
    }

    // MARK: - Private helpers

    private func openDatabase() {
        var ptr: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(libraryFileURL.path, &ptr, flags, nil) == SQLITE_OK {
            db = ptr
            downloadState = .ready
        } else {
            downloadState = .failed("Could not open library database.")
        }
    }

    /// Core SQLite query: movies in `includeGenreIds`, not in `excludeGenreIds`, not already seen.
    /// `excludeMovieIds` is pushed into the SQL WHERE clause (capped at 900 to stay under SQLite's
    /// variable limit); any overflow IDs are filtered in Swift as a safety net.
    private func query(
        db: OpaquePointer,
        includeGenreIds: [Int],
        excludeGenreIds: [Int],
        excludeMovieIds: Set<Int>,
        limit: Int
    ) -> [TMDBMovie] {
        guard !includeGenreIds.isEmpty else { return [] }

        let incPlaceholders = includeGenreIds.map { _ in "?" }.joined(separator: ",")

        let excClause: String
        if excludeGenreIds.isEmpty {
            excClause = ""
        } else {
            let excPlaceholders = excludeGenreIds.map { _ in "?" }.joined(separator: ",")
            excClause = """
            AND m.id NOT IN (
                SELECT DISTINCT movie_id FROM movie_genres
                WHERE genre_id IN (\(excPlaceholders))
            )
            """
        }

        // Push as many seen IDs into SQL as SQLite allows (parameter limit ≈ 999).
        // Any overflow IDs are filtered Swift-side below.
        let sqlParamBudget = 900 - includeGenreIds.count - excludeGenreIds.count
        let cappedExcludeMovieIds = sqlParamBudget > 0
            ? Array(excludeMovieIds.prefix(sqlParamBudget))
            : []
        let excMovieClause: String
        if cappedExcludeMovieIds.isEmpty {
            excMovieClause = ""
        } else {
            let ph = cappedExcludeMovieIds.map { _ in "?" }.joined(separator: ",")
            excMovieClause = "AND m.id NOT IN (\(ph))"
        }

        // Use a generous SQL LIMIT so the engine has enough ranked candidates even after
        // the user has swiped through many popular titles.
        let sqlLimit = max(limit * 8, 1000)

        let sql = """
            SELECT DISTINCT m.id, m.title, m.overview, m.release_date,
                   m.poster_path, m.backdrop_path,
                   m.vote_average, m.vote_count, m.popularity, m.genre_ids_json
            FROM movies m
            JOIN movie_genres mg ON m.id = mg.movie_id
            WHERE mg.genre_id IN (\(incPlaceholders))
            \(excClause)
            \(excMovieClause)
            ORDER BY m.popularity DESC
            LIMIT \(sqlLimit)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for gid in includeGenreIds      { sqlite3_bind_int(stmt, idx, Int32(gid)); idx += 1 }
        for gid in excludeGenreIds      { sqlite3_bind_int(stmt, idx, Int32(gid)); idx += 1 }
        for mid in cappedExcludeMovieIds { sqlite3_bind_int(stmt, idx, Int32(mid)); idx += 1 }

        var movies: [TMDBMovie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            // Swift-side safety net for overflow IDs that didn't fit in the SQL clause.
            guard !excludeMovieIds.contains(id) else { continue }

            let genreIds: [Int]
            if let jsonStr = sqlite3_column_text(stmt, 9) {
                let str = String(cString: jsonStr)
                genreIds = (try? JSONDecoder().decode([Int].self, from: Data(str.utf8))) ?? []
            } else {
                genreIds = []
            }

            movies.append(
                TMDBMovie(
                    id: id,
                    title: colStr(stmt, 1) ?? "",
                    overview: colStr(stmt, 2) ?? "",
                    releaseDate: colStr(stmt, 3),
                    posterPath: colStr(stmt, 4),
                    backdropPath: colStr(stmt, 5),
                    voteAverage: sqlite3_column_double(stmt, 6),
                    voteCount: Int(sqlite3_column_int(stmt, 7)),
                    genreIds: genreIds,
                    popularity: sqlite3_column_double(stmt, 8)
                )
            )
            if movies.count >= limit { break }
        }
        return movies
    }

    private func colStr(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        let s = String(cString: cStr)
        return s.isEmpty ? nil : s
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }
}

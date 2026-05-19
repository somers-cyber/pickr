// DataExportService.swift
// Compiles a user's anonymized data package — the product you sell to content companies.
// Call DataExportService.shared.buildPackage() to get a JSON-ready dictionary.
// When you have a backend, call uploadIfConsented() to POST it automatically.

import Foundation
import CryptoKit

struct DataPackage: Codable {
    // Anonymous identifier — not the user's real ID, rotated for privacy
    let anonymousId: String

    // Demographics
    let ageGroup:  String?
    let gender:    String?
    let country:   String?

    // Taste profile
    let genrePreferences: [String: String]  // genre name → "like" / "dislike" / "neutral"
    let topLikedGenres:   [String]
    let topDislikedGenres: [String]

    // Behavioral signals
    let totalSwipes:      Int
    let likeRate:         Double   // 0.0 – 1.0
    let streamingServices: [String]

    // Meta
    let appVersion:   String
    let packageDate:  String        // ISO 8601
    let consentGiven: Bool
}

@MainActor
final class DataExportService {
    static let shared = DataExportService()
    private init() {}

    /// Builds the anonymized data package from current state.
    func buildPackage(
        profile: UserProfile,
        genrePrefs: GenrePreferencesStore,
        engine: RecommendationEngine,
        streamingPrefs: StreamingPreferences
    ) -> DataPackage {
        // Rotate the user's ID so it can't be reverse-mapped
        let anonId = rotatedId(from: profile.id)

        // Genre preferences
        let rawPrefs = genrePrefs.genrePreferences
        let prefMap  = rawPrefs.mapValues { $0.rawValue }
        let liked    = rawPrefs.filter { $0.value == .like }.map(\.key).sorted()
        let disliked = rawPrefs.filter { $0.value == .dislike }.map(\.key).sorted()

        // Swipe stats from the engine's TasteProfile
        let ep          = engine.profile
        let totalSwipes = ep.totalSwipes
        let likes       = ep.likedIds.count
        let likeRate    = totalSwipes > 0 ? Double(likes) / Double(totalSwipes) : 0

        // Streaming services
        let services = streamingPrefs.selectedServices.map(\.name)

        return DataPackage(
            anonymousId:       anonId,
            ageGroup:          profile.ageGroup?.rawValue,
            gender:            profile.gender?.rawValue,
            country:           profile.country,
            genrePreferences:  prefMap,
            topLikedGenres:    liked,
            topDislikedGenres: disliked,
            totalSwipes:       totalSwipes,
            likeRate:          (likeRate * 1000).rounded() / 1000,  // 3 decimal places
            streamingServices: services,
            appVersion:        appVersionString,
            packageDate:       ISO8601DateFormatter().string(from: Date()),
            consentGiven:      profile.dataShareConsent
        )
    }

    /// Returns the JSON representation of the package (ready to POST to your API).
    func packageJSON(
        profile: UserProfile,
        genrePrefs: GenrePreferencesStore,
        engine: RecommendationEngine,
        streamingPrefs: StreamingPreferences
    ) -> Data? {
        let pkg = buildPackage(
            profile: profile,
            genrePrefs: genrePrefs,
            engine: engine,
            streamingPrefs: streamingPrefs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(pkg)
    }

    /// **Release / beta:** empty in non-DEBUG builds so no upload runs until the backend is real. Remove the `#if DEBUG` wrapper (and extend the body to all configurations) when `api.pickr.app/v1/data-export` is ready.
    /// Upload the package to your data API endpoint.
    /// Replace the URL and auth header with your real backend details.
    /// Only uploads if the user gave dataShareConsent (DEBUG only for now).
    func uploadIfConsented(
        profile: UserProfile,
        genrePrefs: GenrePreferencesStore,
        engine: RecommendationEngine,
        streamingPrefs: StreamingPreferences
    ) async {
#if DEBUG
        // Backend endpoint not yet live for Release — keep upload DEBUG-only until api.pickr.app/v1/data-export is ready, then drop this `#if`.
        guard profile.dataShareConsent else { return }

        guard let body = packageJSON(
            profile: profile,
            genrePrefs: genrePrefs,
            engine: engine,
            streamingPrefs: streamingPrefs
        ) else { return }

        // TODO: replace with your real endpoint
        guard let url = URL(string: "https://api.pickr.app/v1/data-export") else { return }

        var request = URLRequest(url: url)
        request.httpMethod  = "POST"
        request.httpBody    = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // TODO: add your API key header, e.g.:
        // request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[DataExport] Upload status: \(http.statusCode)")
            }
        } catch {
            print("[DataExport] Upload failed: \(error.localizedDescription)")
        }
#endif
    }

    // MARK: - Helpers

    /// One-way pseudonymous identifier: SHA-256(profile id + pepper), first 32 hex chars (distinct from reversible XOR).
    private func rotatedId(from userId: String) -> String {
        let payload = userId + "pickr_salt_2025"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build   = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

// Note: DataExportService reads from TasteProfile (engine.profile) directly.
// TasteProfile.totalSwipes → total number of swipes
// TasteProfile.likedIds    → IDs of movies the user liked
// TasteProfile.swipeHistory → last 150 swipe entries with genreIds + mult (+ = like, - = skip)

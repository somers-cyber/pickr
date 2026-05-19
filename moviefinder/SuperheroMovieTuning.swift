// SuperheroMovieTuning.swift
// TMDB discover/list payloads do not include keywords; Action + fantastical genres tracks most
// comic-book blockbusters. We gate by TMDB popularity so mid-list cape films don’t crowd out
// the rest of the catalog.

import Foundation

enum SuperheroMovieTuning {
    /// Action (28) plus Sci‑Fi (878) or Fantasy (14) — the mix that dominates streaming charts.
    static func isLikelySuperheroCluster(genreIds: [Int]) -> Bool {
        let g = Set(genreIds)
        guard g.contains(28) else { return false }
        return g.contains(878) || g.contains(14)
    }

    /// Stronger suppression for low TMDB popularity; ~flat once the title is a clear “event” release.
    static func popularityGateMultiplier(popularity: Double) -> Double {
        let p = max(popularity, 0)
        if p >= 90 { return 1.0 }
        if p >= 70 { return 0.95 }
        if p >= 52 { return 0.82 }
        if p >= 36 { return 0.62 }
        if p >= 22 { return 0.42 }
        return 0.28
    }
}

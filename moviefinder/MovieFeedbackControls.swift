// MovieFeedbackControls.swift
// Shared Like / Dislike / Watchlist circles + engine wiring (detail sheet + Watch Now tiles).

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Circle button

struct MovieFeedbackCircleButton: View {
    let icon: String
    let color: Color
    let isSelected: Bool
    let diameter: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    init(
        icon: String,
        color: Color,
        isSelected: Bool,
        diameter: CGFloat = 48,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.color = color
        self.isSelected = isSelected
        self.diameter = diameter
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : color)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(isSelected ? color : color.opacity(0.12))
                )
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? Color.white.opacity(0.35) : color.opacity(0.35),
                            lineWidth: isSelected ? 1.5 : max(1, diameter * 0.028)
                        )
                )
                .shadow(
                    color: isSelected ? color.opacity(0.42) : .clear,
                    radius: isSelected ? (diameter > 40 ? 12 : 8) : 0,
                    x: 0,
                    y: isSelected ? (diameter > 40 ? 5 : 3) : 0
                )
                .scaleEffect(isSelected ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isSelected)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Compact row (Watch Now pick cards)

struct WatchNowQuickFeedbackRow: View {
    let movie: TMDBMovie
    @Binding var feedback: MovieDetailFeedback
    @ObservedObject var engine: RecommendationEngine
    @ObservedObject var watchlistStore: WatchlistStore
    var buttonDiameter: CGFloat = 34
    var spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            MovieFeedbackCircleButton(
                icon: "hand.thumbsup.fill",
                color: .green,
                isSelected: feedback == .liked,
                diameter: buttonDiameter,
                accessibilityLabel: feedback == .liked ? "Unlike" : "Like"
            ) { MovieFeedbackActions.onLikeTap(movie: movie, feedback: &feedback, engine: engine) }

            MovieFeedbackCircleButton(
                icon: "hand.thumbsdown.fill",
                color: .red,
                isSelected: feedback == .disliked,
                diameter: buttonDiameter,
                accessibilityLabel: feedback == .disliked ? "Remove dislike" : "Dislike"
            ) { MovieFeedbackActions.onDislikeTap(movie: movie, feedback: &feedback, engine: engine) }

            MovieFeedbackCircleButton(
                icon: "bookmark.fill",
                color: .blue,
                isSelected: watchlistStore.contains(id: movie.id),
                diameter: buttonDiameter,
                accessibilityLabel: watchlistStore.contains(id: movie.id) ? "Remove from Watchlist" : "Add to Watchlist"
            ) { MovieFeedbackActions.onWatchlistTap(movie: movie, engine: engine, watchlistStore: watchlistStore) }
        }
    }
}

// MARK: - Actions

enum MovieFeedbackActions {
    static func feedbackHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func resolvedFeedback(movieId: Int, engine: RecommendationEngine) -> MovieDetailFeedback {
        var f = MovieDetailFeedbackStore.shared.feedback(for: movieId)
        if let v = EvaluationsStore.shared.verdict(for: movieId) {
            switch v {
            case .liked:    f = .liked
            case .disliked: f = .disliked
            }
        } else if f == .none, engine.profile.likedIds.contains(movieId) {
            f = .liked
        }
        return f
    }

    @MainActor
    static func onLikeTap(
        movie: TMDBMovie,
        feedback: inout MovieDetailFeedback,
        engine: RecommendationEngine,
        detail: TMDBMovieDetail? = nil,
        fetchCreditsOnLike: Bool = true
    ) {
        feedbackHaptic()
        let feedbackStore = MovieDetailFeedbackStore.shared
        let engineRecord = MovieDetailEngineRecordStore.shared
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            switch feedback {
            case .liked:
                feedback = .none
                feedbackStore.set(movie.id, .none)
                EvaluationsStore.shared.remove(tmdbId: movie.id)
                engine.revokeSwipeSignalsForMovie(movieId: movie.id)
                engineRecord.revokeLikeDislikeEngineTracking(for: movie.id)
            case .disliked:
                feedback = .liked
                feedbackStore.set(movie.id, .liked)
                EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .liked, movie: movie)
                record(action: .like, movie: movie, engine: engine, detail: detail)
                engineRecord.markLikeApplied(to: movie.id)
                if fetchCreditsOnLike {
                    Task { await fetchCredits(movieId: movie.id, engine: engine, wasLiked: true) }
                }
            case .none:
                feedback = .liked
                feedbackStore.set(movie.id, .liked)
                EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .liked, movie: movie)
                if engineRecord.consumeLikeRecord(for: movie.id) {
                    record(action: .like, movie: movie, engine: engine, detail: detail)
                } else {
                    record(action: .like, movie: movie, engine: engine, detail: detail)
                    engineRecord.markLikeApplied(to: movie.id)
                }
                if fetchCreditsOnLike {
                    Task { await fetchCredits(movieId: movie.id, engine: engine, wasLiked: true) }
                }
            }
        }
    }

    @MainActor
    static func onDislikeTap(
        movie: TMDBMovie,
        feedback: inout MovieDetailFeedback,
        engine: RecommendationEngine,
        detail: TMDBMovieDetail? = nil
    ) {
        feedbackHaptic()
        let feedbackStore = MovieDetailFeedbackStore.shared
        let engineRecord = MovieDetailEngineRecordStore.shared
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            switch feedback {
            case .disliked:
                feedback = .none
                feedbackStore.set(movie.id, .none)
                EvaluationsStore.shared.remove(tmdbId: movie.id)
                engine.revokeSwipeSignalsForMovie(movieId: movie.id)
                engineRecord.revokeLikeDislikeEngineTracking(for: movie.id)
            case .liked:
                feedback = .disliked
                feedbackStore.set(movie.id, .disliked)
                EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .disliked, movie: movie)
                record(action: .skip, movie: movie, engine: engine, detail: detail)
                engineRecord.markDislikeApplied(to: movie.id)
            case .none:
                feedback = .disliked
                feedbackStore.set(movie.id, .disliked)
                EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .disliked, movie: movie)
                if engineRecord.consumeDislikeRecord(for: movie.id) {
                    record(action: .skip, movie: movie, engine: engine, detail: detail)
                } else {
                    record(action: .skip, movie: movie, engine: engine, detail: detail)
                    engineRecord.markDislikeApplied(to: movie.id)
                }
            }
        }
    }

    @MainActor
    static func onWatchlistTap(
        movie: TMDBMovie,
        engine: RecommendationEngine,
        watchlistStore: WatchlistStore,
        detail: TMDBMovieDetail? = nil
    ) {
        feedbackHaptic()
        let engineRecord = MovieDetailEngineRecordStore.shared
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if watchlistStore.contains(id: movie.id) {
                watchlistStore.remove(id: movie.id)
                engineRecord.revokeWatchlistTracking(for: movie.id)
                engine.removeFromSeen(movieId: movie.id)
            } else {
                watchlistStore.add(movie)
                if engineRecord.consumeWatchlistRecord(for: movie.id) {
                    record(action: .watchlist, movie: movie, engine: engine, detail: detail)
                    Task { await fetchCredits(movieId: movie.id, engine: engine, wasLiked: true) }
                }
            }
        }
    }

    @MainActor
    private static func record(
        action: SwipeEvent.Action,
        movie: TMDBMovie,
        engine: RecommendationEngine,
        detail: TMDBMovieDetail?
    ) {
        let d = detail ?? stubDetail(from: movie)
        engine.record(SwipeEvent(movieId: movie.id, action: action, movie: d, timestamp: Date()))
    }

    @MainActor
    private static func stubDetail(from movie: TMDBMovie) -> TMDBMovieDetail {
        TMDBMovieDetail(
            id: movie.id, title: movie.title, overview: movie.overview,
            tagline: nil, releaseDate: movie.releaseDate, runtime: nil,
            voteAverage: movie.voteAverage, posterPath: movie.posterPath,
            backdropPath: movie.backdropPath,
            genres: movie.genreIds.map { TMDBGenre(id: $0, name: "") },
            watchProviders: nil
        )
    }

    @MainActor
    private static func fetchCredits(movieId: Int, engine: RecommendationEngine, wasLiked: Bool) async {
        guard let c = try? await TMDBService.shared.fetchMovieCredits(id: movieId) else { return }
        engine.enrichWithCredits(movieId: movieId, cast: c.cast, crew: c.crew, wasLiked: wasLiked)
    }
}

extension WatchNowMovie {
    /// Minimal `TMDBMovie` for evaluations / engine when only Watch Now row fields are available.
    func asTMDBMovie() -> TMDBMovie {
        TMDBMovie(
            id: id,
            title: title,
            overview: "",
            releaseDate: year == "—" ? nil : "\(year)-01-01",
            posterPath: posterPath,
            backdropPath: nil,
            voteAverage: voteAverage,
            voteCount: 0,
            genreIds: genreIds,
            popularity: 0
        )
    }
}

// MovieDetailView.swift
// Full movie detail sheet — poster, synopsis, actions (Like / Dislike / Watchlist) → RecommendationEngine

import SwiftUI

private enum MovieDetailChrome {
    /// Matches Discover action controls (`DiscoverLayout.actionButtonDiameter`).
    static let actionDiameter: CGFloat = 48
    /// Gap between the three circles (tight cluster).
    static let actionSpacing: CGFloat = 14
    /// Shared width for caption + buttons so edges align on typical phones.
    static let feedbackBlockMaxWidth: CGFloat = 300
}

struct MovieDetailView: View {
    let movie: TMDBMovie
    @ObservedObject var engine: RecommendationEngine
    @ObservedObject private var evaluationsStore = EvaluationsStore.shared
    @EnvironmentObject private var watchlistStore: WatchlistStore

    @State private var detail: TMDBMovieDetail?
    @State private var loading = true
    @State private var feedback: MovieDetailFeedback = .none
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    contentSection
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, Color.white.opacity(0.3))
                            .font(.title2)
                    }
                }
            }
            .task { await loadDetail() }
            .onAppear(perform: syncLocalState)
            .onChange(of: evaluationsStore.mutationGeneration) { _, _ in
                syncLocalState()
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = movie.posterURL {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.stablePlaceholderHue(for: movie.id, saturation: 0.4, brightness: 0.3))
                    }
                }
                .frame(height: 420)
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.stablePlaceholderHue(for: movie.id, saturation: 0.4, brightness: 0.3))
                    .frame(height: 420)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.9)],
                           startPoint: .center, endPoint: .bottom)
                .frame(height: 420)

            VStack(alignment: .leading, spacing: 6) {
                Text(movie.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(radius: 4)

                HStack(spacing: 12) {
                    Label(movie.year, systemImage: "calendar")
                    if let rt = detail?.runtime {
                        Label("\(rt / 60)h \(rt % 60)m", systemImage: "clock")
                    }
                    Label(String(format: "%.1f", movie.voteAverage), systemImage: "star.fill")
                        .foregroundStyle(.yellow, .yellow)
                }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
            }
            .padding(20)
        }
    }

    // MARK: - Body content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let d = detail {
                feedbackBlock
                if let providers = d.watchProviders?.results["US"],
                   let flatrate = providers.flatrate, !flatrate.isEmpty {
                    whereToWatchSection(flatrate)
                }
                overviewSection(d.overview.isEmpty ? movie.overview : d.overview)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 32)
    }

    private func overviewSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.title3.bold())
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Like / Dislike / Watchlist (aligned cluster + selected “premium” fill)

    private var feedbackBlock: some View {
        VStack(spacing: 10) {
            HStack(spacing: MovieDetailChrome.actionSpacing) {
                MovieFeedbackCircleButton(
                    icon: "hand.thumbsup.fill",
                    color: .green,
                    isSelected: feedback == .liked,
                    diameter: MovieDetailChrome.actionDiameter,
                    accessibilityLabel: feedback == .liked ? "Unlike" : "Like"
                ) { onLikeTap() }
                MovieFeedbackCircleButton(
                    icon: "hand.thumbsdown.fill",
                    color: .red,
                    isSelected: feedback == .disliked,
                    diameter: MovieDetailChrome.actionDiameter,
                    accessibilityLabel: feedback == .disliked ? "Remove dislike" : "Dislike"
                ) { onDislikeTap() }
                MovieFeedbackCircleButton(
                    icon: "bookmark.fill",
                    color: .blue,
                    isSelected: watchlistStore.contains(id: movie.id),
                    diameter: MovieDetailChrome.actionDiameter,
                    accessibilityLabel: watchlistStore.contains(id: movie.id) ? "Remove from Watchlist" : "Add to Watchlist"
                ) { onWatchlistTap() }
            }
            Text("Improve your picks")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: MovieDetailChrome.feedbackBlockMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func syncLocalState() {
        feedback = MovieFeedbackActions.resolvedFeedback(movieId: movie.id, engine: engine)
    }

    private func onLikeTap() {
        MovieFeedbackActions.onLikeTap(movie: movie, feedback: &feedback, engine: engine, detail: detail)
    }

    private func onDislikeTap() {
        MovieFeedbackActions.onDislikeTap(movie: movie, feedback: &feedback, engine: engine, detail: detail)
    }

    private func onWatchlistTap() {
        MovieFeedbackActions.onWatchlistTap(movie: movie, engine: engine, watchlistStore: watchlistStore, detail: detail)
    }

    private func loadDetail() async {
        loading = true
        detail = try? await TMDBService.shared.fetchMovieDetail(id: movie.id)
        loading = false
    }

    // MARK: - Where to Watch

    private func whereToWatchSection(_ providers: [TMDBMovieDetail.WatchProvider]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where to Watch")
                .font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(providers) { p in
                        VStack(spacing: 6) {
                            if let path = p.logoPath, let url = tmdbPosterURL(path, size: "w92") {
                                AsyncImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFit()
                                    } else { streamingPlaceholder(p.providerName) }
                                }
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                streamingPlaceholder(p.providerName)
                            }
                            Text(p.providerName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(width: 60)
                        }
                    }
                }
            }
        }
    }

    private func streamingPlaceholder(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.35))
            .frame(width: 50, height: 50)
            .overlay(Text(name.prefix(1)).font(.title3.bold()).foregroundColor(.white))
    }
}

#Preview {
    let json = """
    {"id":238,"title":"The Godfather","overview":"The aging patriarch of an organized crime dynasty transfers control to his reluctant son.",
    "vote_average":9.2,"vote_count":18000,"popularity":120.0,"genre_ids":[18,80],
    "release_date":"1972-03-24"}
    """
    Group {
        if let data = json.data(using: .utf8),
           let m = try? JSONDecoder().decode(TMDBMovie.self, from: data) {
            MovieDetailView(movie: m, engine: RecommendationEngine())
                .environmentObject(WatchlistStore.shared)
        } else {
            Text("Preview decode failed")
        }
    }
}

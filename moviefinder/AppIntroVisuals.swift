// AppIntroVisuals.swift
// Scaled in-app UI previews for the first-launch intro (TMDB posters + layout matched to real tabs).
// Optional: add images to Assets (`IntroWelcome`, etc.) to override mocks.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Visual kind

enum AppIntroVisualKind: String {
    case welcome
    case curate
    case watchNow
    case watchlist
    case archives
    case ready
}

// MARK: - Sample movies (poster paths from pickr_library_v1.db / TMDB)

struct IntroSampleMovie: Identifiable {
    let id: Int
    let title: String
    let year: String
    let posterPath: String
    let genreLabel: String
    let rating: Double
    let runtime: String

    var posterURL: URL? { tmdbPosterURL(posterPath, size: "w342") }
}

enum IntroSampleCatalog {
    static let conjuring = IntroSampleMovie(
        id: 138843, title: "The Conjuring", year: "2013",
        posterPath: "/wVYREutTvI2tmxr6ujrHT704wGF.jpg",
        genreLabel: "Horror", rating: 7.5, runtime: "1h 52m"
    )
    static let pastLives = IntroSampleMovie(
        id: 666277, title: "Past Lives", year: "2023",
        posterPath: "/k3waqVXSnvCZWfJYNtdamTgTtTA.jpg",
        genreLabel: "Romance", rating: 8.0, runtime: "1h 45m"
    )
    static let dune = IntroSampleMovie(
        id: 693134, title: "Dune: Part Two", year: "2024",
        posterPath: "/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg",
        genreLabel: "Sci-Fi", rating: 8.4, runtime: "2h 46m"
    )
    static let oppenheimer = IntroSampleMovie(
        id: 872585, title: "Oppenheimer", year: "2023",
        posterPath: "/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
        genreLabel: "Drama", rating: 8.9, runtime: "3h"
    )
    static let poorThings = IntroSampleMovie(
        id: 792307, title: "Poor Things", year: "2023",
        posterPath: "/kCGlIMHnOm8JPXq3rXM6c5wMxcT.jpg",
        genreLabel: "Fantasy", rating: 8.0, runtime: "2h 21m"
    )
    static let holdovers = IntroSampleMovie(
        id: 840430, title: "The Holdovers", year: "2023",
        posterPath: "/VHSzNBTwxV8vh7wylo7O9CLdac.jpg",
        genreLabel: "Comedy", rating: 7.9, runtime: "2h 13m"
    )

    static let curateStack: [IntroSampleMovie] = [dune, pastLives, conjuring]
    static let watchNowPicks: [IntroSampleMovie] = [conjuring, pastLives, dune]
    static let watchlistGrid: [IntroSampleMovie] = [oppenheimer, pastLives, poorThings, holdovers]
    static let archivesLiked: [IntroSampleMovie] = [oppenheimer, pastLives, dune]
}

// MARK: - Poster image

struct IntroPosterView: View {
    let movie: IntroSampleMovie
    var cornerRadius: CGFloat = 0

    var body: some View {
        Group {
            if let url = movie.posterURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        introPosterPlaceholder
                    }
                }
            } else {
                introPosterPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var introPosterPlaceholder: some View {
        Color.stablePlaceholderHue(for: movie.id, saturation: 0.45, brightness: 0.28)
    }
}

// MARK: - Uniform preview canvas (consistent size across intro pages)

private enum AppIntroPreviewMetrics {
    static let width: CGFloat = 286
    static let height: CGFloat = 300
    static let cornerRadius: CGFloat = 22
    static let insetH: CGFloat = 14
    static let insetV: CGFloat = 14
    /// Poster image height for 2-across Watchlist / Archives rows.
    static let posterRowHeight: CGFloat = 108
    /// Title block under Archives posters (Watchlist uses spacer to match).
    static let posterCaptionHeight: CGFloat = 32
}

/// Fixed-size background plate; content is centered inside.
private struct AppIntroMockCanvas<Content: View>: View {
    var background: Color
    @ViewBuilder var content: () -> Content

    init(
        background: Color = Color(.systemGroupedBackground),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.background = background
        self.content = content
    }

    var body: some View {
        ZStack {
            background
            content()
                .padding(.horizontal, AppIntroPreviewMetrics.insetH)
                .padding(.vertical, AppIntroPreviewMetrics.insetV)
        }
        .frame(width: AppIntroPreviewMetrics.width, height: AppIntroPreviewMetrics.height)
    }
}

// MARK: - Welcome hero (no card chrome — matches login / launch splash)

struct AppIntroWelcomeHero: View {
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(AppTheme.brand.opacity(0.12))
                    .frame(width: 104, height: 104)
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }
            Text("Welcome to Pickr")
                .font(AppTheme.titleLarge)
                .tracking(-0.4)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome to Pickr")
    }
}

// MARK: - Cropped UI frame (tab mocks — soft edge, no harsh stroke)

struct AppIntroPhonePreview<Content: View>: View {
    let content: Content

    init(maxHeight: CGFloat = AppIntroPreviewMetrics.height, @ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: AppIntroPreviewMetrics.width,
                height: AppIntroPreviewMetrics.height
            )
            .clipShape(
                RoundedRectangle(cornerRadius: AppIntroPreviewMetrics.cornerRadius, style: .continuous)
            )
            .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
            .padding(.horizontal, 4)
    }
}

// MARK: - Asset or mock

struct AppIntroScreenVisual: View {
    let kind: AppIntroVisualKind

    var body: some View {
        Group {
            if let asset = kind.assetImageName, introAssetExists(asset) {
                Image(asset)
                    .resizable()
                    .scaledToFill()
            } else {
                mock
            }
        }
    }

    @ViewBuilder
    private var mock: some View {
        Group {
            switch kind {
            case .welcome:
                AppIntroWelcomeHero()
            case .curate:   AppIntroCurateMock()
            case .watchNow: AppIntroWatchNowMock()
            case .watchlist: AppIntroWatchlistMock()
            case .archives: AppIntroArchivesMock()
            case .ready:    AppIntroReadyMock()
            }
        }
        .frame(width: AppIntroPreviewMetrics.width, height: AppIntroPreviewMetrics.height)
    }
}

private func introAssetExists(_ name: String) -> Bool {
    #if canImport(UIKit)
    return UIImage(named: name) != nil
    #else
    return false
    #endif
}

private extension AppIntroVisualKind {
    var assetImageName: String? {
        switch self {
        case .welcome:  return "IntroWelcome"
        case .curate:   return "IntroCurate"
        case .watchNow: return "IntroWatchNow"
        case .watchlist: return "IntroWatchlist"
        case .archives: return "IntroArchives"
        case .ready:    return "IntroReady"
        }
    }
}

// MARK: - Curate

private struct AppIntroCurateMock: View {
    private let stack = IntroSampleCatalog.curateStack

    var body: some View {
        AppIntroMockCanvas {
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                ZStack {
                    if stack.count > 1 {
                        introSwipeCard(movie: stack[0], scale: 0.90, offset: CGSize(width: -8, height: 10), opacity: 0.5)
                    }
                    if stack.count > 2 {
                        introSwipeCard(movie: stack[1], scale: 0.94, offset: CGSize(width: 6, height: 5), opacity: 0.72)
                    }
                    introSwipeCard(movie: stack[2], scale: 1, offset: .zero, opacity: 1, showLikeStamp: true)
                }
                .frame(height: 176)

                HStack(spacing: 12) {
                    introActionCircle(icon: "hand.thumbsdown.fill", color: .red)
                    introActionCircle(icon: "eye.slash", color: .orange)
                    introActionCircle(icon: "bookmark.fill", color: .blue)
                    introActionCircle(icon: "hand.thumbsup.fill", color: .green)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func introSwipeCard(
        movie: IntroSampleMovie,
        scale: CGFloat,
        offset: CGSize,
        opacity: Double,
        showLikeStamp: Bool = false
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            IntroPosterView(movie: movie, cornerRadius: 12)
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            if showLikeStamp {
                Text("LIKE")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.green.opacity(0.88))
                    .rotationEffect(.degrees(-12))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(movie.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(movie.year)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(8)
        }
        .frame(width: 114, height: 162)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
        .scaleEffect(scale)
        .offset(offset)
        .opacity(opacity)
    }

    private func introActionCircle(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.12))
            .clipShape(Circle())
            .overlay(Circle().stroke(color.opacity(0.28), lineWidth: 1))
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Watch Now

private struct AppIntroWatchNowMock: View {
    private let picks = IntroSampleCatalog.watchNowPicks
    private let platforms = ["Max", "Netflix", "Max"]
    private let platformColors: [Color] = [
        Color(red: 0.00, green: 0.17, blue: 0.90),
        Color(red: 0.90, green: 0.05, blue: 0.05),
        Color(red: 0.00, green: 0.17, blue: 0.90),
    ]

    var body: some View {
        AppIntroMockCanvas {
            VStack(alignment: .leading, spacing: 5) {
                introChipRow {
                    introChip("All Streamers", selected: true)
                    introChip("Netflix", selected: false, icon: "play.rectangle.fill", tint: .red)
                    introChip("Max", selected: false, icon: "bolt.fill", tint: Color(red: 0, green: 0.17, blue: 0.9))
                }
                introChipRow {
                    introChip("Any Genre", selected: true)
                    introChip("Horror", selected: false, tint: AppTheme.filterAccent)
                    introChip("Sci-Fi", selected: false)
                }
                introChipRow {
                    introChip("Any Length", selected: true)
                    introChip("Under 90m", selected: false, icon: "clock")
                    introChip("Under 2h", selected: false, icon: "clock")
                }

                VStack(spacing: 5) {
                    ForEach(Array(picks.enumerated()), id: \.offset) { index, movie in
                        introPickRow(
                            movie: movie,
                            rank: index + 1,
                            platform: platforms[index],
                            platformColor: platformColors[index]
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func introChipRow(@ViewBuilder chips: () -> some View) -> some View {
        HStack(spacing: 5) { chips() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func introChip(_ text: String, selected: Bool, icon: String? = nil, tint: Color = AppTheme.filterAccent) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? .white : .primary.opacity(0.75))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(selected ? tint : Color.primary.opacity(0.07))
        .clipShape(Capsule())
    }

    private func introPickRow(movie: IntroSampleMovie, rank: Int, platform: String, platformColor: Color) -> some View {
        HStack(spacing: 0) {
            IntroPosterView(movie: movie, cornerRadius: 6)
                .frame(width: 32, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(movie.title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(rank)")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color(white: 0.32))
                }
                .padding(.bottom, 3)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 7))
                    Text(movie.runtime)
                        .font(.system(size: 7, weight: .medium))
                    Text(platform)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(platformColor.opacity(0.55))
                        .clipShape(Capsule())
                }
                .foregroundStyle(Color(white: 0.62))
                .padding(.bottom, 4)

                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", movie.rating))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(movie.genreLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color(white: 0.62))
                    Spacer(minLength: 2)
                    HStack(spacing: 3) {
                        introMiniFeedback("hand.thumbsup.fill", .green)
                        introMiniFeedback("hand.thumbsdown.fill", .red)
                        introMiniFeedback("bookmark.fill", .blue)
                    }
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
        }
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func introMiniFeedback(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 6, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
            .background(color.opacity(0.12))
            .clipShape(Circle())
    }
}

// MARK: - Watchlist

private struct AppIntroWatchlistMock: View {
    private let movies = [IntroSampleCatalog.oppenheimer, IntroSampleCatalog.pastLives]

    var body: some View {
        AppIntroMockCanvas {
            VStack {
                Spacer(minLength: 0)
                IntroTwoPosterRow(movies: movies, style: .watchlist)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Archives

private struct AppIntroArchivesMock: View {
    private let likedPosters = [IntroSampleCatalog.oppenheimer, IntroSampleCatalog.pastLives]

    var body: some View {
        AppIntroMockCanvas {
            VStack(alignment: .leading, spacing: 10) {
                Spacer(minLength: 0)
                introArchivesSegmentPicker
                introArchivesSearchBar
                IntroTwoPosterRow(movies: likedPosters, style: .archives)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var introArchivesSegmentPicker: some View {
        HStack(spacing: 0) {
            introArchivesSegment(
                title: "Liked",
                icon: "hand.thumbsup.fill",
                count: 3,
                selected: true
            )
            introArchivesSegment(
                title: "Disliked",
                icon: "hand.thumbsdown.fill",
                count: 0,
                selected: false
            )
        }
        .padding(3)
        .background(Color(.tertiarySystemFill).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func introArchivesSegment(title: String, icon: String, count: Int, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 8, weight: .bold))
                .monospacedDigit()
                .opacity(0.6)
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color(.secondarySystemGroupedBackground) : Color.clear)
                .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 2, x: 0, y: 1)
        )
    }

    private var introArchivesSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Search liked films")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Shared two-poster row (Watchlist + Archives)

private enum IntroTwoPosterRowStyle {
    case watchlist
    case archives
}

private struct IntroTwoPosterRow: View {
    let movies: [IntroSampleMovie]
    let style: IntroTwoPosterRowStyle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(movies) { movie in
                IntroPosterTile(movie: movie, style: style)
            }
        }
    }
}

private struct IntroPosterTile: View {
    let movie: IntroSampleMovie
    let style: IntroTwoPosterRowStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                IntroPosterView(movie: movie, cornerRadius: 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: AppIntroPreviewMetrics.posterRowHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                switch style {
                case .watchlist:
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                        .padding(6)
                case .archives:
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", movie.rating))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(5)
                }
            }
            Group {
                if style == .archives {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(movie.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(movie.year)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(height: AppIntroPreviewMetrics.posterCaptionHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(style == .watchlist ? 0.12 : 0.08), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Ready

private struct AppIntroReadyMock: View {
    var body: some View {
        AppIntroMockCanvas(background: Color(.systemGroupedBackground)) {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(AppTheme.starGold)
                Text("You’re ready")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

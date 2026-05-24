// AppIntroVisuals.swift
// Premium intro previews — dark UI, TMDB posters, minimal chrome.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Design system

enum IntroDesign {
    static let canvas = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let mockBG = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let rowBG = Color(red: 0.15, green: 0.15, blue: 0.17)

    static let textSecondary = Color.white.opacity(0.62)
    static let textBody = Color.white.opacity(0.70)

    static let watchNowAccent = Color(red: 0.30, green: 0.76, blue: 0.64)
    static let watchlistAccent = Color(red: 0.40, green: 0.58, blue: 0.98)
    static let archivesAccent = Color(red: 0.70, green: 0.50, blue: 0.90)

    static let pagePadding: CGFloat = 28
    static let previewToCopy: CGFloat = 24
    static let listSpacing: CGFloat = 13

    static let previewWidth: CGFloat = 300
    static let previewHeight: CGFloat = 336
    static let cornerRadius: CGFloat = 24
    static let inset: CGFloat = 16

    enum Fonts {
        static let kicker = Font.system(size: 11, weight: .semibold)
        static let title = Font.system(size: 24, weight: .bold)
        static let intro = Font.system(size: 15, weight: .regular)
        static let body = Font.system(size: 15, weight: .regular)
        static let listMarker = Font.system(size: 15, weight: .semibold)
        static let button = Font.system(size: 17, weight: .semibold)
    }
}

// MARK: - Visual kind

enum AppIntroVisualKind: String {
    case welcome, curate, watchNow, watchlist, archives, ready
}

// MARK: - Sample data

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
    static let curateStack = [dune, pastLives, conjuring]
    static let watchNowPicks = [conjuring, pastLives, dune]
}

// MARK: - Poster

struct IntroPosterView: View {
    let movie: IntroSampleMovie
    var cornerRadius: CGFloat = 0

    var body: some View {
        Group {
            if let url = movie.posterURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Color.stablePlaceholderHue(for: movie.id, saturation: 0.45, brightness: 0.28)
    }
}

// MARK: - Device frame

struct IntroDeviceFrame<Content: View>: View {
    var accent: Color = AppTheme.brand
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: IntroDesign.previewWidth, height: IntroDesign.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: IntroDesign.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: IntroDesign.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
            .shadow(color: accent.opacity(0.12), radius: 32, y: 8)
    }
}

// MARK: - Router

struct AppIntroScreenVisual: View {
    let kind: AppIntroVisualKind

    private var accent: Color {
        switch kind {
        case .welcome, .curate: AppTheme.brand
        case .watchNow: IntroDesign.watchNowAccent
        case .watchlist: IntroDesign.watchlistAccent
        case .archives: IntroDesign.archivesAccent
        case .ready: AppTheme.starGold
        }
    }

    var body: some View {
        IntroDeviceFrame(accent: accent) {
            ZStack {
                IntroDesign.mockBG
                mock.padding(IntroDesign.inset)
            }
        }
    }

    @ViewBuilder
    private var mock: some View {
        switch kind {
        case .welcome: IntroWelcomeMock()
        case .curate: IntroCurateMock()
        case .watchNow: IntroWatchNowMock()
        case .watchlist: IntroWatchlistMock()
        case .archives: IntroArchivesMock()
        case .ready: IntroReadyMock()
        }
    }
}

// MARK: - Welcome hero (full page)

struct AppIntroWelcomeHero: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.brand.opacity(0.10))
                    .frame(width: 100, height: 100)
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }

            VStack(spacing: 6) {
                Text("Welcome to Pickr")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                Text("Stream Smarter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IntroDesign.textSecondary)
                    .tracking(0.25)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IntroWelcomeMock: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(AppTheme.brand)
            Text("Pickr")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Curate

private struct IntroCurateMock: View {
    private let stack = IntroSampleCatalog.curateStack

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            ZStack {
                if stack.count > 1 {
                    card(stack[0], scale: 0.9, offset: CGSize(width: -12, height: 10), opacity: 0.4)
                }
                if stack.count > 2 {
                    card(stack[1], scale: 0.95, offset: CGSize(width: 10, height: 5), opacity: 0.65)
                }
                card(stack[2], showLike: true)
            }
            .frame(height: 228)

            HStack(spacing: 16) {
                action("hand.thumbsdown.fill", .red)
                action("eye.slash", .orange)
                action("bookmark.fill", IntroDesign.watchlistAccent)
                action("hand.thumbsup.fill", .green)
            }
            Spacer(minLength: 0)
        }
    }

    private func card(
        _ movie: IntroSampleMovie,
        scale: CGFloat = 1,
        offset: CGSize = .zero,
        opacity: Double = 1,
        showLike: Bool = false
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            IntroPosterView(movie: movie, cornerRadius: 16)
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            if showLike {
                Text("LIKE")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.green.opacity(0.88))
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(movie.year)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(12)
        }
        .frame(width: 142, height: 204)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .scaleEffect(scale)
        .offset(offset)
        .opacity(opacity)
    }

    private func action(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(color.opacity(0.12))
            .clipShape(Circle())
    }
}

// MARK: - Watch Now

private struct IntroWatchNowMock: View {
    private let picks = IntroSampleCatalog.watchNowPicks

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipRow {
                chip("All Streamers", on: true, fill: AppTheme.brand)
                chip("Netflix", icon: "play.rectangle.fill")
                chip("Max", icon: "bolt.fill")
            }
            chipRow {
                chip("Any Genre", on: true, fill: AppTheme.filterAccent)
                chip("Horror")
                chip("Sci-Fi")
            }
            chipRow {
                chip("Any Length", on: true, fill: AppTheme.brand)
                chip("Under 2h", icon: "clock")
            }

            VStack(spacing: 5) {
                row(picks[0], 1, "Max", Color(red: 0, green: 0.17, blue: 0.9))
                row(picks[1], 2, "Netflix", Color(red: 0.9, green: 0.05, blue: 0.05))
                row(picks[2], 3, "Max", Color(red: 0, green: 0.17, blue: 0.9))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chipRow(@ViewBuilder content: () -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) { content() }
        }
    }

    private func chip(_ title: String, on: Bool = false, icon: String? = nil, fill: Color = AppTheme.brand) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            }
            Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(on ? .white : .white.opacity(0.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(on ? fill : Color.white.opacity(0.07))
        .clipShape(Capsule())
    }

    private func row(_ movie: IntroSampleMovie, _ rank: Int, _ platform: String, _ platformColor: Color) -> some View {
        HStack(spacing: 0) {
            IntroPosterView(movie: movie, cornerRadius: 6)
                .frame(width: 34, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(movie.title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(rank)")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.2))
                }
                HStack(spacing: 3) {
                    Text(movie.runtime).font(.system(size: 8))
                    Text(platform)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(platformColor.opacity(0.6))
                        .clipShape(Capsule())
                }
                .foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(AppTheme.starGold)
                    Text(String(format: "%.1f", movie.rating)).font(.system(size: 8, weight: .semibold))
                    Text(movie.genreLabel).font(.system(size: 8)).foregroundStyle(.white.opacity(0.45))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IntroDesign.rowBG))
    }
}

// MARK: - Watchlist

private struct IntroWatchlistMock: View {
    private let movies = [IntroSampleCatalog.oppenheimer, IntroSampleCatalog.pastLives]

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                ForEach(movies) { movie in
                    ZStack(alignment: .topTrailing) {
                        IntroPosterView(movie: movie, cornerRadius: 14)
                            .frame(height: 152)
                            .frame(maxWidth: .infinity)
                            .clipped()
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IntroDesign.watchlistAccent)
                            .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Archives

private struct IntroArchivesMock: View {
    private let movies = [IntroSampleCatalog.oppenheimer, IntroSampleCatalog.pastLives]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 0) {
                seg("Liked", "hand.thumbsup.fill", true)
                seg("Disliked", "hand.thumbsdown.fill", false)
            }
            .padding(3)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Search liked films")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            HStack(alignment: .top, spacing: 12) {
                ForEach(movies) { movie in
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .topTrailing) {
                            IntroPosterView(movie: movie, cornerRadius: 12)
                                .frame(height: 118)
                                .frame(maxWidth: .infinity)
                            ratingBadge(movie.rating)
                                .padding(5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(movie.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                        Text(movie.year)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func seg(_ title: String, _ icon: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(title).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(on ? .white : .white.opacity(0.4))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(on ? IntroDesign.archivesAccent.opacity(0.32) : .clear)
        )
    }

    private func ratingBadge(_ rating: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(AppTheme.starGold)
            Text(String(format: "%.1f", rating)).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.5))
        .clipShape(Capsule())
    }
}

// MARK: - Ready

private struct IntroReadyMock: View {
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .stroke(AppTheme.starGold.opacity(0.2), lineWidth: 1)
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(AppTheme.starGold.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(AppTheme.starGold)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

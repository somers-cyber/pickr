// SwipeCardView.swift
// Swipe card stack UI — works with both sample data and live TMDBMovie data

import SwiftUI

// MARK: - Movie (local display model)

struct Movie: Identifiable {
    let id         = UUID()
    let title:       String
    let year:        String
    let genre:       [String]
    let rating:      Double
    let overview:    String
    let posterColor: Color       // placeholder until real poster loads
    let posterURL:   URL?        // nil for sample data

    // Convenience init for sample/preview data (no URL)
    init(title: String, year: String, genre: [String],
         rating: Double, overview: String, posterColor: Color) {
        self.title       = title
        self.year        = year
        self.genre       = genre
        self.rating      = rating
        self.overview    = overview
        self.posterColor = posterColor
        self.posterURL   = nil
    }

    // Full init for live data
    init(title: String, year: String, genre: [String],
         rating: Double, overview: String, posterColor: Color, posterURL: URL?) {
        self.title       = title
        self.year        = year
        self.genre       = genre
        self.rating      = rating
        self.overview    = overview
        self.posterColor = posterColor
        self.posterURL   = posterURL
    }
}

// MARK: - Swipe Direction

enum SwipeDirection: Equatable {
    case like       // swipe right
    case skip       // swipe left
    case strongSkip // long-press dislike — stronger negative signal
    case watchlist  // swipe up
    case didNotSee  // explicit "not seen" button
    case none
}

// MARK: - Movie Card

struct MovieCard: View {
    let movie:       Movie
    let dragOffset:  CGSize
    let isTopCard:   Bool
    /// Defaults preserve the original 340×520 layout (e.g. previews).
    var width:  CGFloat = 340
    var height: CGFloat = 520

    private var cornerRadius: CGFloat { width * (20.0 / 340.0) }
    private var sizeScale: CGFloat { width / 340.0 }

    private var rotation: Double {
        isTopCard ? Double(dragOffset.width / 20) : 0
    }
    private var likeOpacity: Double {
        isTopCard ? Double(max(0, min(1, dragOffset.width / 80))) : 0
    }
    private var skipOpacity: Double {
        // Left swipe = dislike
        isTopCard ? Double(max(0, min(1, -dragOffset.width / 80))) : 0
    }
    private var didNotSeeOpacity: Double {
        // Down swipe = skip (unseen titles)
        isTopCard ? Double(max(0, min(1, dragOffset.height / 80))) : 0
    }
    private var watchlistOpacity: Double {
        isTopCard ? Double(max(0, min(1, -dragOffset.height / 80))) : 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Poster background
            posterBackground

            // Swipe indicators
            swipeIndicators

            // Info overlay
            infoOverlay
        }
        .frame(width: width, height: height)
        .rotationEffect(.degrees(rotation))
        .offset(x: dragOffset.width, y: dragOffset.height * 0.4)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
        .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 6)
    }

    // MARK: Sub-views

    @ViewBuilder
    private var posterBackground: some View {
        if let url = movie.posterURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                default:
                    posterColorFill
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .center, endPoint: .bottom))
            )
        } else {
            posterColorFill
        }
    }

    private var posterColorFill: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(movie.posterColor)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .center, endPoint: .bottom))
            )
    }

    private var swipeIndicators: some View {
        ZStack {
            // LIKE
            Label("LIKE", systemImage: "hand.thumbsup.fill")
                .font(.system(size: 26 * sizeScale, weight: .black))
                .foregroundColor(.green)
                .padding(10 * sizeScale)
                .overlay(RoundedRectangle(cornerRadius: 8 * sizeScale).stroke(Color.green, lineWidth: 3))
                .rotationEffect(.degrees(-18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24 * sizeScale)
                .opacity(likeOpacity)

            // DISLIKE (left swipe)
            Label("DISLIKE", systemImage: "hand.thumbsdown.fill")
                .font(.system(size: 26 * sizeScale, weight: .black))
                .foregroundColor(.red)
                .padding(10 * sizeScale)
                .overlay(RoundedRectangle(cornerRadius: 8 * sizeScale).stroke(Color.red, lineWidth: 3))
                .rotationEffect(.degrees(18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(24 * sizeScale)
                .opacity(skipOpacity)

            // SKIP (down swipe — unseen titles)
            Label("SKIP", systemImage: "eye.slash.fill")
                .font(.system(size: 22 * sizeScale, weight: .black))
                .foregroundColor(.orange)
                .padding(10 * sizeScale)
                .overlay(RoundedRectangle(cornerRadius: 8 * sizeScale).stroke(Color.orange, lineWidth: 3))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 24 * sizeScale)
                .opacity(didNotSeeOpacity)

            // WATCHLIST
            Label("Watchlist", systemImage: "bookmark.fill")
                .font(.system(size: 20 * sizeScale, weight: .black))
                .foregroundColor(.blue)
                .padding(10 * sizeScale)
                .overlay(RoundedRectangle(cornerRadius: 8 * sizeScale).stroke(Color.blue, lineWidth: 3))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 24 * sizeScale)
                .opacity(watchlistOpacity)
        }
    }

    private var infoOverlay: some View {
        VStack(alignment: .leading, spacing: 8 * sizeScale) {
            HStack {
                Text(movie.title)
                    .font(.system(size: 24 * sizeScale, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 11 * sizeScale))
                    Text(String(format: "%.1f", movie.rating))
                        .foregroundColor(.white)
                        .font(.system(size: 15 * sizeScale, weight: .semibold))
                }
            }

            Text(movie.year)
                .foregroundColor(.white.opacity(0.7))
                .font(.system(size: 15 * sizeScale))

            if !movie.genre.isEmpty {
                HStack(spacing: 6) {
                    ForEach(movie.genre.prefix(3), id: \.self) { g in
                        Text(g)
                            .font(.system(size: 12 * sizeScale, weight: .medium))
                            .padding(.horizontal, 10 * sizeScale)
                            .padding(.vertical, 4 * sizeScale)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                    }
                }
            }

            if !movie.overview.isEmpty {
                Text(movie.overview)
                    .font(.system(size: 13 * sizeScale))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(20 * sizeScale)
    }
}

// MARK: - Circle Button

struct CircleButton: View {
    let icon:   String
    let color:  Color
    let action: () -> Void
    /// Default 60pt matches the original Discover control size.
    var diameter: CGFloat = 60

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundColor(color)
                .frame(width: diameter, height: diameter)
                .background(color.opacity(0.12))
                .clipShape(Circle())
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: max(1, diameter * 0.028)))
        }
    }
}

// MARK: - Sample Data (used in previews only)

let sampleMovies: [Movie] = [
    Movie(title: "Oppenheimer",       year: "2023", genre: ["Drama", "History"],
          rating: 8.9, overview: "The story of J. Robert Oppenheimer and the development of the atomic bomb.",
          posterColor: Color(red: 0.55, green: 0.27, blue: 0.07)),
    Movie(title: "Past Lives",        year: "2023", genre: ["Romance", "Drama"],
          rating: 8.0, overview: "Two childhood friends reconnect years later, confronting their past.",
          posterColor: Color(red: 0.18, green: 0.38, blue: 0.58)),
    Movie(title: "Dune: Part Two",    year: "2024", genre: ["Sci-Fi", "Adventure"],
          rating: 8.7, overview: "Paul Atreides unites with the Fremen to seek revenge.",
          posterColor: Color(red: 0.65, green: 0.48, blue: 0.18)),
    Movie(title: "Poor Things",       year: "2023", genre: ["Fantasy", "Comedy"],
          rating: 8.0, overview: "A young woman brought back to life sets off on adventures across Europe.",
          posterColor: Color(red: 0.48, green: 0.18, blue: 0.48)),
    Movie(title: "The Holdovers",     year: "2023", genre: ["Comedy", "Drama"],
          rating: 7.9, overview: "A curmudgeonly teacher must remain on campus over the holidays with a troubled student.",
          posterColor: Color(red: 0.28, green: 0.45, blue: 0.28)),
]

// MARK: - Preview

#Preview {
    SwipeCardStackPreview()
}

private struct SwipeCardStackPreview: View {
    @State private var movies = sampleMovies
    @State private var drag: CGSize = .zero

    var body: some View {
        VStack {
            ZStack {
                ForEach(Array(movies.prefix(3).enumerated().reversed()), id: \.element.id) { i, m in
                    MovieCard(movie: m, dragOffset: i == 0 ? drag : .zero, isTopCard: i == 0)
                        .scaleEffect(i == 0 ? 1 : i == 1 ? 0.95 : 0.90)
                        .offset(y: i == 0 ? 0 : CGFloat(i) * 10)
                        .zIndex(Double(10 - i))
                }
            }
            HStack(spacing: 40) {
                CircleButton(icon: "xmark",              color: .red)   { movies.removeFirst() }
                CircleButton(icon: "eye.slash",          color: .orange){ movies.removeFirst() }
                CircleButton(icon: "bookmark.fill",      color: .blue)  { movies.removeFirst() }
                CircleButton(icon: "hand.thumbsup.fill", color: .green) { movies.removeFirst() }
            }
            .padding(.top, 20)
        }
    }
}

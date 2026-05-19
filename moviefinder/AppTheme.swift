// AppTheme.swift
// Shared accent + elevation — one place to tweak or revert the “premium” pass.

import SwiftUI
import UIKit

enum AppTheme {
    /// Tab bar, prominent buttons, system tint
    static let brand = Color(red: 0.86, green: 0.20, blue: 0.17)
    /// Filters, chips, genre “like” emphasis (warm, single family)
    static let filterAccent = Color(red: 0.92, green: 0.38, blue: 0.16)
    /// Genre row “like” highlight (amber, not a second rainbow)
    static let genreLikeHighlight = Color(red: 0.95, green: 0.58, blue: 0.12)

    static let cardShadowColor = Color.black.opacity(0.14)
    static let cardShadowRadius: CGFloat = 14
    static let cardShadowY: CGFloat = 6

    static let chromeIconShadow = Color.black.opacity(0.07)

    /// Two-column poster grids (Watchlist, Archives): `LazyVGrid` `spacing` is **row** only; inter-column gap uses `GridItem.spacing`.
    enum PosterGrid {
        static let columnSpacing: CGFloat = 14
        static let rowSpacing: CGFloat = 18
        static var columns: [GridItem] {
            [GridItem(.flexible(), spacing: columnSpacing), GridItem(.flexible())]
        }
    }

    /// Gold tone for rating / strength stars (reads “designed,” not default emoji yellow).
    static let starGold = Color(red: 0.88, green: 0.72, blue: 0.22)

    // MARK: - Typography (SF Pro default — avoids SF Rounded / “playful” UI look)

    static let titleLarge = Font.system(size: 28, weight: .bold, design: .default)
    static let titleCard = Font.system(size: 16, weight: .bold, design: .default)
    static let rankIndex = Font.system(size: 22, weight: .heavy, design: .default)
    static let rowTitle = Font.system(size: 17, weight: .semibold, design: .default)

    /// Forces navigation bar titles to **SF Pro** (not Rounded) for a stronger editorial feel.
    static func configureNavigationBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        nav.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactScrollEdgeAppearance = nav
    }
}

// MARK: - Poster grid (Watchlist + Archives)

extension View {
    /// `LazyVGrid` row height follows the tallest cell; shorter cells are vertically centered by default, which misaligns posters. Pin content to the **top** so titles can differ in line count without shifting artwork.
    func posterGridCellTopAligned() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

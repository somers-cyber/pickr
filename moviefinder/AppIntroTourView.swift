// AppIntroTourView.swift
// First-launch walkthrough — clean, premium, matches login / launch.

import SwiftUI

// MARK: - Storage

enum AppIntroStorage {
    static let completeKey = "app_intro_complete"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: completeKey)
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: completeKey)
    }

    static func resetForDebug() {
        UserDefaults.standard.set(false, forKey: completeKey)
    }
}

// MARK: - Tour

struct AppIntroTourView: View {
    var onComplete: () -> Void

    @State private var page = 0
    private let pages = AppIntroPage.all

    var body: some View {
        ZStack {
            IntroDesign.canvas.ignoresSafeArea()

            RadialGradient(
                colors: [AppTheme.brand.opacity(0.12), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 300
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, introPage in
                        AppIntroPageView(page: introPage)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: page)

                footerChrome
            }
        }
    }

    private var headerBar: some View {
        HStack {
            if page > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { page -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer()

            if page == 0 {
                Button("Skip", action: finish)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var footerChrome: some View {
        VStack(spacing: 20) {
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.white : Color.white.opacity(0.2))
                        .frame(width: index == page ? 20 : 5, height: 5)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: page)
            .accessibilityLabel("Page \(page + 1) of \(pages.count)")

            Button(action: advance) {
                Text(page == pages.count - 1 ? "Get Started" : "Next")
                    .font(IntroDesign.Fonts.button)
                    .foregroundStyle(page == pages.count - 1 ? .white : .black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(page == pages.count - 1 ? AppTheme.brand : .white)
                    )
                    .shadow(
                        color: (page == pages.count - 1 ? AppTheme.brand : .black).opacity(0.25),
                        radius: 12,
                        y: 5
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, IntroDesign.pagePadding)
        .padding(.bottom, 24)
    }

    private func advance() {
        if page < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        onComplete()
    }
}

// MARK: - Page data

private enum AppIntroListStyle {
    case bullet
    case numbered
}

private struct AppIntroPage: Identifiable {
    let id: String
    let kicker: String
    let visual: AppIntroVisualKind
    let title: String
    let accent: Color
    var isWelcome = false
    var introLines: [String] = []
    var listStyle: AppIntroListStyle = .bullet
    let lines: [String]

    static let all: [AppIntroPage] = [
        AppIntroPage(
            id: "welcome",
            kicker: "",
            visual: .welcome,
            title: "Welcome to Pickr",
            accent: AppTheme.brand,
            isWelcome: true,
            introLines: ["Learn your taste. Three picks, fast."],
            lines: []
        ),
        AppIntroPage(
            id: "curate",
            kicker: "SWIPE & TRAIN",
            visual: .curate,
            title: "Curate",
            accent: AppTheme.brand,
            introLines: ["Curate is where you teach Pickr your taste."],
            lines: [
                "Like — more like this.",
                "Dislike — less like this.",
                "Watchlist — save for later.",
                "Skip — doesn't change your taste."
            ]
        ),
        AppIntroPage(
            id: "watchnow",
            kicker: "TONIGHT'S PICKS",
            visual: .watchNow,
            title: "Watch Now",
            accent: IntroDesign.watchNowAccent,
            introLines: [
                "Three picks, fast.",
                "Filter by streamer, genre, and runtime."
            ],
            lines: [
                "Review or add to Watchlist",
                "Tap the movie poster for more details",
                "\"Something else\" shuffles your picks — change filters for fresh options."
            ]
        ),
        AppIntroPage(
            id: "watchlist",
            kicker: "SAVE FOR LATER",
            visual: .watchlist,
            title: "Watchlist",
            accent: IntroDesign.watchlistAccent,
            introLines: ["Movies you saved for later."],
            lines: [
                "Save from Curate or any movie card.",
                "Like or Dislike after you watch — it goes to Archives.",
                "Tap the bookmark again to remove."
            ]
        ),
        AppIntroPage(
            id: "archives",
            kicker: "YOUR HISTORY",
            visual: .archives,
            title: "Archives",
            accent: IntroDesign.archivesAccent,
            introLines: ["Your liked and disliked movies."],
            lines: [
                "Liked and Disliked tabs at the top.",
                "Tap a poster for details.",
                "Search by title or filter by genre and decade."
            ]
        ),
        AppIntroPage(
            id: "ready",
            kicker: "FINAL STEPS",
            visual: .ready,
            title: "You're ready",
            accent: AppTheme.starGold,
            listStyle: .numbered,
            lines: [
                "Set your genres.",
                "Tap i on any tab for tips.",
                "Do 10+ swipes on Curate.",
                "Open Watch Now for tonight's three picks."
            ]
        ),
    ]
}

// MARK: - Page

private struct AppIntroPageView: View {
    let page: AppIntroPage

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if page.isWelcome {
                    welcomeContent
                } else {
                    tabContent
                }
            }
            .padding(.horizontal, IntroDesign.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Welcome

    private var welcomeContent: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 20)

            AppIntroWelcomeHero()

            Text(page.introLines.first ?? "")
                .font(IntroDesign.Fonts.intro)
                .foregroundStyle(IntroDesign.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .padding(.horizontal, 16)

            Spacer(minLength: 20)
        }
    }

    // MARK: Tab pages

    private var tabContent: some View {
        VStack(spacing: IntroDesign.previewToCopy) {
            AppIntroScreenVisual(kind: page.visual)
                .frame(maxWidth: .infinity)

            copyContent
        }
    }

    private var copyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !page.kicker.isEmpty {
                Text(page.kicker)
                    .font(IntroDesign.Fonts.kicker)
                    .tracking(1.2)
                    .foregroundStyle(page.accent)
            }

            Text(page.title)
                .font(IntroDesign.Fonts.title)
                .tracking(-0.4)
                .foregroundStyle(.white)
                .padding(.top, page.kicker.isEmpty ? 0 : 8)

            Capsule()
                .fill(page.accent.opacity(0.85))
                .frame(width: 28, height: 2)
                .padding(.top, 10)
                .padding(.bottom, 16)

            if !page.introLines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(page.introLines, id: \.self) { line in
                        Text(line)
                            .font(IntroDesign.Fonts.intro)
                            .foregroundStyle(IntroDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, page.lines.isEmpty ? 0 : 20)
            }

            if !page.lines.isEmpty {
                VStack(alignment: .leading, spacing: IntroDesign.listSpacing) {
                    ForEach(Array(page.lines.enumerated()), id: \.offset) { index, line in
                        listRow(index: index, text: line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            switch page.listStyle {
            case .bullet:
                Circle()
                    .fill(page.accent)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
            case .numbered:
                Text("\(index + 1).")
                    .font(IntroDesign.Fonts.listMarker)
                    .foregroundStyle(page.accent)
                    .frame(width: 20, alignment: .leading)
            }

            Text(text)
                .font(IntroDesign.Fonts.body)
                .foregroundStyle(IntroDesign.textBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    AppIntroTourView(onComplete: {})
}

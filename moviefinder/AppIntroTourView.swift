// AppIntroTourView.swift
// First-launch walkthrough: in-app UI previews + practical copy for each tab.
// Per-tab coaches (Curate swipe guide, Watch Now info) still run on those screens.

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
            AppIntroTourStyle.background
                .ignoresSafeArea()

            AppIntroTourStyle.topGlow
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, introPage in
                        AppIntroPageView(page: introPage)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.28), value: page)

                footerCTA
            }
        }
    }

    private var headerBar: some View {
        HStack {
            if page > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.28)) { page -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer()

            if page == 0 {
                Button("Skip") { finish() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.40))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footerCTA: some View {
        VStack(spacing: 14) {
            Button(action: advance) {
                Text(page == pages.count - 1 ? "Get Started" : "Next")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page == pages.count - 1 ? "Get Started" : "Next page")
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 44)
        .padding(.top, 4)
    }

    private func advance() {
        if page < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        onComplete()
    }
}

// MARK: - Page model

private enum AppIntroListStyle {
    case bullet
    case numbered
}

/// How the top of an intro page is presented.
private enum AppIntroPreviewPresentation {
    /// Logo + title on the tour background (Welcome).
    case brandHero
    /// Rounded UI mock in a soft shadow frame (tab walkthrough).
    case framedMock
}

private struct AppIntroPage: Identifiable {
    let id: String
    let visual: AppIntroVisualKind
    let title: String
    let accent: Color
    var presentation: AppIntroPreviewPresentation = .framedMock
    /// Optional lead paragraph (no bullet), shown above `lines`.
    var introLine: String? = nil
    var listStyle: AppIntroListStyle = .bullet
    /// When false, title is shown only in the preview (e.g. Welcome).
    var showsTitleBelowPreview: Bool = true
    let lines: [String]

    static let all: [AppIntroPage] = [
        AppIntroPage(
            id: "welcome",
            visual: .welcome,
            title: "Welcome to Pickr",
            accent: AppTheme.brand,
            presentation: .brandHero,
            introLine: "Pickr learns what you like, then helps you choose — no more endless browsing.",
            showsTitleBelowPreview: false,
            lines: []
        ),
        AppIntroPage(
            id: "curate",
            visual: .curate,
            title: "Curate",
            accent: AppTheme.brand,
            introLine: "Curate is where you teach Pickr your taste. What you swipe shapes Watch Now and Archives.",
            lines: [
                "Like — you enjoyed it, Pickr surfaces more like it.",
                "Dislike — not for you, Pickr dials back similar titles.",
                "Watchlist — save for later, then Like or Dislike after watching.",
                "Did Not See — you haven't watched it; Pickr won't update your taste."
            ]
        ),
        AppIntroPage(
            id: "watchnow",
            visual: .watchNow,
            title: "Watch Now",
            accent: Color(red: 0.35, green: 0.55, blue: 0.95),
            introLine: "Three picks fast — filter with streamers, genre, and runtime.",
            lines: [
                "Review or add to Watchlist on each movie card; tap the movie poster for more details.",
                "\"Something else\" shuffles based on your filters, but after a few, picks will repeat. Change filters or review more for fresh options."
            ]
        ),
        AppIntroPage(
            id: "watchlist",
            visual: .watchlist,
            title: "Watchlist",
            accent: .blue,
            introLine: "Your saved for later list — bookmark movies then review them when you're ready.",
            lines: [
                "Add from Curate (swipe up) or tap the bookmark on any movie card.",
                "After you watch, review it from Watchlist — Like or Dislike saves to Archives.",
                "Tap the bookmark again to remove it from your list."
            ]
        ),
        AppIntroPage(
            id: "archives",
            visual: .archives,
            title: "Archives",
            accent: Color(white: 0.72),
            introLine: "Every Like and Dislike is saved here — your archive of movies you've reviewed.",
            lines: [
                "Switch between Liked and Disliked at the top; tap a poster for the full movie page.",
                "Search by title, or tap Filter to sort and narrow by genre or decade."
            ]
        ),
        AppIntroPage(
            id: "ready",
            visual: .ready,
            title: "You’re ready",
            accent: AppTheme.starGold,
            listStyle: .numbered,
            lines: [
                "Set your genres.",
                "Each tab shows tips on first use — tap i (top right) for more.",
                "Do at least 10 swipes on Curate; more is better.",
                "Open Watch Now when you want tonight’s three picks."
            ]
        ),
    ]
}

// MARK: - Page view

private enum AppIntroPageLayout {
    /// Space above the TabView page indicator dots (inside the scroll content).
    static let pageIndicatorInset: CGFloat = 52
}

private enum AppIntroCopyStyle {
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyColor = Color.white.opacity(0.72)
    static let sectionTitle = Font.system(size: 24, weight: .bold)
    static let heroTagline = Font.system(size: 16, weight: .regular)
    static let heroTaglineColor = Color.white.opacity(0.72)
}

private struct AppIntroPageView: View {
    let page: AppIntroPage
    @State private var appeared = false

    /// Slightly shrink preview on copy-heavy pages so text fits above the page dots.
    private var previewScale: CGFloat {
        let copyLines = page.lines.count + (page.introLine != nil ? 1 : 0)
        if copyLines >= 5 { return 0.86 }
        if copyLines >= 4 { return 0.90 }
        return 1
    }

    var body: some View {
        Group {
            switch page.presentation {
            case .brandHero:
                brandHeroLayout
            case .framedMock:
                framedMockLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84).delay(0.04)) {
                appeared = true
            }
        }
        .onDisappear { appeared = false }
    }

    // MARK: Welcome — logo and title on background, no card frame

    private var brandHeroLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            AppIntroWelcomeHero()
                .scaleEffect(appeared ? 1 : 0.96)
                .opacity(appeared ? 1 : 0)

            if let intro = page.introLine {
                Text(intro)
                    .font(AppIntroCopyStyle.heroTagline)
                    .foregroundStyle(AppIntroCopyStyle.heroTaglineColor)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
            }

            Spacer(minLength: AppIntroPageLayout.pageIndicatorInset)
        }
        .padding(.horizontal, 8)
    }

    // MARK: Tab mocks + copy

    private var framedMockLayout: some View {
        VStack(spacing: 0) {
            AppIntroPhonePreview {
                AppIntroScreenVisual(kind: page.visual)
            }
            .scaleEffect(appeared ? previewScale : previewScale * 0.96)
            .opacity(appeared ? 1 : 0)
            .padding(.top, 4)

            ScrollView(.vertical, showsIndicators: false) {
                copyBlock
                    .padding(.bottom, AppIntroPageLayout.pageIndicatorInset)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var copyBlock: some View {
        VStack(spacing: 0) {
            if page.showsTitleBelowPreview {
                Text(page.title)
                    .font(AppIntroCopyStyle.sectionTitle)
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
            }

            VStack(alignment: page.lines.isEmpty ? .center : .leading, spacing: 0) {
                if let intro = page.introLine {
                    Text(intro)
                        .font(AppIntroCopyStyle.body)
                        .foregroundStyle(AppIntroCopyStyle.bodyColor)
                        .multilineTextAlignment(page.lines.isEmpty ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)
                        .padding(.bottom, page.lines.isEmpty ? 0 : 12)
                }

                if !page.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(page.lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 10) {
                                switch page.listStyle {
                                case .bullet:
                                    Circle()
                                        .fill(page.accent.opacity(0.9))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 7)
                                case .numbered:
                                    Text("\(index + 1).")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(page.accent.opacity(0.95))
                                        .frame(width: 22, alignment: .trailing)
                                        .padding(.top, 1)
                                }
                                Text(line)
                                    .font(AppIntroCopyStyle.body)
                                    .foregroundStyle(AppIntroCopyStyle.bodyColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: page.lines.isEmpty ? .center : .leading)
            .padding(.horizontal, 32)
            .padding(.top, page.showsTitleBelowPreview ? 10 : 14)
        }
    }
}

// MARK: - Chrome

private enum AppIntroTourStyle {
    /// Matches launch splash / login dark canvas.
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)

    static var topGlow: some View {
        RadialGradient(
            colors: [AppTheme.brand.opacity(0.15), Color.clear],
            center: .top,
            startRadius: 40,
            endRadius: 280
        )
    }
}

#Preview {
    AppIntroTourView(onComplete: {})
}

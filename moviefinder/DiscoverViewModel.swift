// DiscoverViewModel.swift
// Swipe discovery: on-device library only (SQLite via MovieLibraryService). No TMDB discover
// for the deck — other features still use TMDB (credits, detail, Watch Now, etc.).
// RecommendationEngine ranks each batch from the library.

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SwipeFeedback

struct SwipeFeedback: Identifiable, Equatable {
    let id        = UUID()
    let direction: SwipeDirection
    let title:     String
}

// MARK: - DiscoverViewModel

@MainActor
final class DiscoverViewModel: ObservableObject {

    @Published var cards:        [TMDBMovie]    = []
    @Published var isLoading:    Bool           = false
    @Published var errorMessage: String?
    @Published var lastFeedback: SwipeFeedback?
    @Published private(set) var didNotSeeCount = 0
    @Published var isInTrainingMode: Bool = true
    /// Like + dislike (skip) swipes counted toward unlocking; persisted separately from `totalSwipes`.
    @Published private(set) var validTrainingSwipeCount: Int = 0

    let engine: RecommendationEngine
    let prefs:  StreamingPreferences

    private static let trainingCompleteKey = "training_complete"
    private static let trainingValidSwipeCountKey = "training_valid_swipe_count"

    private var isFetching  = false
    private let threshold   = 3
    private var ignoredIds: Set<Int> = []

    /// One-level undo: restores deck + recommendation profile + auxiliary stores exactly as before the last swipe.
    private struct DiscoverSwipeCheckpoint {
        let cards: [TMDBMovie]
        let tasteProfile: TasteProfile
        let evaluationsSnapshot: [Evaluation]
        let watchlistIds: Set<Int>
        let ignoredIds: Set<Int>
        let didNotSeeCountSnapshot: Int
        let validTrainingSwipeCountSnapshot: Int
        let trainingCompleteStored: Bool
        let wasInTrainingMode: Bool
    }

    private var swipeUndoCheckpoint: DiscoverSwipeCheckpoint?
    /// True after a swipe until undo clears it or refresh invalidates it.
    @Published private(set) var canUndoLastSwipe = false
    /// Invalidate in-flight TMDB credits enrichment after undo / refresh so `enrichWithCredits` cannot apply to undone swipes.
    private var swipeCreditsToken = UInt64(0)

    var requiredTrainingPicks: Int { 10 }
    var trainingProgress: Int { min(validTrainingSwipeCount, requiredTrainingPicks) }
    var hasCompletedTraining: Bool {
        UserDefaults.standard.bool(forKey: Self.trainingCompleteKey)
            || validTrainingSwipeCount >= requiredTrainingPicks
    }

    init(engine: RecommendationEngine, prefs: StreamingPreferences) {
        self.engine = engine
        self.prefs  = prefs
        Self.migrateTrainingValidCountIfNeeded(profile: engine.profile)
        var v = UserDefaults.standard.integer(forKey: Self.trainingValidSwipeCountKey)
        // Legacy installs completed training with 20 total swipes (any actions).
        if !UserDefaults.standard.bool(forKey: Self.trainingCompleteKey), engine.profile.totalSwipes >= 20 {
            UserDefaults.standard.set(true, forKey: Self.trainingCompleteKey)
            UserDefaults.standard.set(10, forKey: Self.trainingValidSwipeCountKey)
            v = 10
        }
        validTrainingSwipeCount = min(v, 10)
        let trainingDone = UserDefaults.standard.bool(forKey: Self.trainingCompleteKey)
            || validTrainingSwipeCount >= requiredTrainingPicks
        isInTrainingMode = !trainingDone
    }

    /// Count like (mult 1.0), skip (mult -0.25), and strongSkip (mult -1.0) entries; watchlist does not count.
    private static func countValidTrainingSwipes(in history: [SwipeHistoryEntry]) -> Int {
        history.filter { entry in
            abs(entry.mult - 1.0)  < 0.001   // like
                || abs(entry.mult + 0.25) < 0.001  // skip
                || abs(entry.mult + 1.0)  < 0.001  // strongSkip
        }.count
    }

    private static func migrateTrainingValidCountIfNeeded(profile: TasteProfile) {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.trainingValidSwipeCountKey) != nil { return }
        let fromHistory = min(countValidTrainingSwipes(in: profile.swipeHistory), 10)
        ud.set(fromHistory, forKey: Self.trainingValidSwipeCountKey)
    }

    static func resetTrainingProgressForFullReset() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: Self.trainingValidSwipeCountKey)
        ud.set(false, forKey: Self.trainingCompleteKey)
    }

    // MARK: Public

    func loadInitialCards() async {
        guard cards.isEmpty, !isFetching else { return }
        isLoading = true
        await fetch()
        isLoading = false
    }

    func refresh() async {
        invalidateSwipeUndoCheckpoint()
        cards = []; errorMessage = nil
        isLoading = true; await fetch(); isLoading = false
    }

    /// Removes the previously swiped top card state and rolls back recommendation learning for that swipe.
    func undoLastSwipe() {
        guard let ck = swipeUndoCheckpoint else { return }
        swipeUndoCheckpoint = nil
        canUndoLastSwipe = false
        swipeCreditsToken &+= 1
        lastFeedback = nil

        cards = ck.cards
        engine.restoreProfile(ck.tasteProfile)
        EvaluationsStore.shared.restoreSwipeUndoSnapshot(ck.evaluationsSnapshot)
        WatchlistStore.shared.restoreSwipeUndoSnapshot(ids: ck.watchlistIds)
        ignoredIds = ck.ignoredIds
        didNotSeeCount = ck.didNotSeeCountSnapshot
        validTrainingSwipeCount = ck.validTrainingSwipeCountSnapshot
        isInTrainingMode = ck.wasInTrainingMode
        UserDefaults.standard.set(validTrainingSwipeCount, forKey: Self.trainingValidSwipeCountKey)
        UserDefaults.standard.set(ck.trainingCompleteStored, forKey: Self.trainingCompleteKey)
    }

    private func pushSwipeUndoCheckpoint() {
        swipeUndoCheckpoint = DiscoverSwipeCheckpoint(
            cards: cards,
            tasteProfile: engine.profile,
            evaluationsSnapshot: EvaluationsStore.shared.swipeUndoSnapshot(),
            watchlistIds: WatchlistStore.shared.allIds(),
            ignoredIds: ignoredIds,
            didNotSeeCountSnapshot: didNotSeeCount,
            validTrainingSwipeCountSnapshot: validTrainingSwipeCount,
            trainingCompleteStored: UserDefaults.standard.bool(forKey: Self.trainingCompleteKey),
            wasInTrainingMode: isInTrainingMode
        )
        canUndoLastSwipe = true
    }

    private func invalidateSwipeUndoCheckpoint() {
        swipeCreditsToken &+= 1
        swipeUndoCheckpoint = nil
        canUndoLastSwipe = false
    }

    func handleSwipe(movie: TMDBMovie, direction: SwipeDirection) {
        guard direction != .none else { return }
        pushSwipeUndoCheckpoint()
        cards.removeAll { $0.id == movie.id }
        showFeedback(direction)

        if direction == .didNotSee {
            ignoredIds.insert(movie.id)
            didNotSeeCount += 1
        } else {
            record(movie: movie, direction: direction)
        }

        if direction == .watchlist { WatchlistStore.shared.add(movie) }
        if direction == .like || direction == .watchlist {
            // Positive taste signal for cast/crew nudges — watchlist is weaker in `record` (0.7) but still pro, not con.
            Task { await fetchCredits(movieId: movie.id, wasLiked: direction == .like || direction == .watchlist) }
        }

        // Keep the deck aligned with the latest profile: dislike → drop obvious franchise neighbors, then re-order by engine.
        if direction == .skip || direction == .strongSkip {
            pruneFranchiseNeighbors(of: movie)
        }
        rerankRemainingDeck()

        if cards.count < threshold && !isFetching {
            Task { await fetch() }
        }

        if isInTrainingMode, direction == .like || direction == .skip || direction == .strongSkip {
            let next = min(validTrainingSwipeCount + 1, 10)
            UserDefaults.standard.set(next, forKey: Self.trainingValidSwipeCountKey)
            validTrainingSwipeCount = next
            AccountLocalState.persistTrainingSwipeCount(next)
            if next >= requiredTrainingPicks {
                isInTrainingMode = false
                UserDefaults.standard.set(true, forKey: Self.trainingCompleteKey)
                AccountLocalState.persistGlobalsToScopedUser()
            }
        }
    }

    /// Call after `engine.fullReset()` + `resetTrainingProgressForFullReset()` so training flags match the cleared profile.
    func syncTrainingStateAfterProfileReload() {
        Self.migrateTrainingValidCountIfNeeded(profile: engine.profile)
        let v = UserDefaults.standard.integer(forKey: Self.trainingValidSwipeCountKey)
        validTrainingSwipeCount = min(v, requiredTrainingPicks)
        let trainingDone = UserDefaults.standard.bool(forKey: Self.trainingCompleteKey)
            || validTrainingSwipeCount >= requiredTrainingPicks
        isInTrainingMode = !trainingDone
    }

    // MARK: Private — Fetch

    private func fetch() async {
        // Swiping uses only the on-device library — no TMDB discover fallback.
        if MovieLibraryService.shared.isReady {
            fetchFromLibrary()
            return
        }
        guard !isFetching else { return }
        isFetching = true
        errorMessage = swipeLibraryUnavailableMessage()
        isFetching = false
    }

    private func swipeLibraryUnavailableMessage() -> String {
        switch MovieLibraryService.shared.downloadState {
        case .downloading:
            return "Downloading your movie library…"
        case .failed(let msg):
            return msg.isEmpty ? "Couldn’t download your movie library." : msg
        case .idle:
            return "Movie library isn’t ready yet. Connect to the internet and try again."
        case .ready:
            return "Couldn’t open your movie library."
        }
    }

    private func fetchFromLibrary() {
        guard !isFetching else { return }
        isFetching = true

        let genrePrefs   = GenrePreferencesStore.shared.genrePreferences
        let likedIds     = GenreCatalog.tmdbIds(matching: genrePrefs, level: .like)
        let dislikedIds  = GenreCatalog.tmdbIds(matching: genrePrefs, level: .dislike)
        let existingIds  = Set(cards.map(\.id))
        let excludeIds   = engine.profile.seenIds.union(existingIds).union(ignoredIds)
        let allOnboardingGenreIds = GenreCatalog.onboarding.map(\.tmdbGenreId)

        // Batch size: fetch more candidates than needed so the engine can rank + dedupe effectively.
        let minimumBatch = isInTrainingMode
            ? max(threshold * 2, 10)
            : max(threshold * 2, 7)

        // Give the ranking engine a generous candidate pool (150) so it can surface
        // diverse, well-matched picks rather than just the first 7 available titles.
        let rankingPoolSize = 150

        var candidates = MovieLibraryService.shared.fetchSwipeQueue(
            likedGenreIds:    likedIds,
            dislikedGenreIds: dislikedIds,
            excludingIds:     excludeIds,
            limit:            rankingPoolSize
        )

        // When the taste-filtered pool is exhausted, widen **genre** constraints only.
        // Never drop `seenIds` here — that previously resurfaced skipped titles after only a handful of swipes.
        if candidates.isEmpty {
            candidates = MovieLibraryService.shared.fetchSwipeQueue(
                likedGenreIds:    likedIds,
                dislikedGenreIds: [],
                excludingIds:     excludeIds,
                limit:            rankingPoolSize
            )
        }
        if candidates.isEmpty {
            candidates = MovieLibraryService.shared.fetchSwipeQueue(
                likedGenreIds:    likedIds.isEmpty ? allOnboardingGenreIds : likedIds,
                dislikedGenreIds: [],
                excludingIds:     excludeIds,
                limit:            rankingPoolSize
            )
        }
        if candidates.isEmpty {
            candidates = MovieLibraryService.shared.fetchSwipeQueue(
                likedGenreIds:    allOnboardingGenreIds,
                dislikedGenreIds: [],
                excludingIds:     excludeIds,
                limit:            rankingPoolSize
            )
        }

        var gathered: [TMDBMovie] = []
        for movie in engine.rank(candidates) {
            if isFranchiseDuplicate(movie, in: gathered) { continue }
            gathered.append(movie)
            if gathered.count >= minimumBatch { break }
        }

        cards.append(contentsOf: gathered)
        errorMessage = nil
        isFetching = false
    }

    /// Removes titles that look like the same franchise/series as a title the user just disliked.
    private func pruneFranchiseNeighbors(of dismissed: TMDBMovie) {
        guard !cards.isEmpty else { return }
        cards.removeAll { candidate in
            isFranchiseDuplicate(candidate, in: [dismissed])
        }
    }

    /// Re-sorts cards **below** the top using the engine. The top card stays the natural “next” title after a
    /// removal so we don’t swap a higher-scoring row from deep in the deck onto the front for one frame
    /// (Discover swipe glitch). Deeper order still tracks taste via `rank` on the tail.
    private func rerankRemainingDeck() {
        guard !cards.isEmpty else { return }
        guard let top = cards.first else { return }
        let rest = Array(cards.dropFirst())
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            if rest.isEmpty {
                cards = [top]
            } else {
                cards = [top] + engine.rank(rest)
            }
        }
    }

    // MARK: - Franchise deduplication (Discover queue)

    private static let franchiseStopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "that", "this", "part", "return",
        "about", "after", "before", "under", "between", "within", "without",
    ]

    /// Single-word overlaps this common are ignored (unrelated “franchise” collisions).
    private static let franchiseGenericAnchors: Set<String> = [
        "american", "beautiful", "christmas", "perfect", "another", "forever", "midnight",
        "captain", "doctor", "doctors", "great", "little", "people", "children",
    ]

    /// Words ≥ 5 chars, ignoring articles/numbers and stop words.
    private func franchiseAnchorWords(_ title: String) -> Set<String> {
        Set(
            title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .filter { $0.count >= 5 && !Self.franchiseStopWords.contains($0) && Int($0) == nil }
        )
    }

    private func franchiseIsSequelToken(_ s: String) -> Bool {
        if Int(s) != nil { return true }
        let romans: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]
        return romans.contains(s.lowercased())
    }

    /// Leading phrase for short-title series (e.g. Star Wars, Iron Man 2, Rocky II).
    private func franchiseNormalizedPrefixKey(_ title: String) -> String? {
        let tokens = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var t = tokens
        while let f = t.first, f == "the" || f == "a" || f == "an" { t.removeFirst() }
        guard !t.isEmpty else { return nil }
        if t.count >= 3, franchiseIsSequelToken(t[2]) {
            return "\(t[0]) \(t[1])"
        }
        if t.count >= 2, franchiseIsSequelToken(t[1]) {
            return t[0].count >= 4 ? t[0] : nil
        }
        if t.count >= 2 {
            return "\(t[0]) \(t[1])"
        }
        return t[0]
    }

    private func franchisePrefixMatches(_ a: String, _ b: String) -> Bool {
        guard let ka = franchiseNormalizedPrefixKey(a), let kb = franchiseNormalizedPrefixKey(b) else { return false }
        let minLen = 5
        guard ka.count >= minLen, kb.count >= minLen else { return false }
        if ka == kb { return true }
        return ka.hasPrefix(kb) || kb.hasPrefix(ka)
    }

    /// Returns true if `candidate` is too similar to any movie already in `pool`.
    /// - Two+ shared anchor words → duplicate.
    /// - One shared anchor → duplicate only if length ≥ 6 and not a generic word.
    /// - Otherwise, normalized leading-phrase match (Star Wars, Iron Man, Rocky II, …).
    internal func isFranchiseDuplicate(_ candidate: TMDBMovie, in pool: [TMDBMovie]) -> Bool {
        let cTitle = candidate.title
        let anchorsC = franchiseAnchorWords(cTitle)
        for existing in pool {
            let eTitle = existing.title
            let anchorsE = franchiseAnchorWords(eTitle)
            let overlap = anchorsC.intersection(anchorsE)
            if overlap.count >= 2 {
                return true
            }
            if overlap.count == 1, let w = overlap.first {
                if !Self.franchiseGenericAnchors.contains(w), w.count >= 6 {
                    return true
                }
            }
            if franchisePrefixMatches(cTitle, eTitle) {
                return true
            }
        }
        return false
    }

    // MARK: Private — Engine

    private func record(movie: TMDBMovie, direction: SwipeDirection) {
        let action: SwipeEvent.Action
        switch direction {
        case .like:
            action = .like
            EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .liked, movie: movie)
        case .skip:
            action = .skip
            EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .disliked, movie: movie)
        case .strongSkip:
            action = .strongSkip
            EvaluationsStore.shared.record(tmdbId: movie.id, verdict: .disliked, movie: movie)
        case .watchlist:   action = .watchlist
        case .didNotSee: return
        case .none:      return
        }
        let stub = TMDBMovieDetail(
            id: movie.id, title: movie.title, overview: movie.overview,
            tagline: nil, releaseDate: movie.releaseDate, runtime: nil,
            voteAverage: movie.voteAverage, posterPath: movie.posterPath,
            backdropPath: movie.backdropPath,
            genres: movie.genreIds.map { TMDBGenre(id: $0, name: "") },
            watchProviders: nil)
        engine.record(SwipeEvent(movieId: movie.id, action: action, movie: stub, timestamp: Date()))
    }

    private func fetchCredits(movieId: Int, wasLiked: Bool) async {
        let ticket = swipeCreditsToken
        guard let c = try? await TMDBService.shared.fetchMovieCredits(id: movieId) else { return }
        guard ticket == swipeCreditsToken else { return }
        engine.enrichWithCredits(movieId: movieId, cast: c.cast, crew: c.crew, wasLiked: wasLiked)
    }

    // MARK: Private — UI

    private func showFeedback(_ dir: SwipeDirection) {
        let t: String
        switch dir {
        case .like:        t = "Liked!"
        case .skip:        t = "Disliked"
        case .strongSkip:
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            t = "Won't recommend this genre"
        case .watchlist:   t = "Added to Watchlist"
        case .didNotSee:   t = "Haven’t watched"
        case .none:        return
        }
        lastFeedback = SwipeFeedback(direction: dir, title: t)
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if lastFeedback?.direction == dir { lastFeedback = nil }
        }
    }
}

// MARK: - Layout (centered bars — middle third of screen width)

private enum DiscoverHeaderLayout {
    /// One third of the current screen width (via window scene), not `UIScreen.main` (deprecated iOS 26+).
    static var barContainerWidth: CGFloat {
        #if canImport(UIKit)
        let w = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width
        if let w, w > 0 { return max(120, w / 3) }
        #endif
        return 120
    }
}

private enum DiscoverSpacing {
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
}

/// Tighter card + controls so the deck breathes above the tab bar.
private enum DiscoverLayout {
    static let cardWidth: CGFloat = 300
    static let cardHeight: CGFloat = 452
    static let actionButtonDiameter: CGFloat = 48
    static let actionRowSpacing: CGFloat = 20
    static let actionHorizontalPadding: CGFloat = 28
    static let stackHorizontalPadding: CGFloat = 24
    /// Below header; keep modest — card shadow carries separation.
    static let stackTopPadding: CGFloat = 6
    /// Clears `MovieCard` drop-shadow bleed so Undo isn’t visually under the poster shadow.
    static let undoTopPadding: CGFloat = 28
    /// Space between Undo pill and swipe row (reads as one control cluster).
    static let undoToButtonsSpacing: CGFloat = 16
    /// Extra inset under safe area (nav bar is hidden; avoid stacking with status bar).
    static let headerTopPadding: CGFloat = 14
    /// Air between deck bottom (incl. shadow) and the swipe row when Undo is hidden.
    static let buttonsTopPadding: CGFloat = 52
    static let bottomPaddingTraining: CGFloat = 52
    static let bottomPaddingFull: CGFloat = 36
}

// MARK: - DiscoverView

struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    /// Observing download progress for the offline catalog retry / update flow on empty deck.
    @ObservedObject private var movieLibraryService = MovieLibraryService.shared
    @EnvironmentObject private var prefs: StreamingPreferences
    @AppStorage("genre_onboarding_complete") private var genreOnboardingComplete = false
    @AppStorage("discover_swipe_coach_dismissed") private var swipeCoachDismissed = false
    @State private var drag: CGSize = .zero
    @State private var selected: TMDBMovie?       // for detail sheet
    @State private var swipeCoachVisible = false
    @State private var swipeCoachManualOpen = false
    @State private var firstLaunchCoachWork: DispatchWorkItem?
    @State private var showGenreSheet = false
    private let threshold: CGFloat = 90

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                stack
                Group {
                    if vm.canUndoLastSwipe {
                        VStack(spacing: DiscoverLayout.undoToButtonsSpacing) {
                            discoverUndoButton
                            buttons
                        }
                        .padding(.top, DiscoverLayout.undoTopPadding)
                    } else {
                        buttons
                            .padding(.top, DiscoverLayout.buttonsTopPadding)
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: vm.canUndoLastSwipe)
                .padding(
                    .bottom,
                    vm.isInTrainingMode ? DiscoverLayout.bottomPaddingTraining : DiscoverLayout.bottomPaddingFull
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: genreOnboardingComplete) {
            guard genreOnboardingComplete else { return }
            await vm.loadInitialCards()
        }
        .overlay(alignment: .top) { toast }
        .overlay {
            if swipeCoachVisible && genreOnboardingComplete && (!swipeCoachDismissed || swipeCoachManualOpen) {
                DiscoverSwipeCoachOverlay(onDismiss: dismissSwipeCoach)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                .zIndex(200)
            }
        }
        .onAppear { scheduleFirstLaunchSwipeCoachIfNeeded() }
        .onChange(of: genreOnboardingComplete) { _, done in
            if done { scheduleFirstLaunchSwipeCoachIfNeeded() }
        }
        .sheet(item: $selected) { movie in
            MovieDetailView(movie: movie, engine: vm.engine)
                .environmentObject(WatchlistStore.shared)
        }
        .sheet(isPresented: $showGenreSheet) {
            NavigationStack {
                GenreOnboardingView(
                    genrePrefs: GenrePreferencesStore.shared,
                    primaryButtonTitle: "Save",
                    showMarketingSubtitle: false
                ) {
                    let gp = GenrePreferencesStore.shared.genrePreferences
                    let buckets = GenreCatalog.engineOnboardingGenreIds(from: gp)
                    vm.engine.replaceOnboardingGenres(
                        loved: buckets.loved,
                        liked: buckets.liked,
                        disliked: buckets.disliked
                    )
                    showGenreSheet = false
                    Task { await vm.refresh() }
                }
                .environmentObject(vm.engine)
                .environmentObject(prefs)
                .navigationTitle("Genre Preferences")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showGenreSheet = false }
                    }
                }
            }
        }
    }

    private func scheduleFirstLaunchSwipeCoachIfNeeded() {
        guard genreOnboardingComplete, !swipeCoachDismissed else { return }
        firstLaunchCoachWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                swipeCoachManualOpen = false
                swipeCoachVisible = true
            }
        }
        firstLaunchCoachWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
    }

    private func openSwipeCoachFromInfo() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        firstLaunchCoachWork?.cancel()
        firstLaunchCoachWork = nil
        swipeCoachManualOpen = true
        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
            swipeCoachVisible = true
        }
    }

    private func dismissSwipeCoach() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        withAnimation(.easeOut(duration: 0.22)) {
            swipeCoachVisible = false
            swipeCoachManualOpen = false
            swipeCoachDismissed = true
        }
        AccountLocalState.persistOnboardingFlag("discover_swipe_coach_dismissed", value: true)
    }

    /// Matches Watch Now chrome (streamers / genre) — compact circular material button.
    private func discoverChromeIconButton(icon: String, accessibility: String, action: @escaping () -> Void) -> some View {
        let side: CGFloat = 36
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: side, height: side)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: AppTheme.chromeIconShadow, radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    // MARK: Header

    private var header: some View {
        Group {
            if vm.isInTrainingMode {
                trainingCompactHeader
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    discoverHeaderTitleRow
                    accuracyBarBadge
                    if let e = vm.errorMessage {
                        Text(e)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, DiscoverSpacing.s20)
                .padding(.top, DiscoverLayout.headerTopPadding)
                .padding(.bottom, 10)
            }
        }
        .animation(.easeInOut, value: vm.isInTrainingMode)
    }

    /// Training: title + centered progress + optional error.
    private var trainingCompactHeader: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                discoverHeaderTitleRow
                Text("\(vm.trainingProgress) / \(vm.requiredTrainingPicks)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .frame(maxWidth: .infinity)
                trainingProgressBar
                if let e = vm.errorMessage {
                    Text(e)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, DiscoverSpacing.s20)
            .padding(.top, DiscoverLayout.headerTopPadding)
            .padding(.bottom, DiscoverSpacing.s12)
            Divider()
        }
    }

    /// Left-aligned title matching WatchNow / Watchlist header rhythm; icons pinned to trailing edge.
    private var discoverHeaderTitleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Curate Pickr")
                .font(AppTheme.titleLarge)
                .tracking(-0.35)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if genreOnboardingComplete {
                HStack(spacing: 8) {
                    discoverChromeIconButton(icon: "film.stack", accessibility: "Genre preferences") {
                        showGenreSheet = true
                    }
                    discoverChromeIconButton(icon: "info.circle", accessibility: "Swipe guide") {
                        openSwipeCoachFromInfo()
                    }
                }
            }
        }
    }

    private var trainingProgressBar: some View {
        let total = Double(max(vm.requiredTrainingPicks, 1))
        let ratio = min(1.0, Double(vm.trainingProgress) / total)
        let barW = DiscoverHeaderLayout.barContainerWidth
        let fillW = max(0, barW * ratio)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.gray.opacity(0.22))
                .frame(width: barW, height: 8)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.65)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: fillW, height: 8)
                .animation(.spring(response: 0.35), value: vm.trainingProgress)
        }
        .frame(width: barW, height: 8)
    }

    /// Centered tier bar for non-training mode (below title). Replaces % accuracy.
    private var accuracyBarBadge: some View {
        let swipes = vm.engine.profile.totalSwipes
        let (label, color, ratio): (String, Color, Double) = {
            switch swipes {
            case 0:
                return ("Not Started", Color.gray, 0.0)
            case 1..<5:
                return ("Warming Up", Color.gray, Double(swipes) / 5.0 * 0.15)
            case 5..<20:
                return ("Learning", Color.orange, 0.15 + (Double(swipes) - 5) / 15.0 * 0.35)
            case 20..<50:
                return ("Tuned", Color.blue, 0.50 + (Double(swipes) - 20) / 30.0 * 0.35)
            default:
                return ("Dialed In", Color.green, 1.0)
            }
        }()
        let barW = DiscoverHeaderLayout.barContainerWidth
        let fillW = max(swipes == 0 ? 0 : 4, barW * ratio)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.22))
                    .frame(width: barW, height: 8)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillW, height: 8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: ratio)
            }
            .frame(width: barW, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
                .animation(.easeInOut(duration: 0.3), value: label)
        }
    }

    /// Matches Watch Now “Something else”: capsule material + tint shadow.
    private var discoverUndoButton: some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            drag = .zero
            vm.undoLastSwipe()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                Text("Undo")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(0.88))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: AppTheme.chromeIconShadow.opacity(0.85), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Undo")
        .accessibilityHint("Restores the last swiped movie and rolls back Curate picks for that swipe.")
    }

    // MARK: Card Stack

    private var stack: some View {
        ZStack {
            if vm.isLoading && vm.cards.isEmpty { loading }
            else if !vm.isLoading && vm.cards.isEmpty { empty }
            else {
                ForEach(Array(vm.cards.prefix(3).enumerated().reversed()), id: \.element.id) { i, m in
                    let isTop = i == 0
                    MovieCard(
                        movie: adapt(m),
                        dragOffset: isTop ? drag : .zero,
                        isTopCard: isTop,
                        width: DiscoverLayout.cardWidth,
                        height: DiscoverLayout.cardHeight
                    )
                        .scaleEffect(isTop ? 1.0 : i == 1 ? 0.95 : 0.90)
                        .offset(y: isTop ? 0 : CGFloat(i) * 8)
                        .zIndex(Double(10 - i))
                        .gesture(isTop ? cardGesture(m) : nil)
                        .onTapGesture { if isTop { selected = m } }
                }
            }
        }
        .frame(height: DiscoverLayout.cardHeight)
        .padding(.horizontal, DiscoverLayout.stackHorizontalPadding)
        .padding(.top, DiscoverLayout.stackTopPadding)
    }

    private func cardGesture(_ m: TMDBMovie) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { v in
                let d = direction(v.translation)
                d != .none ? commit(m, d, translation: v.translation) : snap()
            }
    }

    private func direction(_ t: CGSize) -> SwipeDirection {
        if t.width  >  threshold { return .like }
        if t.width  < -threshold { return .skip }
        if t.height < -threshold { return .watchlist }
        if t.height >  threshold { return .didNotSee }  // swipe down = skip (haven't watched)
        return .none
    }

    private func commit(_ m: TMDBMovie, _ d: SwipeDirection, translation: CGSize = .zero) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        withAnimation(.easeInOut(duration: 0.25)) { drag = exit(d, translation: translation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            // Remove the swiped card *before* resetting drag. If `drag = .zero` runs first, the
            // top card is still in `vm.cards` for a frame — it snaps back to center and flashes.
            vm.handleSwipe(movie: m, direction: d)
            withAnimation(.none) { drag = .zero }
        }
    }

    private func snap() {
        withAnimation(.easeOut(duration: 0.28)) { drag = .zero }
    }

    private func exit(_ d: SwipeDirection, translation: CGSize = .zero) -> CGSize {
        switch d {
        case .like:        return CGSize(width:  600, height: 0)
        case .skip:        return CGSize(width: -600, height: 0)
        case .strongSkip:  return CGSize(width: -600, height: 0)
        case .watchlist:   return CGSize(width: 0, height: -800)
        case .didNotSee:   return CGSize(width: 0, height: 600)
        case .none:        return .zero
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: DiscoverLayout.actionRowSpacing) {
            CircleButton(icon: "hand.thumbsdown.fill", color: .red, action: { tap(.skip) }, diameter: DiscoverLayout.actionButtonDiameter)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Dislike")
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in tap(.strongSkip) }
                )
            iconOnlyToolbarButton(icon: "eye.slash", color: .orange, accessibilityLabel: "Skip") { tap(.didNotSee) }
            iconOnlyToolbarButton(icon: "bookmark.fill", color: .blue, accessibilityLabel: "Watchlist") { tap(.watchlist) }
            iconOnlyToolbarButton(icon: "hand.thumbsup.fill", color: .green, accessibilityLabel: "Like") { tap(.like) }
        }
        .padding(.horizontal, DiscoverLayout.actionHorizontalPadding)
    }

    private func tap(_ d: SwipeDirection) {
        guard let top = vm.cards.first else { return }
        commit(top, d)
    }

    private func iconOnlyToolbarButton(icon: String, color: Color, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        CircleButton(icon: icon, color: color, action: action, diameter: DiscoverLayout.actionButtonDiameter)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Toast

    @ViewBuilder
    private var toast: some View {
        if let fb = vm.lastFeedback {
            let (icon, color): (String, Color) = {
                switch fb.direction {
                case .like:        return ("hand.thumbsup.fill", .green)
                case .skip:        return ("hand.thumbsdown.fill",  .red)
                case .strongSkip:  return ("hand.thumbsdown.fill",  .red)
                case .watchlist:   return ("bookmark.fill",       .blue)
                case .didNotSee:   return ("eye.slash",           .orange)
                case .none:        return ("circle",              .gray)
                }
            }()
            Label(fb.title, systemImage: icon)
                .font(.headline).foregroundColor(color)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.ultraThinMaterial).clipShape(Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(fb.id).animation(.spring(), value: fb.id)
        }
    }

    // MARK: Empty / Loading

    private var loading: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(.secondarySystemFill).opacity(0.65))
            .frame(width: DiscoverLayout.cardWidth, height: DiscoverLayout.cardHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: DiscoverSpacing.s12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading movies…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            )
            .shadow(color: AppTheme.cardShadowColor.opacity(0.5), radius: 16, x: 0, y: 8)
    }

    private var empty: some View {
        let downloading: Bool = {
            if case .downloading = movieLibraryService.downloadState { return true }
            return false
        }()

        return ScrollView {
            VStack(spacing: DiscoverSpacing.s12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.top, DiscoverSpacing.s8)
                Text("No more titles right now")
                    .font(.title3.weight(.semibold))
                    .tracking(-0.2)
                    .multilineTextAlignment(.center)
                Text(
                    """
                    Shuffle again from Pickr's offline movie list — or fetch the latest catalog if we've added titles since your last download.
                    """
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                if case .downloading(let progress) = movieLibraryService.downloadState {
                    VStack(spacing: 6) {
                        ProgressView(value: progress)
                            .tint(Color.accentColor)
                            .padding(.horizontal, 28)
                        Text("Updating offline movie list…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                VStack(spacing: DiscoverSpacing.s8) {
                    Button("Refresh picks") {
                        Task { await vm.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloading)

                    Button("Update movie list") {
                        Task {
                            await MovieLibraryService.shared.redownloadLibraryReplacingExisting()
                            await vm.refresh()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(downloading)
                }
                .padding(.top, 4)

                Text(
                    """
                    Updating the list doesn't remove Archives entries, watchlist items, or your swipe history — only the offline titles Pickr pulls from change.
                    """
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, DiscoverSpacing.s8)
            }
        }
        .frame(width: DiscoverLayout.cardWidth, height: DiscoverLayout.cardHeight)
        .scrollIndicators(.hidden)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: AppTheme.cardShadowColor.opacity(0.4), radius: 14, x: 0, y: 7)
        }
    }

    // MARK: Adapter: TMDBMovie → Movie

    private func adapt(_ m: TMDBMovie) -> Movie {
        Movie(title: m.title, year: m.year, genre: [],
              rating: m.voteAverage, overview: m.overview,
              posterColor: Color.stablePlaceholderHue(for: m.id, saturation: 0.45, brightness: 0.30),
              posterURL: m.posterURL)
    }
}

// MARK: - Discover swipe coach (one-time)

private struct DiscoverSwipeCoachOverlay: View {
    let onDismiss: () -> Void
    @State private var didFinish = false

    private func dismissOnce() {
        guard !didFinish else { return }
        didFinish = true
        onDismiss()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 22) {
                    Text("Swipe the deck")
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .tracking(-0.4)
                        .foregroundStyle(.primary)

                    VStack(spacing: 4) {
                        Text("Likes, dislikes, and watchlist")
                        Text("improve your picks")
                        Text("Skip does not—use it for unseen")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                    swipeDiagram
                        .padding(.vertical, 8)

                    Button(action: dismissOnce) {
                        Text("Got it")
                            .font(.system(size: 17, weight: .semibold, design: .default))
                            .tracking(-0.2)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(AppTheme.brand)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                            )
                            .shadow(color: AppTheme.brand.opacity(0.45), radius: 12, x: 0, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel("Got it")
                    .accessibilityHint("Dismisses this guide.")
                }
                .padding(26)
                .frame(maxWidth: 360)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.72))
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.42),
                                        Color.white.opacity(0.12),
                                        Color(red: 0.88, green: 0.72, blue: 0.28).opacity(0.55),
                                        Color.white.opacity(0.08),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                }
                .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 18)
                .shadow(color: AppTheme.brand.opacity(0.12), radius: 40, x: 0, y: 12)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var swipeDiagram: some View {
        VStack(spacing: 18) {
            coachDirection(
                arrow: "arrow.up",
                label: "Watchlist",
                sublabel: "Swipe up",
                tint: .blue,
                icon: "bookmark.fill"
            )

            HStack(alignment: .center, spacing: 0) {
                coachSide(
                    arrow: "arrow.left",
                    label: "Dislike",
                    sublabel: "Swipe left",
                    tint: .red,
                    icon: "hand.thumbsdown.fill",
                    align: .leading
                )

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.08),
                                    Color.primary.opacity(0.03),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 54, height: 54)
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        .frame(width: 54, height: 54)
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
                .padding(.horizontal, 10)

                coachSide(
                    arrow: "arrow.right",
                    label: "Like",
                    sublabel: "Swipe right",
                    tint: .green,
                    icon: "hand.thumbsup.fill",
                    align: .trailing
                )
            }

            coachDirection(
                arrow: "arrow.down",
                label: "Skip",
                sublabel: "Swipe down",
                tint: .orange,
                icon: "eye.slash.fill"
            )
        }
    }

    private func coachDirection(arrow: String, label: String, sublabel: String, tint: Color, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: arrow)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(tint.opacity(0.92))
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(tint)
            Text(sublabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.68))
        }
    }

    private func coachSide(arrow: String, label: String, sublabel: String, tint: Color, icon: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 8) {
            Image(systemName: arrow)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(tint.opacity(0.92))
            HStack(spacing: 6) {
                if align == .trailing {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            Text(sublabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }
}

// MARK: - WatchlistStore

extension Notification.Name {
    /// Posted when the persisted watchlist is cleared (e.g. Settings → Full reset).
    static let watchlistStoreDidReset = Notification.Name("watchlistStoreDidReset")
}

@MainActor
final class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()

    private let key = "watchlist_tmdb_ids_v2"

    /// In-memory snapshot; kept in sync with `UserDefaults` so SwiftUI refreshes when IDs change anywhere in the app.
    @Published private(set) var ids: Set<Int>

    private init() {
        ids = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }

    private func persist() {
        UserDefaults.standard.set(Array(ids), forKey: key)
        guard suppressSyncPushCount == 0, !ProcessInfo.processInfo.isRunningXCTest else { return }
        SupabaseSyncService.shared.schedulePushFromLocalChange()
    }

    func add(_ m: TMDBMovie) {
        guard !ids.contains(m.id) else { return }
        var s = ids
        s.insert(m.id)
        ids = s
        persist()
    }

    func remove(id: Int) {
        guard ids.contains(id) else { return }
        var s = ids
        s.remove(id)
        ids = s
        persist()
    }

    /// Restore watchlist ids after Discover “undo” (whole-set snapshot keeps add/remove symmetrical).
    func restoreSwipeUndoSnapshot(ids: Set<Int>) {
        self.ids = ids
        persist()
    }

    func contains(id: Int) -> Bool { ids.contains(id) }

    func allIds() -> Set<Int> { ids }

    /// Clears all saved IDs (e.g. full app reset). Posts `watchlistStoreDidReset` so UI can reload.
    func removeAll() {
        ids = []
        persist()
        NotificationCenter.default.post(name: .watchlistStoreDidReset, object: nil)
    }

    /// Replace all ids (e.g. Supabase pull on login).
    func replaceAll(ids newIds: Set<Int>, suppressSyncPush: Bool = false) {
        if suppressSyncPush {
            suppressSyncPushCount += 1
            defer { suppressSyncPushCount -= 1 }
        }
        ids = newIds
        persist()
    }

    private var suppressSyncPushCount = 0
}

// MARK: - Preview

#Preview {
    let eng = RecommendationEngine()
    let prf = StreamingPreferences()
    DiscoverView(vm: DiscoverViewModel(engine: eng, prefs: prf))
        .environmentObject(prf)
        .environmentObject(WatchlistStore.shared)
}

// ArchivesView.swift
// Repository of all evaluated movies — Liked and Disliked — with genre/era/sort filtering.
// Settings lives here via the gear button.

import SwiftUI
import Combine

// MARK: - Sort

enum ArchivesSortMode: String, CaseIterable {
    case dateNewest  = "Date (newest)"
    case titleAZ     = "Title (A–Z)"
    case ratingHigh  = "Rating (high to low)"
    case yearNewest  = "Year (newest)"
}

// MARK: - Filter

private enum ArchivesFilter: String, CaseIterable, Identifiable {
    case liked    = "Liked"
    case disliked = "Disliked"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .liked:    return "hand.thumbsup.fill"
        case .disliked: return "hand.thumbsdown.fill"
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ArchivesViewModel: ObservableObject {
    @Published var likedMovies:    [TMDBMovie] = []
    @Published var dislikedMovies: [TMDBMovie] = []
    @Published var isLoading = false

    /// Holds the newest in-flight load; newer calls cancel the previous work so stale completions cannot overwrite UI.
    private var loadTask: Task<Void, Never>?

    /// SwiftUI callers (`.task`, `onChange`, `refreshable`) use `await` for structured suspension; overlapping calls cancel older runs.
    func load() async {
        loadTask?.cancel()
        let t = Task { @MainActor in
            await self._load()
        }
        loadTask = t
        await t.value
    }

    private func _load() async {
        let store = EvaluationsStore.shared

        guard !Task.isCancelled else { return }

        isLoading = true
        defer { isLoading = false }

        let allEvals = store.all

        // ── 1. Build from cache immediately (no network, instant) ────────
        let likedEvals    = allEvals.filter { $0.verdict == .liked    }.reversed() as [Evaluation]
        let dislikedEvals = allEvals.filter { $0.verdict == .disliked }.reversed() as [Evaluation]

        likedMovies    = likedEvals.compactMap    { $0.toTMDBMovie() }
        dislikedMovies = dislikedEvals.compactMap { $0.toTMDBMovie() }

        guard !Task.isCancelled else { return }

        // ── 2. Rows with no workable image URL: fetch once from TMDB (also recovers aborted loads). ──
        let needsFetchIds = Set(
            (likedEvals + dislikedEvals)
                .filter(\.needsArchiveImageFetch)
                .map(\.tmdbId)
        )

        guard !needsFetchIds.isEmpty else { return }

        guard !Task.isCancelled else { return }

        // ── 3. Batch-fetch missing metadata (max 15 concurrent to respect rate limits) ──
        let fetched = await batchFetch(ids: Array(needsFetchIds))

        guard !Task.isCancelled else { return }

        let byId = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })

        // Merge into store so next load is instant
        for movie in fetched {
            guard !Task.isCancelled else { return }
            store.enrichMetaFromRemote(tmdbId: movie.id, movie: movie)
        }

        guard !Task.isCancelled else { return }

        // Re-snapshot evaluations after enrichment (avoid stale `meta` structs from before `enrichMetaFromRemote`).
        let evalsNow = store.all
        let likedNow    = evalsNow.filter { $0.verdict == .liked    }.reversed() as [Evaluation]
        let dislikedNow = evalsNow.filter { $0.verdict == .disliked }.reversed() as [Evaluation]

        likedMovies    = likedNow.compactMap    { archiveRow(from: $0, fetched: byId[$0.tmdbId]) }
        dislikedMovies = dislikedNow.compactMap { archiveRow(from: $0, fetched: byId[$0.tmdbId]) }
    }

    /// Fires requests in batches of 15 so we stay within TMDB's rate limit.
    private func batchFetch(ids: [Int]) async -> [TMDBMovie] {
        var results: [TMDBMovie] = []
        let batchSize = 15
        let batches   = stride(from: 0, to: ids.count, by: batchSize).map {
            Array(ids[$0 ..< min($0 + batchSize, ids.count)])
        }
        for (i, batch) in batches.enumerated() {
            guard !Task.isCancelled else { break }
            await withTaskGroup(of: TMDBMovie?.self) { group in
                for id in batch {
                    group.addTask {
                        guard let d = await self.fetchDetailWithRetry(id: id) else { return nil }
                        return TMDBMovie(
                            id: d.id, title: d.title, overview: d.overview,
                            releaseDate: d.releaseDate, posterPath: d.posterPath,
                            backdropPath: d.backdropPath, voteAverage: d.voteAverage,
                            voteCount: 0, genreIds: d.genres.map(\.id), popularity: 0
                        )
                    }
                }
                for await m in group { if let m { results.append(m) } }
            }
            // 400 ms pause between batches so we don't hit the 40 req/10 s limit
            if i < batches.count - 1 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { break }
            }
        }
        return results
    }

    /// Single retry helps when a detail request fails transiently (spotty network / rate pressure).
    private func fetchDetailWithRetry(id: Int) async -> TMDBMovieDetail? {
        for attempt in 0..<2 {
            if let d = try? await TMDBService.shared.fetchMovieDetail(id: id) {
                return d
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
        }
        return nil
    }

    /// Prefer a fresh TMDB row whenever the cached row still can't render an image URL.
    private func archiveRow(from eval: Evaluation, fetched: TMDBMovie?) -> TMDBMovie? {
        guard let local = eval.toTMDBMovie() else { return fetched }
        guard let fetched else { return local }
        if local.posterURL == nil, fetched.posterURL != nil { return fetched }
        return local
    }
}

// MARK: - View

struct ArchivesView: View {
    @StateObject private var vm = ArchivesViewModel()
    @ObservedObject private var evaluations = EvaluationsStore.shared
    @State private var filter: ArchivesFilter = .liked
    @State private var selected: TMDBMovie?
    @State private var showSettings = false
    @State private var showFilterSheet = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    // Filter state
    @State private var selectedGenreName: String?
    @State private var selectedEraLabel: String?
    @State private var sortMode: ArchivesSortMode = .dateNewest

    @EnvironmentObject var engine:    RecommendationEngine
    @EnvironmentObject var prefs:     StreamingPreferences
    @EnvironmentObject var discoverVM: DiscoverViewModel

    // Raw movies for current tab
    private var rawMovies: [TMDBMovie] {
        filter == .liked ? vm.likedMovies : vm.dislikedMovies
    }

    private var searchTrimmed: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // After genre/era filter + sort + search
    private var filteredMovies: [TMDBMovie] {
        var list = rawMovies
        if let g = selectedGenreName {
            list = list.filter { $0.genreIds.contains { archivesGenreLabel($0) == g } }
        }
        if let e = selectedEraLabel {
            list = list.filter { archivesDecadeLabel(for: $0) == e }
        }
        switch sortMode {
        case .dateNewest:  break                   // already in recency order from vm
        case .titleAZ:     list = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .ratingHigh:  list = list.sorted { $0.voteAverage > $1.voteAverage }
        case .yearNewest:  list = list.sorted { (Int($0.year) ?? 0) > (Int($1.year) ?? 0) }
        }
        let q = searchTrimmed
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.year.localizedCaseInsensitiveContains(q) ||
            $0.genreIds.contains { archivesGenreLabel($0).localizedCaseInsensitiveContains(q) }
        }
    }

    private var hasActiveFilters: Bool { selectedGenreName != nil || selectedEraLabel != nil }

    // Genre/decade stats for filter sheet
    private var currentGenreCounts: [(name: String, count: Int)] {
        var map: [String: Int] = [:]
        for m in rawMovies { for gid in m.genreIds { map[archivesGenreLabel(gid), default: 0] += 1 } }
        return map.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private var currentDecadeCounts: [(label: String, count: Int)] {
        var map: [String: Int] = [:]
        for m in rawMovies { map[archivesDecadeLabel(for: m), default: 0] += 1 }
        let order = ["2020s", "2010s", "2000s", "1990s", "Earlier"]
        return order.compactMap { k in map[k].map { (k, $0) } }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    archivesHeader
                    if vm.isLoading {
                        loadingState
                    } else if vm.likedMovies.isEmpty && vm.dislikedMovies.isEmpty {
                        emptyState
                    } else {
                        archivesContent
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await vm.load() }
            .onChange(of: evaluations.mutationGeneration) { _, _ in
                Task { await vm.load() }
            }
            .onChange(of: filter) { _, _ in
                selectedGenreName = nil
                selectedEraLabel = nil
                searchText = ""
            }
            .sheet(item: $selected) { m in
                MovieDetailView(movie: m, engine: engine)
                    .environmentObject(WatchlistStore.shared)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(engine)
                    .environmentObject(prefs)
                    .environmentObject(discoverVM)
            }
            .sheet(isPresented: $showFilterSheet) {
                archivesFilterSheet
            }
        }
    }

    // MARK: - Header

    private var archivesHeader: some View {
        HStack {
            Text("Archives")
                .font(AppTheme.titleLarge)
                .tracking(-0.35)
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 8) {
                if !rawMovies.isEmpty {
                    Button { showFilterSheet = true } label: {
                        Image(systemName: hasActiveFilters
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(hasActiveFilters ? Color.accentColor : .primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1))
                            .shadow(color: AppTheme.chromeIconShadow, radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter")
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.07), lineWidth: 1))
                        .shadow(color: AppTheme.chromeIconShadow, radius: 8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    private var archivesContent: some View {
        VStack(spacing: 0) {
            // Picker + search sit outside the scroll view so they stay fixed
            VStack(spacing: 10) {
                filterPicker
                    .padding(.horizontal, 20)
                archivesSearchBar
                    .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasActiveFilters {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                selectedGenreName = nil
                                selectedEraLabel = nil
                            }
                        } label: {
                            Label("Clear filters", systemImage: "xmark.circle")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 20)
                    }
                    movieGrid
                        .padding(.horizontal, 20)
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .refreshable { await vm.load() }
        }
    }

    private var archivesSearchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("", text: $searchText,
                      prompt: Text("Search \(filter == .liked ? "liked" : "disliked") films")
                        .font(.body)
                        .foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: searchFocused
                            ? [Color.blue.opacity(0.65), Color.blue.opacity(0.2)]
                            : [Color.primary.opacity(0.09), Color.primary.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: searchFocused ? 1.5 : 1
                )
        }
        .shadow(
            color: Color.black.opacity(searchFocused ? 0.14 : 0.07),
            radius: searchFocused ? 18 : 11, x: 0, y: searchFocused ? 7 : 4
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: searchFocused)
    }

    // MARK: - Tab Picker

    private var filterPicker: some View {
        HStack(spacing: 0) {
            ForEach(ArchivesFilter.allCases) { tab in
                let isSelected = filter == tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { filter = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.semibold))
                        let count = tab == .liked ? vm.likedMovies.count : vm.dislikedMovies.count
                        Text("\(count)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .opacity(0.6)
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color(.secondarySystemGroupedBackground) : Color.clear)
                            .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 4, x: 0, y: 2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.tertiarySystemFill).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Grid

    /// Busts `AsyncImage`/cell reuse when poster paths appear after enrichment.
    private func archiveCardIdentity(_ movie: TMDBMovie) -> String {
        "\(movie.id)|\(movie.posterPath ?? "")|\(movie.backdropPath ?? "")"
    }

    private var movieGrid: some View {
        Group {
            if filteredMovies.isEmpty {
                emptyFilterState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(
                        columns: AppTheme.PosterGrid.columns,
                        spacing: AppTheme.PosterGrid.rowSpacing
                    ) {
                        ForEach(filteredMovies) { movie in
                            WatchlistCard(movie: movie)
                                .posterGridCellTopAligned()
                                .id(archiveCardIdentity(movie))
                                .onTapGesture { selected = movie }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filter Sheet

    private var archivesFilterSheet: some View {
        NavigationStack {
            ZStack {
                ZStack {
                    Color(.systemGroupedBackground)
                    LinearGradient(
                        colors: [Color.clear, AppTheme.filterAccent.opacity(0.055)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {

                        // Sort
                        archivesFilterSection(title: "Sort", subtitle: "Change order", icon: "arrow.up.arrow.down") {
                            WatchlistChipFlowLayout(spacing: 10, lineSpacing: 10) {
                                ForEach(ArchivesSortMode.allCases, id: \.self) { mode in
                                    WatchlistFilterChipButton(
                                        title: mode.rawValue,
                                        count: 0,
                                        isSelected: sortMode == mode
                                    ) { sortMode = mode }
                                }
                            }
                        }

                        // Genres
                        if !currentGenreCounts.isEmpty {
                            archivesFilterSection(title: "Genres", subtitle: "One at a time", icon: "theatermasks.fill") {
                                SelectableGenreChips(genres: currentGenreCounts, selection: $selectedGenreName)
                            }
                        }

                        // Era
                        if !currentDecadeCounts.isEmpty {
                            archivesFilterSection(title: "By era", subtitle: "Release decade", icon: "calendar") {
                                SelectableEraChips(decades: currentDecadeCounts, selection: $selectedEraLabel)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 22)
                }
            }
            .navigationTitle("Filter & Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFilterSheet = false }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.filterAccent)
                }
            }
        }
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func archivesFilterSection<Content: View>(
        title: String, subtitle: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [AppTheme.filterAccent.opacity(0.18), AppTheme.brand.opacity(0.1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LinearGradient(
                            colors: [AppTheme.filterAccent, AppTheme.brand],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.07), radius: 24, x: 0, y: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [Color.white.opacity(0.45), Color.primary.opacity(0.05),
                                     AppTheme.filterAccent.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
        )
    }

    // MARK: - Empty States

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading your history…")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 52)).foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.title2.weight(.semibold))
            Text("Movies you swipe on in Discover will appear here as your archive.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 12) {
            Image(systemName: filter == .liked ? "hand.thumbsup" : "hand.thumbsdown")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(filter == .liked ? "No liked films yet" : "No disliked films yet")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Genre / era helpers (shared with filter sheet)

func archivesGenreLabel(_ id: Int) -> String {
    if let n = GenreCatalog.displayName(forTmdbGenreId: id) { return n }
    let extra: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Sci-Fi",
        53: "Thriller", 10752: "War", 37: "Western",
    ]
    return extra[id] ?? "Other"
}

func archivesDecadeLabel(for movie: TMDBMovie) -> String {
    guard let y = Int(movie.year.prefix(4)) else { return "Earlier" }
    switch y {
    case 2020...:      return "2020s"
    case 2010...2019:  return "2010s"
    case 2000...2009:  return "2000s"
    case 1990...1999:  return "1990s"
    default:           return "Earlier"
    }
}

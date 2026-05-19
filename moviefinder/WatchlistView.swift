// WatchlistView.swift
// My List tab — watchlist + liked movies

import SwiftUI
import Combine

// MARK: - WatchlistViewModel

@MainActor
final class WatchlistViewModel: ObservableObject {
    @Published var watchlistMovies: [TMDBMovie] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var totalSavedCount = 0

    private var orderedIds: [Int] = []
    private var nextFetchIndex = 0
    private let pageSize = 20

    var hasMore: Bool { nextFetchIndex < orderedIds.count }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let ids = WatchlistStore.shared.allIds()
        totalSavedCount = ids.count
        orderedIds = Array(ids).sorted()
        nextFetchIndex = 0
        watchlistMovies = []
        guard !ids.isEmpty else { return }
        await fetchNextBatch()
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchNextBatch()
    }

    private func fetchNextBatch() async {
        let end = min(nextFetchIndex + pageSize, orderedIds.count)
        guard nextFetchIndex < end else { return }
        let slice = Array(orderedIds[nextFetchIndex..<end])
        nextFetchIndex = end

        var newMovies: [TMDBMovie] = []
        await withTaskGroup(of: TMDBMovie?.self) { group in
            for id in slice {
                group.addTask {
                    guard let d = try? await TMDBService.shared.fetchMovieDetail(id: id) else { return nil }
                    return Self.detailToMovie(d)
                }
            }
            for await m in group { if let m { newMovies.append(m) } }
        }
        watchlistMovies = (watchlistMovies + newMovies).sorted { $0.title < $1.title }
    }

    func remove(_ movie: TMDBMovie) {
        WatchlistStore.shared.remove(id: movie.id)
        MovieDetailEngineRecordStore.shared.revokeWatchlistTracking(for: movie.id)
        watchlistMovies.removeAll { $0.id == movie.id }
        orderedIds.removeAll { $0 == movie.id }
        totalSavedCount = max(0, totalSavedCount - 1)
        if nextFetchIndex > orderedIds.count {
            nextFetchIndex = orderedIds.count
        }
    }

    nonisolated private static func detailToMovie(_ d: TMDBMovieDetail) -> TMDBMovie {
        TMDBMovie(id: d.id, title: d.title, overview: d.overview, releaseDate: d.releaseDate,
                  posterPath: d.posterPath, backdropPath: d.backdropPath, voteAverage: d.voteAverage,
                  voteCount: 0, genreIds: d.genres.map { $0.id }, popularity: 0)
    }
}
private func watchlistGenreLabel(_ id: Int) -> String {
    if let n = GenreCatalog.displayName(forTmdbGenreId: id) { return n }
    let extra: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Sci-Fi",
        53: "Thriller", 10752: "War", 37: "Western",
    ]
    return extra[id] ?? "Other"
}

private func decadeLabel(for movie: TMDBMovie) -> String {
    guard let y = Int(movie.year.prefix(4)) else { return "Earlier" }
    switch y {
    case 2020...: return "2020s"
    case 2010...2019: return "2010s"
    case 2000...2009: return "2000s"
    case 1990...1999: return "1990s"
    default: return "Earlier"
    }
}

// MARK: - WatchlistView

private enum WatchlistSpacing {
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
}

/// Matches `WatchNowChrome` / `WatchNowView` header + filter button rhythm.
private enum WatchlistChrome {
    static let horizontal: CGFloat = 20
    static let headerTop: CGFloat = 14
    static let headerBottom: CGFloat = 8
    static let titleStackSpacing: CGFloat = 8
    /// Same as `WatchNowChrome.s12`: gap from title row to chips/search below.
    static let headerToContent: CGFloat = 12
}

struct WatchlistView: View {
    @StateObject private var vm = WatchlistViewModel()
    @State private var selected: TMDBMovie?
    @State private var watchlistSearchText = ""
    @FocusState private var watchlistSearchFieldFocused: Bool
    @State private var selectedGenreName: String?
    @State private var selectedEraLabel: String?
    @State private var sortMode: ArchivesSortMode = .titleAZ
    @State private var showFilterSheet = false
    @EnvironmentObject var engine: RecommendationEngine

    private var watchlistSearchTrimmed: String {
        watchlistSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveFilters: Bool { selectedGenreName != nil || selectedEraLabel != nil }

    /// Every saved bookmark — like/dislike from detail or Curate still records to Archives but does **not** remove the bookmark; only clearing the blue bookmark (or “Remove from list”) drops the title from this tab.
    private var queuedMovies: [TMDBMovie] {
        var list = vm.watchlistMovies
        if let g = selectedGenreName {
            list = list.filter { $0.genreIds.contains { archivesGenreLabel($0) == g } }
        }
        if let e = selectedEraLabel {
            list = list.filter { archivesDecadeLabel(for: $0) == e }
        }
        switch sortMode {
        case .dateNewest:  break   // saved-order approximation (IDs are appended chronologically)
        case .titleAZ:     list = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .ratingHigh:  list = list.sorted { $0.voteAverage > $1.voteAverage }
        case .yearNewest:  list = list.sorted { (Int($0.year) ?? 0) > (Int($1.year) ?? 0) }
        }
        return list
    }

    private var displayedMovies: [TMDBMovie] {
        let q = watchlistSearchTrimmed
        guard !q.isEmpty else { return queuedMovies }
        return queuedMovies.filter { matchesWatchlistSearch($0, query: q) }
    }

    private var genreCounts: [(name: String, count: Int)] {
        var map: [String: Int] = [:]
        for m in vm.watchlistMovies {
            for gid in m.genreIds { map[archivesGenreLabel(gid), default: 0] += 1 }
        }
        return map.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private var decadeCounts: [(label: String, count: Int)] {
        var map: [String: Int] = [:]
        for m in vm.watchlistMovies {
            map[archivesDecadeLabel(for: m), default: 0] += 1
        }
        let order = ["2020s", "2010s", "2000s", "1990s", "Earlier"]
        return order.compactMap { k in map[k].map { (k, $0) } }
    }

    private func matchesWatchlistSearch(_ movie: TMDBMovie, query: String) -> Bool {
        if movie.title.localizedCaseInsensitiveContains(query) { return true }
        if movie.overview.localizedCaseInsensitiveContains(query) { return true }
        if movie.year.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    watchlistHeader
                    if !vm.isLoading && queuedMovies.count > 0 {
                        watchlistPremiumSearchBar
                            .padding(.horizontal, WatchlistChrome.horizontal)
                            .padding(.top, WatchlistChrome.headerToContent)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Group {
                        if vm.isLoading {
                            loadingState
                        } else if queuedMovies.isEmpty {
                            emptyState
                        } else {
                            movieContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: vm.totalSavedCount)
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: watchlistSearchFieldFocused)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await vm.load() }
            .onReceive(NotificationCenter.default.publisher(for: .watchlistStoreDidReset)) { _ in
                Task { await vm.load() }
            }
            .refreshable { await vm.load() }
            .sheet(item: $selected) { m in
                MovieDetailView(movie: m, engine: engine)
                    .environmentObject(WatchlistStore.shared)
            }
            .sheet(isPresented: $showFilterSheet) {
                watchlistFilterSheet
            }
        }
    }

    private var watchlistHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: WatchlistChrome.titleStackSpacing) {
                Text("Watchlist")
                    .font(AppTheme.titleLarge)
                    .tracking(-0.35)
                    .foregroundStyle(.primary)
            }
            Spacer()
            if !vm.watchlistMovies.isEmpty {
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
                .accessibilityLabel("Filter & Sort")
            }
        }
        .padding(.horizontal, WatchlistChrome.horizontal)
        .padding(.top, WatchlistChrome.headerTop)
        .padding(.bottom, WatchlistChrome.headerBottom)
    }

    /// Inline search — only titles already in your watchlist (loaded rows). Material, focus ring, warm accent.
    private var watchlistPremiumSearchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("", text: $watchlistSearchText,
                      prompt: Text("Search your list")
                        .font(.body)
                        .foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .focused($watchlistSearchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !watchlistSearchText.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        watchlistSearchText = ""
                    }
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
                        colors: watchlistSearchFieldFocused
                            ? [Color.blue.opacity(0.65), Color.blue.opacity(0.2)]
                            : [Color.primary.opacity(0.09), Color.primary.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: watchlistSearchFieldFocused ? 1.5 : 1
                )
        }
        .shadow(
            color: Color.black.opacity(watchlistSearchFieldFocused ? 0.14 : 0.07),
            radius: watchlistSearchFieldFocused ? 18 : 11,
            x: 0,
            y: watchlistSearchFieldFocused ? 7 : 4
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search your watchlist")
    }

    private var loadingState: some View {
        VStack(spacing: WatchlistSpacing.md) {
            ProgressView()
            Text("Loading your saved titles…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WatchlistSpacing.lg)
    }

    private var movieContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchlistSpacing.md) {
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
                }
                if !watchlistSearchTrimmed.isEmpty {
                    watchlistSearchContextStrip
                }
                if displayedMovies.isEmpty && !watchlistSearchTrimmed.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("Nothing matches “\(watchlistSearchTrimmed)”.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    LazyVGrid(columns: AppTheme.PosterGrid.columns, spacing: AppTheme.PosterGrid.rowSpacing) {
                        ForEach(displayedMovies) { movie in
                            WatchlistCard(movie: movie)
                                .posterGridCellTopAligned()
                                .id("\(movie.id)|\(movie.posterPath ?? "")|\(movie.backdropPath ?? "")")
                                .onTapGesture { selected = movie }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            vm.remove(movie)
                                            engine.removeFromSeen(movieId: movie.id)
                                        }
                                    } label: {
                                        Label("Remove from list", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                if vm.hasMore {
                    loadMoreButton
                }
            }
            .padding(WatchlistSpacing.md)
        }
    }

    /// Compact summary while searching — keeps context without crowding the grid.
    private var watchlistSearchContextStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.22), Color.blue.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Your list")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("\(displayedMovies.count) of \(queuedMovies.count) match")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.18), Color.primary.opacity(0.04)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: AppTheme.cardShadowColor.opacity(0.2), radius: 12, x: 0, y: 5)
    }

    private var loadMoreButton: some View {
        Button {
            Task { await vm.loadMore() }
        } label: {
            HStack(spacing: 8) {
                if vm.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(vm.isLoadingMore ? "Loading…" : "Load more")
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isLoadingMore)
    }

    private var emptyState: some View {
        VStack(spacing: WatchlistSpacing.lg) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Nothing to watch yet")
                .font(.title2.weight(.semibold))
            Text("Save movies with the bookmark. You can like or dislike from detail — they’ll appear in Archives too, and stay here until you clear the bookmark.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WatchlistSpacing.lg)
    }

    // MARK: - Filter Sheet

    private var watchlistFilterSheet: some View {
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
                        watchlistFilterSection(title: "Sort", subtitle: "Change order", icon: "arrow.up.arrow.down") {
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
                        if !genreCounts.isEmpty {
                            watchlistFilterSection(title: "Genres", subtitle: "One at a time", icon: "theatermasks.fill") {
                                SelectableGenreChips(genres: genreCounts, selection: $selectedGenreName)
                            }
                        }

                        // Era
                        if !decadeCounts.isEmpty {
                            watchlistFilterSection(title: "By era", subtitle: "Release decade", icon: "calendar") {
                                SelectableEraChips(decades: decadeCounts, selection: $selectedEraLabel)
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

    private func watchlistFilterSection<Content: View>(
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
}

// MARK: - Filter chips

struct WatchlistFilterChipButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .opacity(isSelected ? 0.95 : 0.55)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(chipBackgroundFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chipBorderColor, lineWidth: 1)
            }
            .shadow(
                color: isSelected ? AppTheme.filterAccent.opacity(0.38) : Color.black.opacity(0.05),
                radius: isSelected ? 12 : 5,
                x: 0,
                y: isSelected ? 5 : 2
            )
        }
        .buttonStyle(.plain)
    }

    private var chipBackgroundFill: LinearGradient {
        LinearGradient(
            colors: isSelected
                ? [AppTheme.filterAccent, AppTheme.brand.opacity(0.94)]
                : [Color(.tertiarySystemGroupedBackground), Color(.tertiarySystemGroupedBackground)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var chipBorderColor: Color {
        isSelected ? Color.white.opacity(0.28) : Color.primary.opacity(0.08)
    }
}

struct WatchlistChipFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        if maxWidth == .greatestFiniteMagnitude, !subviews.isEmpty {
            var w: CGFloat = 0
            var h: CGFloat = 0
            for (i, sub) in subviews.enumerated() {
                let s = sub.sizeThatFits(.unspecified)
                w += s.width + (i > 0 ? spacing : 0)
                h = max(h, s.height)
            }
            return CGSize(width: w, height: h)
        }

        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + spacing + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + lineSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > bounds.width, x > bounds.minX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

struct SelectableGenreChips: View {
    let genres: [(name: String, count: Int)]
    @Binding var selection: String?

    private let flowGap: CGFloat = 10

    var body: some View {
        WatchlistChipFlowLayout(spacing: flowGap, lineSpacing: flowGap) {
            ForEach(genres, id: \.name) { item in
                WatchlistFilterChipButton(
                    title: item.name,
                    count: item.count,
                    isSelected: selection == item.name
                ) {
                    if selection == item.name { selection = nil }
                    else { selection = item.name }
                }
            }
        }
    }
}

struct SelectableEraChips: View {
    let decades: [(label: String, count: Int)]
    @Binding var selection: String?

    private let flowGap: CGFloat = 10

    var body: some View {
        WatchlistChipFlowLayout(spacing: flowGap, lineSpacing: flowGap) {
            ForEach(decades, id: \.label) { item in
                WatchlistFilterChipButton(
                    title: item.label,
                    count: item.count,
                    isSelected: selection == item.label
                ) {
                    if selection == item.label { selection = nil }
                    else { selection = item.label }
                }
            }
        }
    }
}

// MARK: - Watchlist Card

struct WatchlistCard: View {
    let movie: TMDBMovie

    /// TMDB posters are portrait; constrains poster width to grid cell (`LazyVGrid` row `spacing` is vertical-only unless `GridItem` spacing adds column gutters).
    private var posterAspect: CGFloat { 2 / 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                posterImage
                ratingBadgeOverlay
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(posterAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(movie.year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 52, alignment: .top)
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        if let url = movie.posterURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        placeholderFill
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white.opacity(0.85))
                    }
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    placeholderFill
                        .overlay(
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.45))
                        )
                @unknown default:
                    placeholderFill
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .id(url.absoluteString)
        } else {
            placeholderFill
                .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.5)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Rating pill over the poster (`allowsHitTesting(false)` keeps taps on the outer card tap target).
    private var ratingBadgeOverlay: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption2)
                    Text(String(format: "%.1f", movie.voteAverage))
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var placeholderFill: some View {
        Rectangle()
            .fill(Color.stablePlaceholderHue(for: movie.id, saturation: 0.4, brightness: 0.3))
    }
}

#Preview {
    WatchlistView()
        .environmentObject(RecommendationEngine())
}

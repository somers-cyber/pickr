// GenreOnboardingView.swift
// Genre preferences — inset grouped list (full-row tap), compact primary action.

import SwiftUI

struct GenreOnboardingView: View {
    @ObservedObject var genrePrefs: GenrePreferencesStore
    @ObservedObject var libraryService: MovieLibraryService = .shared
    var primaryButtonTitle: String = "Continue"
    /// Kept for API compatibility.
    var showMarketingSubtitle: Bool = true
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(GenreCatalog.onboarding) { genre in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                genrePrefs.cycle(genre.displayName)
                            }
                        } label: {
                            GenrePreferenceRowContent(
                                title: genre.displayName,
                                level: genrePrefs.genrePreferences[genre.displayName] ?? .neutral
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            genreRowBackground(
                                level: genrePrefs.genrePreferences[genre.displayName] ?? .neutral
                            )
                        )
                    }
                } header: {
                    Text("Tap a row to cycle neutral, like, or dislike.")
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)

            saveActionBar
        }
        .background(Color(.systemGroupedBackground))
    }

    private var saveActionBar: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.primary.opacity(0.08))

            // Progress bar — visible only while the library is downloading.
            // In practice the user is busy selecting genres, so this resolves
            // before they tap Continue in most network conditions.
            if case .downloading(let progress) = libraryService.downloadState {
                VStack(spacing: 5) {
                    ProgressView(value: progress)
                        .tint(AppTheme.brand)
                        .padding(.horizontal, 20)
                    Text("Personalizing your library…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button(action: {
                // Button is disabled during download; this only fires when ready.
                onComplete()
            }) {
                HStack(spacing: 8) {
                    if case .downloading = libraryService.downloadState {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.82)
                        Text("Setting up…")
                            .font(.system(size: 16, weight: .semibold))
                    } else {
                        Text(primaryButtonTitle)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .disabled({
                if case .downloading = libraryService.downloadState { return true }
                return false
            }())
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.brand)
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.25), value: libraryService.downloadState == .ready)
    }

    @ViewBuilder
    private func genreRowBackground(level: PreferenceLevel) -> some View {
        switch level {
        case .neutral:
            Color.clear
        case .like:
            AppTheme.genreLikeHighlight.opacity(0.14)
        case .dislike:
            Color.primary.opacity(0.045)
        }
    }
}

// MARK: - Row content (inside List — entire row is the button’s label)

private struct GenrePreferenceRowContent: View {
    let title: String
    let level: PreferenceLevel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 28, alignment: .center)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(AppTheme.rowTitle)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Text(levelLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(levelLabelForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(levelPillBackground)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch level {
        case .neutral: return "circle.dashed"
        case .like: return "hand.thumbsup.fill"
        case .dislike: return "hand.thumbsdown.fill"
        }
    }

    private var iconTint: Color {
        switch level {
        case .neutral: return .secondary
        case .like: return AppTheme.genreLikeHighlight
        case .dislike: return .secondary.opacity(0.75)
        }
    }

    private var levelLabel: String {
        switch level {
        case .neutral: return "Neutral"
        case .like: return "Like"
        case .dislike: return "Dislike"
        }
    }

    private var levelLabelForeground: Color {
        switch level {
        case .neutral: return .secondary
        case .like: return AppTheme.genreLikeHighlight.opacity(0.95)
        case .dislike: return .secondary
        }
    }

    private var levelPillBackground: Color {
        switch level {
        case .neutral: return Color(.secondarySystemFill)
        case .like: return AppTheme.genreLikeHighlight.opacity(0.16)
        case .dislike: return Color(.secondarySystemFill)
        }
    }
}

#Preview {
    NavigationStack {
        GenreOnboardingView(genrePrefs: GenrePreferencesStore.shared) {}
            .navigationTitle("Genre Preferences")
            .navigationBarTitleDisplayMode(.inline)
    }
}

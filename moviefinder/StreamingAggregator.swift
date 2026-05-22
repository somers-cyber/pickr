// StreamingAggregator.swift
// Streaming service list, user preferences, and the Services tab UI.
// All services are limited to United States availability and use TMDB provider IDs.

import SwiftUI
import Combine

// MARK: - StreamingService

struct StreamingService: Identifiable {
    let id:         Int
    let name:       String
    let logoURL:    URL?
    let logoSymbol: String  // SF Symbol name — shown in rows, chips, and filter badges
    let color:      Color   // Brand color — consistent across rows, tags, and Watch Now cards

    // US-available streaming services using TMDB's watch_provider IDs for region=US.
    // Pipe-separated provider IDs in TMDB Discover queries (with_watch_providers) match
    // against these IDs when the user selects services.
    static let all: [StreamingService] = [
        .init(id: 8,    name: "Netflix",     logoURL: URL(string: "https://image.tmdb.org/t/p/w92/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg"), logoSymbol: "play.rectangle.fill",  color: Color(red: 0.90, green: 0.05, blue: 0.05)),
        // Logo paths for Prime / Max / Tubi / Shudder must match TMDB watch/providers (US); old filenames 404.
        .init(id: 9,    name: "Prime Video", logoURL: URL(string: "https://image.tmdb.org/t/p/w92/pvske1MyAoymrs5bguRfVqYiM9a.jpg"), logoSymbol: "play.circle.fill",     color: Color(red: 0.00, green: 0.67, blue: 0.88)),
        .init(id: 337,  name: "Disney+",     logoURL: URL(string: "https://image.tmdb.org/t/p/w92/7rwgEs15tFwyR9NPQ5vpzxTj19Q.jpg"), logoSymbol: "sparkles",             color: Color(red: 0.07, green: 0.24, blue: 0.81)),
        .init(id: 15,   name: "Hulu",        logoURL: URL(string: "https://image.tmdb.org/t/p/w92/zxrVdFjIjLqkfnwyghnfywTn3Lh.jpg"), logoSymbol: "leaf.fill",            color: Color(red: 0.11, green: 0.91, blue: 0.51)),
        .init(id: 1899, name: "Max",         logoURL: URL(string: "https://image.tmdb.org/t/p/w92/jbe4gVSfRlbPTdESXhEKpornsfu.jpg"), logoSymbol: "bolt.fill",            color: Color(red: 0.00, green: 0.17, blue: 0.90)),
        .init(id: 350,  name: "Apple TV+",   logoURL: URL(string: "https://image.tmdb.org/t/p/w92/6uhKBfmtzFqOcLousHwZuzcrScK.jpg"), logoSymbol: "apple.logo",           color: Color(white: 0.35)),
        .init(id: 386,  name: "Peacock",     logoURL: URL(string: "https://image.tmdb.org/t/p/w92/xTHltMrZPAJFLQ6qyCBjAnXSmZt.jpg"), logoSymbol: "bird.fill",            color: Color(red: 0.96, green: 0.65, blue: 0.14)),
        .init(id: 531,  name: "Paramount+",  logoURL: URL(string: "https://image.tmdb.org/t/p/w92/h5DcR0J2EESLitnhR8xLG1QymTE.jpg"), logoSymbol: "mountain.2.fill",      color: Color(red: 0.00, green: 0.39, blue: 1.00)),
        .init(id: 73,   name: "Tubi",        logoURL: URL(string: "https://image.tmdb.org/t/p/w92/zLYr7OPvpskMA4S79E3vlCi71iC.jpg"), logoSymbol: "tv.circle.fill",       color: Color(red: 0.96, green: 0.35, blue: 0.08)),
        .init(id: 99,   name: "Shudder",     logoURL: URL(string: "https://image.tmdb.org/t/p/w92/vEtdiYRPRbDCp1Tcn3BEPF1Ni76.jpg"), logoSymbol: "moon.fill",            color: Color(red: 0.55, green: 0.00, blue: 0.55)),
    ]

    /// Compact title for Watch Now horizontal chips.
    var watchNowChipTitle: String {
        switch id {
        case 8: return "Netflix"
        case 9: return "Prime"
        case 337: return "Disney+"
        case 15: return "Hulu"
        case 1899: return "Max"
        case 350: return "Apple TV+"
        case 386: return "Peacock"
        case 531: return "Paramount+"
        case 73: return "Tubi"
        case 99: return "Shudder"
        default: return name
        }
    }
}

// MARK: - StreamingPreferences

final class StreamingPreferences: ObservableObject {
    @Published var selectedServiceIds: Set<Int> = []

    /// Guest / pre-auth bucket — not shared with signed-in users (avoids stale Netflix, etc. on first login).
    static let guestStorageKey = "selected_streaming_services_v2"
    private static let legacyStorageKey = "selected_streaming_services"

    init() {
        load()
    }

    static func storageKey(userId: String?) -> String {
        if let userId { return "\(guestStorageKey)_\(userId)" }
        return guestStorageKey
    }

    var selectedServices: [StreamingService] {
        // Preserves the display order defined in StreamingService.all
        StreamingService.all.filter { selectedServiceIds.contains($0.id) }
    }

    func toggle(_ service: StreamingService) {
        if selectedServiceIds.contains(service.id) {
            selectedServiceIds.remove(service.id)
        } else {
            selectedServiceIds.insert(service.id)
        }
        save()
    }

    func isSelected(_ service: StreamingService) -> Bool {
        selectedServiceIds.contains(service.id)
    }

    func clearAll() {
        selectedServiceIds.removeAll()
        save()
    }

    /// Reload from disk for the active account (call after sign-in / sign-out).
    func reloadFromStorage() {
        load()
    }

    // Determines whether a movie should appear given the current filter.
    // Empty selection = no filter active = every movie passes (show all US titles).
    // Used by Watch Now's TMDB query (via providerIds) and by unit tests to verify behavior.
    func moviePassesServiceFilter(availableServiceIds: Set<Int>) -> Bool {
        selectedServiceIds.isEmpty || !selectedServiceIds.isDisjoint(with: availableServiceIds)
    }

    private func save() {
        UserDefaults.standard.set(Array(selectedServiceIds), forKey: Self.storageKey(userId: AccountLocalState.lastSignedInUserId))
    }

    private func load() {
        let ud = UserDefaults.standard
        let key = Self.storageKey(userId: AccountLocalState.lastSignedInUserId)
        let saved = ud.array(forKey: key) as? [Int] ?? []
        let valid = Set(StreamingService.all.map(\.id))
        selectedServiceIds = Set(saved).intersection(valid)
    }

    /// Clears guest, legacy, and all per-user streaming filter keys (e.g. on account switch).
    static func clearAllPersistedSelections() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: guestStorageKey)
        ud.removeObject(forKey: legacyStorageKey)
        for key in ud.dictionaryRepresentation().keys where key.hasPrefix("\(guestStorageKey)_") {
            ud.removeObject(forKey: key)
        }
    }
}

// MARK: - ServiceRow

// Full-width horizontal tile for single-column lists (picker + Services tab).
struct ServiceRow: View {
    let svc:        StreamingService
    let isSelected: Bool
    let onTap:      () -> Void
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(svc.color)
                .frame(width: isSelected ? 2 : 0)
                .clipped()

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(svc.color.opacity(0.2))
                    AsyncImage(url: svc.logoURL) { phase in
                        switch phase {
                        case .empty:
                            Color.clear
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Color.clear
                        @unknown default:
                            Color.clear
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(isSelected ? 1.0 : 0.45)

                Text(svc.name)
                    .font(AppTheme.rowTitle)
                    .foregroundStyle(Color.primary.opacity(isSelected ? 1.0 : 0.45))

                Spacer(minLength: 0)

                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(svc.color)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
        }
        .frame(height: 68)
        .frame(maxWidth: .infinity)
        .background(isSelected ? svc.color.opacity(0.07) : Color.clear)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                isPressed = true
            }
            onTap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                    isPressed = false
                }
            }
        }
    }
}

// MARK: - ServicesPickerView
// Used in onboarding (onContinue provided) and Settings sheet (onContinue nil — toolbar handles dismissal).

struct ServicesPickerView: View {
    @ObservedObject var prefs: StreamingPreferences
    // Pass a closure to show a Continue/Skip button at the bottom (onboarding use).
    // Pass nil when a toolbar Done button handles dismissal (settings sheet use).
    var onContinue: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if onContinue != nil {
                VStack(spacing: 6) {
                    Text("Your streaming services")
                        .font(.system(size: 22, weight: .bold, design: .default))
                    Text("We’ll prioritize picks you can stream today.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(StreamingService.all.enumerated()), id: \.element.id) { index, svc in
                        ServiceRow(
                            svc: svc,
                            isSelected: prefs.isSelected(svc),
                            onTap: { withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { prefs.toggle(svc) } }
                        )
                        if index < StreamingService.all.count - 1 {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: AppTheme.cardShadowColor.opacity(0.28), radius: 14, x: 0, y: 6)
                .padding(.horizontal, 20)
            }

            if let cont = onContinue {
                VStack(spacing: 10) {
                    if !prefs.selectedServiceIds.isEmpty {
                        Text("\(prefs.selectedServiceIds.count) service\(prefs.selectedServiceIds.count == 1 ? "" : "s") selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button(prefs.selectedServiceIds.isEmpty ? "Skip for now" : "Continue →") {
                        cont()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(24)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - ServicesTabView
// The standalone tab for quick service selection. Lives between Watch Now and Settings.

struct ServicesTabView: View {
    @EnvironmentObject var prefs: StreamingPreferences
    /// When set (e.g. modal from Watch Now), show a Done button to dismiss the sheet.
    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        ForEach(Array(StreamingService.all.enumerated()), id: \.element.id) { index, svc in
                            ServiceRow(
                                svc: svc,
                                isSelected: prefs.isSelected(svc),
                                onTap: { withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { prefs.toggle(svc) } }
                            )
                            if index < StreamingService.all.count - 1 {
                                Divider()
                                    .padding(.leading, 72)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.cardShadowColor.opacity(0.28), radius: 14, x: 0, y: 6)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("United States", systemImage: "globe.americas.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: prefs.selectedServiceIds.isEmpty
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                                .foregroundStyle(prefs.selectedServiceIds.isEmpty ? Color.secondary : Color.accentColor)
                            Group {
                                if prefs.selectedServiceIds.isEmpty {
                                    Text("All US titles — no filter")
                                } else {
                                    Text("\(prefs.selectedServiceIds.count) service\(prefs.selectedServiceIds.count == 1 ? "" : "s") selected")
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(prefs.selectedServiceIds.isEmpty ? Color.secondary : Color.primary)

                            Spacer()

                            if !prefs.selectedServiceIds.isEmpty {
                                Button("Clear") {
                                    withAnimation { prefs.clearAll() }
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 2)

                        Text("Watch Now uses this list to match availability. Leave empty to include every US streaming title.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Services")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if let onDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { onDismiss() }
                    }
                }
                if !prefs.selectedServiceIds.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Text("\(prefs.selectedServiceIds.count) selected")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Services Tab") {
    ServicesTabView()
        .environmentObject(StreamingPreferences())
}

#Preview("Services Picker — Onboarding") {
    ServicesPickerView(prefs: StreamingPreferences()) {}
}

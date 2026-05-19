// ProfileSetupView.swift
// Post-login wizard that collects the demographic profile.
// This is the data that makes Pickr valuable to content companies.
// Three steps: demographics → streaming preferences (already set) → consent.

import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject private var auth: AuthManager
    var onComplete: () -> Void

    @State private var step: Int = 0
    @State private var draft: UserProfile

    // Step 0 — demographics
    @State private var selectedAgeGroup: AgeGroup?
    @State private var selectedGender: Gender?
    @State private var selectedCountry: String = Locale.current.region?.identifier ?? ""

    // Step 1 — consent
    @State private var marketingConsent = false
    @State private var dataShareConsent = false

    @State private var appeared = false

    init(profile: UserProfile, onComplete: @escaping () -> Void) {
        _draft = State(initialValue: profile)
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()
            RadialGradient(
                colors: [Color.red.opacity(0.15), Color.clear],
                center: .top, startRadius: 40, endRadius: 280
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                progressBar
                    .padding(.horizontal, 28)
                    .padding(.top, 56)
                    .padding(.bottom, 32)

                // Step content — full width so multi-line Text wraps instead of truncating
                Group {
                    switch step {
                    case 0: demographicsStep
                    default: consentStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.easeOut(duration: 0.35), value: appeared)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear {
            appeared = false
            withAnimation(.easeOut(duration: 0.45).delay(0.05)) { appeared = true }
        }
        .onChange(of: step) { _, _ in
            appeared = false
            withAnimation(.easeOut(duration: 0.35).delay(0.05)) { appeared = true }
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.red : Color.white.opacity(0.15))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.35), value: step)
            }
        }
    }

    // MARK: - Step 0: Demographics

    private var demographicsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tell us about yourself")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

            Text("We use this to improve your recommendations\nand power Pickr's research product.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 32)

            // Age group
            sectionHeader("Age Group")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AgeGroup.allCases) { group in
                        chipButton(group.rawValue, selected: selectedAgeGroup == group) {
                            selectedAgeGroup = group
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 28)

            // Gender
            sectionHeader("Gender")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Gender.allCases) { g in
                        chipButton(g.rawValue, selected: selectedGender == g) {
                            selectedGender = g
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 28)

            // Country
            sectionHeader("Country")
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.white.opacity(0.45))
                    .font(.system(size: 16))
                    .frame(width: 28)

                // Native picker for the country list
                Picker("Country", selection: $selectedCountry) {
                    ForEach(countryCodes, id: \.code) { item in
                        Text(item.name).tag(item.code)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white.opacity(0.75))
                .font(.system(size: 16))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .padding(.horizontal, 28)

            Spacer().frame(height: 36)

            // Continue
            primaryButton("Continue") {
                // Save demographics to draft
                draft.ageGroup = selectedAgeGroup
                draft.gender   = selectedGender
                draft.country  = selectedCountry.isEmpty ? nil : selectedCountry
                withAnimation { step = 1 }
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Step 1: Consent

    private var consentStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your data, your choice")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

            Text("Pickr partners with content studios and streaming platforms who use anonymous, aggregated data to make better movies and shows.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 32)

            // What data is shared card
            VStack(alignment: .leading, spacing: 12) {
                Text("What gets shared")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                    .textCase(.uppercase)
                    .tracking(0.8)

                dataPointRow(icon: "person.fill",         label: "Age group & gender",
                             detail: "e.g. 25–34, Female")
                dataPointRow(icon: "globe",               label: "Country",
                             detail: "e.g. United States")
                dataPointRow(icon: "film.fill",           label: "Genre preferences",
                             detail: "What you like/dislike")
                dataPointRow(icon: "hand.thumbsup.fill",  label: "Swipe behavior",
                             detail: "Movies you said yes or no to")
                dataPointRow(icon: "play.rectangle.fill", label: "Streaming services",
                             detail: "What platforms you use")

                Divider().background(Color.white.opacity(0.08)).padding(.vertical, 4)

                Text("Your name, email, and exact identity are never shared.")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(Color(red: 0.45, green: 0.88, blue: 0.55))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 28)
            .padding(.bottom, 28)

            // Toggles
            consentToggle(
                title: "Share my anonymous data",
                subtitle: "Help studios understand what audiences want",
                isOn: $dataShareConsent
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            consentToggle(
                title: "Send me relevant updates",
                subtitle: "Occasional emails about new features (optional)",
                isOn: $marketingConsent
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 32)

            // CTA
            primaryButton("Start Discovering →") {
                var finished = draft
                finished.dataShareConsent  = dataShareConsent
                finished.marketingConsent  = marketingConsent
                finished.consentDate       = Date()
                finished.profileComplete   = true
                auth.updateProfile(finished)
                onComplete()
            }
            .padding(.horizontal, 28)

            // Skip
            Button {
                var finished = draft
                finished.profileComplete = true
                auth.updateProfile(finished)
                onComplete()
            } label: {
                Text("Skip for now")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.62))
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
    }

    private func chipButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .black : .white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(selected ? Color.red : Color.white.opacity(0.09))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    private func dataPointRow(icon: String, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.red.opacity(0.8))
                .frame(width: 20, alignment: .top)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consentToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .tint(AppTheme.brand)
                .labelsHidden()
        }
        .padding(16)
        .background(Color.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Country list (abbreviated — add more as needed)

private struct CountryItem { let code: String; let name: String }

private let countryCodes: [CountryItem] = Locale.Region.isoRegions
    .compactMap { region -> CountryItem? in
        let code = region.identifier
        guard let name = Locale(identifier: "en_US").localizedString(forRegionCode: code) else { return nil }
        return CountryItem(code: code, name: name)
    }
    .sorted { $0.name < $1.name }

#Preview {
    ProfileSetupView(profile: UserProfile(id: UUID().uuidString)) {}
        .environmentObject(AuthManager.shared)
}

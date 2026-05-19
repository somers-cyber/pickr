// SupabaseConfig.swift
// Reads Supabase URL + API key (publishable or legacy anon JWT) from Info.plist via xcconfig.

import Foundation

enum SupabaseConfig {
    static var url: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("YOUR_PROJECT_REF") else { return nil }
        return URL(string: trimmed)
    }

    static var anonKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "your_supabase_anon_key_here",
              !trimmed.contains("YOUR_KEY_HERE") else { return nil }
        return trimmed
    }

    static var isConfigured: Bool { url != nil && anonKey != nil }
}

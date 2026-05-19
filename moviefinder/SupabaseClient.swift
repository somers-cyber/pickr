// SupabaseClient.swift
// Shared Supabase client (nil when URL/key are not configured).

import Foundation
import Supabase

enum SupabaseClientProvider {
  private static var _client: SupabaseClient?

  static var client: SupabaseClient? {
    if let _client { return _client }
    guard let url = SupabaseConfig.url, let key = SupabaseConfig.anonKey else { return nil }
    let c = SupabaseClient(
      supabaseURL: url,
      supabaseKey: key,
      options: SupabaseClientOptions(
        auth: .init(emitLocalSessionAsInitialSession: true)
      )
    )
    _client = c
    return c
  }

  static var isConfigured: Bool { SupabaseConfig.isConfigured && client != nil }

  static func reset() {
    _client = nil
  }
}

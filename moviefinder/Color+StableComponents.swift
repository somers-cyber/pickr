// Color+StableComponents.swift
// Safe SwiftUI colors for dynamic ids — avoids UIColor warnings when hue/RGB components are out of 0…1.

import SwiftUI

extension Color {
    /// Placeholder fill from a TMDB (or other) id. Negative ids are possible; Swift’s `%` can yield a negative
    /// remainder, which would pass a **negative hue** into `Color(hue:…)` and log “component values far outside the expected range”.
    static func stablePlaceholderHue(
        for id: Int,
        saturation: Double = 0.45,
        brightness: Double = 0.30
    ) -> Color {
        let hue = Double((id % 360 + 360) % 360) / 360.0
        let s = saturation.clampedToUnit
        let b = brightness.clampedToUnit
        return Color(hue: hue, saturation: s, brightness: b)
    }

    /// RGB in 0…1; clamps each component so UIKit bridging never sees out-of-range values.
    static func safeRGB(red: Double, green: Double, blue: Double, opacity: Double = 1) -> Color {
        Color(
            red: red.clampedToUnit,
            green: green.clampedToUnit,
            blue: blue.clampedToUnit,
            opacity: opacity.clampedToUnit
        )
    }
}

private extension Double {
    var clampedToUnit: Double { min(1, max(0, self)) }
}

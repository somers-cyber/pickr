// DeviceMetadata.swift
// Non-sensitive device / locale fields allowed without extra permissions.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct DeviceMetadata: Codable, Equatable {
    var country: String?
    var language: String?
    var osVersion: String?
    var deviceModel: String?
    var appVersion: String?

    static func current() -> DeviceMetadata {
        var meta = DeviceMetadata()
        meta.country = Locale.current.region?.identifier
        meta.language = Locale.preferredLanguages.first
        #if canImport(UIKit)
        meta.osVersion = UIDevice.current.systemVersion
        meta.deviceModel = UIDevice.current.model
        #endif
        meta.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return meta
    }
}

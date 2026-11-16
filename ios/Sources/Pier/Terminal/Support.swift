import SwiftUI
import UIKit

// What Appearance.swift and AppearanceViews.swift expect of
// the app around them.

typealias PlatformColor = UIColor
typealias PlatformFont = UIFont

extension Color {
    init(platform c: PlatformColor) { self.init(uiColor: c) }
}

enum Paths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Kept for Appearance's settings; Pier has no typing prediction.
enum PredictMode: String, CaseIterable, Identifiable {
    case auto, always, off
    var id: String { rawValue }
}

/// An error with a message, as the appearance code throws it.
struct TmxError: LocalizedError {
    var errorDescription: String?
}
struct TmuxWindow: Codable, Hashable {
    var index: Int
    var name: String
    var active: Bool
    var bell: Bool
    var activity: Int64
    var panes: Int
    var command: String
    var sync: Bool
    var width: Int      // of the active pane, in cells
    var height: Int
}

import AppKit

@MainActor
enum AppearanceController {
    static func apply(_ mode: AppearanceMode) {
        NSApplication.shared.appearance = appearance(for: mode)
    }

    static func current() -> NSAppearance? {
        NSApplication.shared.appearance
    }

    private static func appearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

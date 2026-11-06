import Foundation

// MARK: - Localization

/// Looks a user-visible string up in `Localizable.strings`.
///
/// SwiftUI localizes literals passed to `Text`, `Button`, `Label`, `Toggle`,
/// `Picker`, `TextField`, `.help(_:)` and friends on its own. Use `L` for the
/// places SwiftUI cannot see a `LocalizedStringKey`: AppKit alerts, panels and
/// menu items, toast/status strings, `LocalizedError` descriptions, and strings
/// that are built dynamically before reaching a view.
///
/// The key is the English source text, with `%@` for string arguments and
/// `%lld` for integer arguments — for example:
///
///     showToast(L("Opened in %@ at line %lld", appName, line))
///
/// The same string therefore appears in `Text("…")` (no call change) and in
/// `L("…")` (explicit call). One English source, one translation per language.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments)
}

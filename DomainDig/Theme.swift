import SwiftUI

/// One of the app's semantic colours, named rather than resolved.
///
/// A token instead of a `Color` so a colour chosen outside a view body — a
/// status badge's model, for one — can say which colour it means and leave the
/// resolving to the view that draws it. That is what lets the whole palette sit
/// in the environment rather than only the parts used inside `body`.
///
/// The case names drop the `app`/`status` prefixes that the colorsets carry so
/// they do not collide with the style accessors below, which keep the prefixed
/// spelling the call sites already used. The raw value is the colorset's name.
nonisolated enum ThemeToken: String, CaseIterable, Sendable {
    case background = "AppBackground"
    case surface = "AppSurface"
    case surfaceElevated = "AppSurfaceElevated"
    case textSecondary = "AppTextSecondary"
    case separator = "AppSeparator"
    case onAccent = "AppOnAccent"
    case accent = "AccentFill"
    case positive = "StatusPositive"
    case positiveSurface = "StatusPositiveSurface"
    case warning = "StatusWarning"
    case warningSurface = "StatusWarningSurface"
    case critical = "StatusCritical"
    case criticalSurface = "StatusCriticalSurface"
    case info = "StatusInfo"
    case infoSurface = "StatusInfoSurface"
    case neutral = "StatusNeutral"
    case neutralSurface = "StatusNeutralSurface"

    /// The palette in `Shared/Colors.xcassets`, which stays the single
    /// definition of every default colour.
    ///
    /// `Docs/ACCESSIBILITY.txt` names that palette as the guard against
    /// contrast regressions, and reading the defaults from it here is what
    /// keeps the guard: a theme overrides individual tokens, it does not
    /// replace the set.
    ///
    /// Looked up by name rather than through the generated `ColorResource`
    /// symbols, which are MainActor-isolated and so cannot be read from
    /// `ShapeStyle.resolve(in:)`. `ThemeTests` asserts that every token still
    /// has a colorset and that no colorset is left without a token.
    var assetColor: Color {
        Color(rawValue, bundle: .main)
    }
}

/// A token is itself a style, so it can be handed straight to `foregroundStyle`,
/// `background`, `tint` or `fill` and resolve against the environment's theme
/// when the view draws.
///
/// This is what keeps the refactor from adding an `@Environment(\.theme)`
/// property to every view in the app: in a style position the token needs no
/// one to resolve it. Only a colour used as a plain value — a list row's
/// background, which takes a view rather than a style — needs the environment
/// read explicitly.
nonisolated extension ThemeToken: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.theme[self]
    }
}

/// The colours a screen draws with.
///
/// Carried in the environment so an accent choice reaches every view without
/// threading a parameter. The default resolves every token from the asset
/// catalog, so an app with no theme chosen renders exactly as it did before
/// this existed.
nonisolated struct Theme: Equatable, Sendable {
    /// What this theme changes about the palette. Empty for the default.
    private let overrides: [ThemeToken: Color]

    init(overrides: [ThemeToken: Color] = [:]) {
        self.overrides = overrides
    }

    static let `default` = Theme()

    subscript(token: ThemeToken) -> Color {
        overrides[token] ?? token.assetColor
    }

    /// For the few places that need a `Color` rather than a style, such as a
    /// list row's background.
    var appBackground: Color { self[.background] }
    var appSurface: Color { self[.surface] }
    var appSurfaceElevated: Color { self[.surfaceElevated] }
    var appTextSecondary: Color { self[.textSecondary] }
    var accentFill: Color { self[.accent] }
}

/// An accent a user can pick.
///
/// Only the accent tokens are overridden. The status colours keep their palette
/// values deliberately: "critical" means one thing, and letting an accent
/// recolour it would undo the contrast work phases 1–5 of #21 did and leave the
/// palette no longer answerable for its own contrast.
nonisolated enum AccentTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case `default`
    case graphite
    case forest
    case plum

    static let userDefaultsKey = "appAccentTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .graphite: return "Graphite"
        case .forest: return "Forest"
        case .plum: return "Plum"
        }
    }

    var theme: Theme {
        guard let fill = accentFill else { return .default }
        return Theme(overrides: [.accent: fill, .onAccent: .white])
    }

    private var accentFill: Color? {
        switch self {
        case .default:
            return nil
        case .graphite:
            return Color(red: 0.26, green: 0.28, blue: 0.31)
        case .forest:
            return Color(red: 0.13, green: 0.40, blue: 0.27)
        case .plum:
            return Color(red: 0.42, green: 0.20, blue: 0.44)
        }
    }
}

extension AccentTheme {
    /// The alternate app icon for this accent, or `nil` for the primary one.
    ///
    /// The names match the asset catalog's icon sets, which
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` lists.
    var alternateIconName: String? {
        switch self {
        case .default: return nil
        case .graphite: return "AppIconGraphite"
        case .forest: return "AppIconForest"
        case .plum: return "AppIconPlum"
        }
    }
}

/// Keeps the home-screen icon on whichever accent is in force.
///
/// The icon follows the accent rather than being a second picker: iOS shows its
/// own "You have changed the icon" alert on every change and there is no public
/// way to suppress it, so two pickers would mean two alerts for what a user
/// thinks of as one choice.
@MainActor
enum AppIconController {
    /// Idempotent, so it is safe to call on launch as well as on change —
    /// which is what reverts the icon when a lapsed tier drops the accent back
    /// to default.
    static func apply(_ accent: AccentTheme) {
        guard UIApplication.shared.supportsAlternateIcons else { return }

        let desired = accent.alternateIconName
        guard UIApplication.shared.alternateIconName != desired else { return }

        UIApplication.shared.setAlternateIconName(desired) { error in
            guard let error else { return }
            DomainDebugLog.error("AppIcon.setFailed name=\(desired ?? "primary") error=\(error.localizedDescription)")
        }
    }
}

nonisolated private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.default
}

extension EnvironmentValues {
    /// Nonisolated so `ShapeStyle.resolve(in:)`, which is itself nonisolated,
    /// can read it.
    nonisolated var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// `listRowBackground` takes a view rather than a style, so a token cannot be
/// handed to it directly — it has to be resolved first, which needs the
/// environment. This is the one place in the app that reads the theme to get a
/// `Color` rather than passing a token as a style.
private struct ThemedListRowBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let token: ThemeToken

    func body(content: Content) -> some View {
        content.listRowBackground(theme[token])
    }
}

extension View {
    func themedListRowBackground(_ token: ThemeToken) -> some View {
        modifier(ThemedListRowBackground(token: token))
    }
}

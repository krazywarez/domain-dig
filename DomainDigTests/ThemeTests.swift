import SwiftUI
import XCTest
@testable import DomainDig

/// The palette moved from 483 asset-catalog call sites into a `Theme` carried
/// in the environment (I1's sibling, W13).
///
/// The one safety the move gave up is compile-time checking of the colour
/// names: `ThemeToken.assetColor` looks them up by string, because the
/// generated `ColorResource` symbols are MainActor-isolated and
/// `ShapeStyle.resolve(in:)` is not. `testEveryTokenHasAColorset` and
/// `testNoColorsetIsMissingAToken` are what replace it.
final class ThemeTests: XCTestCase {

    /// The colorsets on disk, which are the palette's definition.
    private func colorsetNames() throws -> Set<String> {
        // The bundle under test is the app's, and the catalog is compiled into
        // it, so the names are read from the source tree instead.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Colors.xcassets")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return Set(
            entries
                .filter { $0.hasSuffix(".colorset") }
                .map { String($0.dropLast(".colorset".count)) }
        )
    }

    func testEveryTokenHasAColorset() throws {
        let names = try colorsetNames()

        for token in ThemeToken.allCases {
            XCTAssertTrue(
                names.contains(token.rawValue),
                "\(token) names '\(token.rawValue)', which is not a colorset — it would render as a placeholder"
            )
        }
    }

    /// The other direction: a colour added to the catalog without a token is
    /// unreachable through the theme, so it cannot be themed and nothing says
    /// so.
    func testNoColorsetIsMissingAToken() throws {
        let names = try colorsetNames()
        let tokens = Set(ThemeToken.allCases.map(\.rawValue))

        XCTAssertEqual(
            names.subtracting(tokens),
            [],
            "these colorsets have no ThemeToken, so the theme cannot reach them"
        )
    }

    // MARK: Defaults

    /// The default theme has to render exactly as the asset catalog did, or the
    /// refactor changed the app's appearance rather than only its plumbing.
    func testTheDefaultThemeResolvesEveryTokenFromTheCatalog() {
        let theme = Theme.default

        for token in ThemeToken.allCases {
            XCTAssertEqual(theme[token], token.assetColor, "\(token) should come straight from the catalog")
        }
    }

    func testAnEmptyOverrideSetIsTheDefault() {
        XCTAssertEqual(Theme(overrides: [:]), Theme.default)
    }

    // MARK: Accents

    func testTheDefaultAccentOverridesNothing() {
        XCTAssertEqual(AccentTheme.default.theme, Theme.default)
    }

    /// An accent changes the accent and nothing else. Letting it reach the
    /// status colours would undo the contrast work phases 1–5 of #21 did.
    func testAnAccentOverridesOnlyTheAccentTokens() {
        for accent in AccentTheme.allCases where accent != .default {
            let theme = accent.theme

            XCTAssertNotEqual(theme[.accent], ThemeToken.accent.assetColor, "\(accent) should change the accent")

            for token in ThemeToken.allCases where token != .accent && token != .onAccent {
                XCTAssertEqual(
                    theme[token],
                    token.assetColor,
                    "\(accent) must leave \(token) alone"
                )
            }
        }
    }

    func testEveryAccentHasATitle() {
        for accent in AccentTheme.allCases {
            XCTAssertFalse(accent.title.isEmpty)
            XCTAssertEqual(AccentTheme(rawValue: accent.rawValue), accent, "the stored value round-trips")
        }
    }

    /// Accent themes are Pro+ per D1. Pro+ takes `allCases`, so the check that
    /// matters is that the capability did not land in free or pro.
    func testAccentThemesArePrOPlusOnly() {
        XCTAssertFalse(FeatureAccessService.entitlements(for: .free).capabilities.contains(.accentTheme))
        XCTAssertFalse(FeatureAccessService.entitlements(for: .pro).capabilities.contains(.accentTheme))
        XCTAssertTrue(FeatureAccessService.entitlements(for: .proPlus).capabilities.contains(.accentTheme))
        XCTAssertEqual(FeatureAccessService.upgradeMessage(for: .accentTheme), "Available in Pro+")
    }

    // MARK: App icons

    /// The alternate icon names are strings matched against the asset catalog
    /// at runtime, so a typo fails the same silent way a wrong colorset name
    /// would — `setAlternateIconName` just reports an error and the icon stays
    /// put. This is the parity check for them.
    func testEveryAccentsIconNameHasAnIconSet() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DomainDig/Assets.xcassets")
        let sets = Set(
            try FileManager.default.contentsOfDirectory(atPath: catalog.path)
                .filter { $0.hasSuffix(".appiconset") }
                .map { String($0.dropLast(".appiconset".count)) }
        )

        for accent in AccentTheme.allCases {
            guard let name = accent.alternateIconName else { continue }
            XCTAssertTrue(sets.contains(name), "\(accent) names '\(name)', which is not an icon set")
        }

        // And the other direction: an icon set nothing selects is dead weight
        // in the bundle.
        let named = Set(AccentTheme.allCases.compactMap(\.alternateIconName)).union(["AppIcon"])
        XCTAssertEqual(sets.subtracting(named), [], "these icon sets are unreachable")
    }

    /// The default accent uses the primary icon, which is what `nil` means to
    /// `setAlternateIconName`.
    func testTheDefaultAccentUsesThePrimaryIcon() {
        XCTAssertNil(AccentTheme.default.alternateIconName)
        for accent in AccentTheme.allCases where accent != .default {
            XCTAssertNotNil(accent.alternateIconName, "\(accent) should have its own icon")
        }
    }

    // MARK: Badge models carry tokens

    /// The badges are built outside a view body, which is why their colours are
    /// tokens rather than resolved values.
    func testStatusBadgesNameTokensRatherThanColors() {
        let registered = AppStatusFactory.availability(.registered)
        XCTAssertFalse(registered.title.isEmpty)

        // A token, so the theme resolves it at draw time.
        XCTAssertEqual(Theme.default[registered.foreground], registered.foreground.assetColor)
        XCTAssertEqual(Theme.default[registered.background], registered.background.assetColor)
    }

    func testEveryToneMapsToATokenPair() {
        for tone in [AppStatusTone.positive, .warning, .critical, .info, .neutral] {
            XCTAssertNotEqual(tone.foreground, tone.surface, "\(tone) should not use one colour for both")
        }
    }
}

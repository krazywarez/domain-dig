import XCTest
@testable import DomainDig

/// The measured ratios in `Docs/ACCESSIBILITY.txt` were prose, while
/// `AccessibilityAuditHarness` names the centralised palette as "the actual
/// guard against contrast regressions" — the reason `.contrast` is allowed to
/// stay report-only in the audit. Nothing checked the palette, so the guard was
/// a claim. This is the check.
///
/// Read from the colorsets rather than resolved `UIColor`s, for the reason
/// `ThemeTests` gives: the catalog is compiled into the app bundle, and the
/// source tree is the palette's definition.
final class PaletteContrastTests: XCTestCase {

    /// WCAG AA for body text.
    private let minimumRatio = 4.5

    /// Each status foreground and the surfaces it is drawn on: the page, a
    /// card, and its own badge fill — `AppStatusBadgeView` draws
    /// `theme[foreground]` over `theme[background]`, paired by `AppStatusTone`.
    private let pairings: [(foreground: String, badge: String)] = [
        ("StatusInfo", "StatusInfoSurface"),
        ("StatusPositive", "StatusPositiveSurface"),
        ("StatusWarning", "StatusWarningSurface"),
        ("StatusCritical", "StatusCriticalSurface"),
        ("StatusNeutral", "StatusNeutralSurface")
    ]

    func testEveryStatusForegroundClearsAAOnEverySurfaceItIsDrawnOn() throws {
        for appearance in Appearance.allCases {
            let background = try components("AppBackground", appearance)
            let surface = try components("AppSurface", appearance)

            for pairing in pairings {
                let foreground = try components(pairing.foreground, appearance)
                let badge = try components(pairing.badge, appearance)

                for (name, against) in [("page", background), ("card", surface), ("badge", badge)] {
                    let ratio = contrastRatio(foreground, against)
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        minimumRatio,
                        "\(pairing.foreground) on its \(name) in \(appearance) is \(rounded(ratio)):1"
                    )
                }
            }
        }
    }

    /// `AppTextSecondary` exists because iOS's own `secondaryLabel` is 3.29:1
    /// on a light card. A regression here would reintroduce that across the
    /// body text it replaced.
    func testSecondaryTextClearsAAOnThePageAndOnACard() throws {
        for appearance in Appearance.allCases {
            let secondary = try components("AppTextSecondary", appearance)

            for name in ["AppBackground", "AppSurface", "AppSurfaceElevated"] {
                let ratio = try contrastRatio(secondary, components(name, appearance))
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    minimumRatio,
                    "AppTextSecondary on \(name) in \(appearance) is \(rounded(ratio)):1"
                )
            }
        }
    }

    /// `AppOnAccent` is drawn over `StatusInfo`, by the selected Dashboard
    /// filter chip — the only site that uses it. It is deliberately white in
    /// light and black in dark, because `StatusInfo` goes from `#0000FF` to
    /// `#4DA3FF` and the readable foreground flips with it.
    ///
    /// Not asserted against `AccentFill`, which nothing pairs it with:
    /// `accentFill` is passed to `.tint`, where iOS picks its own label colour.
    /// Were anything to start drawing that pair, note that black on the dark
    /// `AccentFill` (`#0040DD`) measures 2.78:1 and would need white instead.
    func testTextOnTheSelectedChipClearsAA() throws {
        for appearance in Appearance.allCases {
            let ratio = try contrastRatio(
                components("AppOnAccent", appearance),
                components("StatusInfo", appearance)
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimumRatio,
                "AppOnAccent on StatusInfo in \(appearance) is \(rounded(ratio)):1"
            )
        }
    }

    // MARK: Colorsets

    private enum Appearance: String, CaseIterable {
        case light
        case dark
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// The sRGB components a colorset defines for one appearance.
    ///
    /// The light entry is the one with no `appearances` key; the dark entry
    /// carries `luminosity: dark`. High-contrast variants are skipped: they
    /// only ever push further in the same direction, so the base values are the
    /// worst case.
    private func components(_ name: String, _ appearance: Appearance) throws -> RGB {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Colors.xcassets/\(name).colorset/Contents.json")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let colors = parsed?["colors"] as? [[String: Any]] ?? []

        let entry = colors.first { entry in
            let appearances = entry["appearances"] as? [[String: Any]] ?? []
            if appearances.contains(where: { ($0["appearance"] as? String) == "contrast" }) {
                return false
            }
            let isDark = appearances.contains { $0["appearance"] as? String == "luminosity" && $0["value"] as? String == "dark" }
            return appearance == .dark ? isDark : appearances.isEmpty
        }

        let raw = try XCTUnwrap(
            (entry?["color"] as? [String: Any])?["components"] as? [String: String],
            "\(name) has no \(appearance) components"
        )
        return RGB(
            red: try channel(raw["red"], in: name),
            green: try channel(raw["green"], in: name),
            blue: try channel(raw["blue"], in: name)
        )
    }

    /// Xcode writes these as `0xAD`, but a catalog edited by hand can hold a
    /// decimal or a float, so all three are accepted and anything else fails
    /// loudly rather than silently measuring black.
    private func channel(_ raw: String?, in name: String) throws -> Double {
        let value = try XCTUnwrap(raw, "\(name) is missing a channel")
        if value.hasPrefix("0x") {
            return Double(try XCTUnwrap(UInt8(value.dropFirst(2), radix: 16), "\(name): bad hex '\(value)'")) / 255
        }
        let number = try XCTUnwrap(Double(value), "\(name): bad component '\(value)'")
        return number > 1 ? number / 255 : number
    }

    // MARK: WCAG

    private func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let a = relativeLuminance(lhs)
        let b = relativeLuminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// WCAG 2.1 relative luminance.
    private func relativeLuminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private func rounded(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

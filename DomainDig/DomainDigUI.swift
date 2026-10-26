import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// User-selected appearance, applied once at the `WindowGroup`.
///
/// Deliberately applied in exactly one place. The app previously carried 16
/// separate `.preferredColorScheme(.dark)` calls scattered across view bodies,
/// which is how it became impossible to reach light mode at all — re-applying
/// per view is what let the lock spread unnoticed.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let userDefaultsKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    /// `nil` hands control back to the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AppDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    static let userDefaultsKey = "appDensity"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .comfortable:
            return "Comfortable"
        }
    }

    var metrics: AppDensityMetrics {
        switch self {
        case .compact:
            return AppDensityMetrics(
                sectionSpacing: 14,
                cardSpacing: 6,
                cardPadding: 10,
                rowSpacing: 4,
                rowMinHeight: 30,
                controlVerticalPadding: 10,
                // Was 42, which put every control using it under the 44pt
                // minimum in compact density — section headers, Run, Run Batch.
                controlMinHeight: AppLayout.minimumTapTarget,
                cardCornerRadius: 10
            )
        case .comfortable:
            return AppDensityMetrics(
                sectionSpacing: 18,
                cardSpacing: 10,
                cardPadding: 14,
                rowSpacing: 7,
                rowMinHeight: 38,
                controlVerticalPadding: 14,
                controlMinHeight: 48,
                cardCornerRadius: 14
            )
        }
    }

    func font(_ textStyle: Font.TextStyle, design: Font.Design = .monospaced, weight: Font.Weight? = nil) -> Font {
        var font = Font.system(textStyle, design: design)
        if let weight {
            font = font.weight(weight)
        }
        return font
    }
}

/// Layout constants that are not density-dependent.
enum AppLayout {
    /// The HIG minimum for an interactive control, and WCAG 2.5.8's floor.
    /// Controls scale up from here with Dynamic Type; none may sit below it.
    static let minimumTapTarget: CGFloat = 44
}

struct AppDensityMetrics: Equatable {
    let sectionSpacing: CGFloat
    let cardSpacing: CGFloat
    let cardPadding: CGFloat
    let rowSpacing: CGFloat
    let rowMinHeight: CGFloat
    let controlVerticalPadding: CGFloat
    let controlMinHeight: CGFloat
    let cardCornerRadius: CGFloat
}

private struct AppDensityKey: EnvironmentKey {
    static let defaultValue: AppDensity = .compact
}

extension EnvironmentValues {
    var appDensity: AppDensity {
        get { self[AppDensityKey.self] }
        set { self[AppDensityKey.self] = newValue }
    }
}

/// A status colour pairing: the foreground and the surface it sits on.
///
/// These travel together because they cannot be derived from one another. The
/// badge fill used to be `foreground.opacity(0.16)`, which forced every
/// foreground dark enough to stay legible against its own wash — that is how the
/// light palette ended up olive-and-mud rather than amber-and-green. Decoupling
/// them lets the foregrounds stay fully saturated.
///
/// See `Docs/ACCESSIBILITY.md` for the measured ratios.
enum AppStatusTone {
    case positive
    case warning
    case critical
    case info
    case neutral

    var foreground: ThemeToken {
        switch self {
        case .positive:
            return .positive
        case .warning:
            return .warning
        case .critical:
            return .critical
        case .info:
            return .info
        case .neutral:
            return .neutral
        }
    }

    var surface: ThemeToken {
        switch self {
        case .positive:
            return .positiveSurface
        case .warning:
            return .warningSurface
        case .critical:
            return .criticalSurface
        case .info:
            return .infoSurface
        case .neutral:
            return .neutralSurface
        }
    }
}

/// A badge's appearance, named rather than resolved.
///
/// The colours are `ThemeToken`s because every one of these is built outside a
/// view body — `AppStatusFactory` and the per-row helpers are plain functions —
/// so they cannot read the environment. `AppStatusBadgeView` resolves them when
/// it draws.
struct AppStatusBadgeModel: Equatable {
    let title: String
    let systemImage: String?
    let foreground: ThemeToken
    let background: ThemeToken
}

enum AppStatusFactory {
    static func availability(_ status: DomainAvailabilityStatus?) -> AppStatusBadgeModel {
        switch status {
        case .available:
            return .init(title: "Available", systemImage: "checkmark.circle.fill", foreground: .positive, background: .positiveSurface)
        case .registered:
            return .init(title: "Registered", systemImage: "circle.fill", foreground: .warning, background: .warningSurface)
        case .unknown, .none:
            return .init(title: "Unknown", systemImage: "questionmark.circle", foreground: .textSecondary, background: .surfaceElevated)
        }
    }

    static func tls(sslInfo: SSLCertificateInfo?, error: String?) -> AppStatusBadgeModel {
        if error != nil || sslInfo == nil {
            return .init(title: "Invalid", systemImage: "xmark.octagon.fill", foreground: .critical, background: .criticalSurface)
        }
        if let sslInfo, sslInfo.daysUntilExpiry <= 14 {
            return .init(title: "Expiring", systemImage: "exclamationmark.triangle.fill", foreground: .warning, background: .warningSurface)
        }
        return .init(title: "Valid", systemImage: "lock.fill", foreground: .positive, background: .positiveSurface)
    }

    static func email(_ result: EmailSecurityResult?, error: String?) -> AppStatusBadgeModel {
        guard error == nil, let result else {
            return .init(title: "Missing", systemImage: "minus.circle", foreground: .textSecondary, background: .surfaceElevated)
        }

        let foundCount = [result.spf.found, result.dmarc.found, result.dkim.found].filter { $0 }.count
        switch foundCount {
        case 3:
            return .init(title: "Secure", systemImage: "checkmark.shield.fill", foreground: .positive, background: .positiveSurface)
        case 1, 2:
            return .init(title: "Partial", systemImage: "shield.lefthalf.filled", foreground: .warning, background: .warningSurface)
        default:
            return .init(title: "Missing", systemImage: "minus.circle", foreground: .textSecondary, background: .surfaceElevated)
        }
    }

    static func change(_ summary: DomainChangeSummary?) -> AppStatusBadgeModel {
        guard let summary else {
            return .init(title: "Unchanged", systemImage: "circle", foreground: .textSecondary, background: .surfaceElevated)
        }
        if summary.hasChanges {
            return .init(title: "Changed", systemImage: "arrow.triangle.2.circlepath", foreground: .info, background: .infoSurface)
        }
        return .init(title: "Unchanged", systemImage: "checkmark.circle", foreground: .textSecondary, background: .surfaceElevated)
    }
}

struct AppStatusBadgeView: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.theme) private var theme

    let model: AppStatusBadgeModel

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage = model.systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(model.title)
        }
        // Never compress. Squeezed beside a long domain at accessibility sizes,
        // the capsule otherwise wraps one character per line into a
        // screen-height pill. Taking natural width instead forces the row's
        // ViewThatFits onto its stacked layout, which is the intended fallback.
        .fixedSize()
        .font(appDensity.font(.caption, weight: .semibold))
        .foregroundStyle(theme[model.foreground])
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(theme[model.background])
        .clipShape(Capsule())
        // Read as one word ("Critical"), not "icon, Critical". The symbol
        // duplicates the title for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
    }
}

struct AppCopyButton: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopy = false

    /// Grows with Dynamic Type. The `max(_, minimumTapTarget)` floor matters
    /// because `@ScaledMetric` also scales *down* below the default text size,
    /// which would push this back under the 44pt minimum.
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = AppLayout.minimumTapTarget

    let value: String
    let label: String

    var body: some View {
        Button {
            AppClipboard.copy(value)
            AppHaptics.copy()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                didCopy = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                await MainActor.run {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        didCopy = false
                    }
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(appDensity.font(.caption))
                .foregroundStyle(didCopy ? ThemeToken.positive : ThemeToken.textSecondary)
                .frame(width: max(size, AppLayout.minimumTapTarget), height: max(size, AppLayout.minimumTapTarget))
                .background(ThemeToken.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "\(label) copied" : label)
    }
}

enum AppClipboard {
    static func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

enum AppAccessibility {
    /// Speaks a status update through VoiceOver without moving focus. Used at
    /// lookup and sweep completion so a blind user hears the result land instead
    /// of having to hunt for whether anything changed.
    static func announce(_ message: String) {
        #if canImport(UIKit)
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
        #endif
    }
}

enum AppHaptics {
    static func copy() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }

    static func refresh() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    static func track() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()
        #endif
    }
}

struct EmptyStateCardView: View {
    @Environment(\.appDensity) private var appDensity

    let title: String
    let message: String
    let suggestion: String
    let systemImage: String
    let showsCardBackground: Bool

    init(
        title: String,
        message: String,
        suggestion: String,
        systemImage: String,
        showsCardBackground: Bool = true
    ) {
        self.title = title
        self.message = message
        self.suggestion = suggestion
        self.systemImage = systemImage
        self.showsCardBackground = showsCardBackground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            // `Text(message)` already carried `fixedSize`; the title and
            // suggestion did not, which is why the audit reported the *title*
            // clipped on every empty state while the body beneath it wrapped.
            // Deliberately an HStack rather than `Label`. `Label` constrains its
            // own title text and `.fixedSize` applied to the Label does not
            // reach the Text inside, so every empty-state heading reported as
            // clipped. Splitting it lets the modifier land on the Text itself.
            // Verified: doing this alone cleared the finding on all four empty
            // states; changing the font design did not.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Decorative. `Label` used to fold the icon into the title's
                // element; splitting them exposed it as its own, announcing the
                // raw SF Symbol name ("checklist.unchecked") to VoiceOver.
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
                .font(appDensity.font(.headline, weight: .semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(appDensity.font(.body))
                .foregroundStyle(ThemeToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(suggestion)
                .font(appDensity.font(.caption))
                .foregroundStyle(ThemeToken.info)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(appDensity.metrics.cardPadding)
        .background(showsCardBackground ? AnyShapeStyle(ThemeToken.surface) : AnyShapeStyle(.clear))
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
    }
}

/// A collapsible result section.
///
/// Its body is a `Group`, not a stack: inside a `List` that makes the header
/// and each piece of content their own row, so the row backgrounds draw one
/// grouped panel per section and the separators keep the cards inside it
/// apart. Every caller puts it in a `List` for that reason — a stack would lay
/// the children out itself and lose both.
struct CollapsibleSectionView<HeaderTrailing: View, Content: View>: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    @Binding var isCollapsed: Bool
    let subtitle: String?
    @ViewBuilder let trailing: () -> HeaderTrailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        isCollapsed: Binding<Bool>,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> HeaderTrailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isCollapsed = isCollapsed
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        Group {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                // One line while the title, trailing controls, and chevron
                // genuinely fit; otherwise the trailing controls drop below the
                // title. Without this, a squeezed trailing button letter-wraps
                // vertically ("N o t e" as a screen-tall capsule) at larger
                // Dynamic Type sizes — same pathology as the row badges.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        titleBlock
                        Spacer(minLength: 8)
                        trailing()
                        chevron
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 10) {
                            titleBlock
                            Spacer(minLength: 8)
                            chevron
                        }
                        trailing()
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: appDensity.metrics.controlMinHeight, alignment: .center)
            }
            .buttonStyle(.plain)
            // A header that is also the expand/collapse control. The chevron is
            // decorative; state and hint carry it to VoiceOver instead. No
            // `children: .combine` here — `trailing()` may hold its own controls
            // (Track, Pin), and combining would swallow them into the header.
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed ? "Expands the section" : "Collapses the section")

            if !isCollapsed {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(appDensity.font(.headline, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            if let subtitle {
                Text(subtitle)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(ThemeToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ThemeToken.textSecondary)
            .accessibilityHidden(true)
    }
}

/// A horizontally scrolling row of read-only tag chips, e.g. for a tracked
/// domain's detail view.
struct TagChipRowView: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(ThemeToken.surfaceElevated, in: Capsule())
                }
            }
        }
    }
}

/// A horizontally scrolling row of selectable tag chips used to filter a list,
/// with an "All" chip to clear the selection.
struct TagFilterChipRowView: View {
    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(tags, id: \.self) { tag in
                    filterChip(title: tag, isSelected: selection == tag) {
                        selection = (selection == tag) ? nil : tag
                    }
                }
            }
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? ThemeToken.infoSurface : ThemeToken.surfaceElevated, in: Capsule())
                .foregroundStyle(isSelected ? AnyShapeStyle(ThemeToken.info) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

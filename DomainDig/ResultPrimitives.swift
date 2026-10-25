import SwiftUI

// The shared presentation primitives every result view builds on — cards,
// rows, section titles, trust metadata, colours — and the small formatting
// extensions that go with them. Split out of ContentView.swift (A13).

struct TrackedDomainDetailHeaderView: View {
    let trackedDomain: TrackedDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = trackedDomain.note?.nilIfEmpty {
                LabeledValueRow(row: InfoRowViewData(label: "Tracking Note", value: note, tone: .secondary))
            }
            HStack(spacing: 8) {
                if trackedDomain.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                }
                Text("Last refresh \(trackedDomain.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(Color(.appTextSecondary))
        }
    }
}

struct SectionTitleView: View {
    @Environment(\.appDensity) private var appDensity
    let title: String

    var body: some View {
        Text(title)
            .font(appDensity.font(.headline, design: .default, weight: .semibold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A card that wraps its content by default.
///
/// `allowsHorizontalScroll` used to default to `true`, so nine call sites put
/// their content behind a horizontal gesture instead of letting it wrap — a
/// WCAG 1.4.10 (Reflow) failure, and the mechanism behind clipped rows at large
/// text sizes. It also forced VoiceOver and Switch Control users onto a nested
/// scroll axis to reach data.
///
/// The default is now `false`. Where horizontal scrolling genuinely suits wide
/// tabular content, it is still opt-in — but it is suppressed at accessibility
/// text sizes, where wrapping always beats a hidden axis.
struct CardView<Content: View>: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let allowsHorizontalScroll: Bool
    let content: Content

    init(allowsHorizontalScroll: Bool = false, @ViewBuilder content: () -> Content) {
        self.allowsHorizontalScroll = allowsHorizontalScroll
        self.content = content()
    }

    var body: some View {
        Group {
            if allowsHorizontalScroll, !dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    cardContent
                        .scrollTargetLayout()
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                cardContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(appDensity.metrics.cardPadding)
        .background(Color(.appSurface))
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            content
        }
    }
}

struct LoadingCardView: View {
    let text: String

    var body: some View {
        CardView {
            ProgressView(text)
                .appLoadingStyle()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct MessageCardView: View {
    let text: String
    let isError: Bool

    var body: some View {
        CardView {
            MessageRowView(text: text, isError: isError)
        }
    }
}

struct MessageRowView: View {
    @Environment(\.appDensity) private var appDensity
    let text: String
    let isError: Bool

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
            .font(appDensity.font(.caption))
            .foregroundStyle(isError ? Color(.statusCritical) : .secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SectionTrustMetadataView: View {
    @Environment(\.appDensity) private var appDensity
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let note: String?

    init(provenance: SectionProvenance?, confidence: ConfidenceLevel?, note: String? = nil) {
        self.provenance = provenance
        self.confidence = confidence
        self.note = note
    }

    var body: some View {
        if provenance != nil || confidence != nil || note != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let confidence {
                        Text("Confidence \(confidence.title)")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                    if let provenance {
                        Text(provenance.provider ?? provenance.source)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                        Text(provenance.resultSource.label)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let provenance {
                            LabeledValueRow(row: .init(label: "Method", value: provenance.source, tone: .secondary))
                            if let provider = provenance.provider {
                                LabeledValueRow(row: .init(label: "Provider", value: provider, tone: .secondary))
                            }
                            if let resolver = provenance.resolver {
                                LabeledValueRow(row: .init(label: "Resolver", value: resolver, tone: .secondary))
                            }
                            LabeledValueRow(row: .init(label: "Collected", value: provenance.collectedAt.formatted(date: .abbreviated, time: .shortened), tone: .secondary))
                            LabeledValueRow(row: .init(label: "Mode", value: provenance.resultSource.label, tone: .secondary))
                        }
                        if let note {
                            LabeledValueRow(row: .init(label: "Note", value: note, tone: .secondary))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(appDensity.font(.caption))
                .tint(.secondary)
            }
        }
    }
}

struct LabeledValueRow: View {
    @Environment(\.appDensity) private var appDensity
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let row: InfoRowViewData

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing - 1) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing - 1) {
                    Text(row.label)
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if differentiateWithoutColor, let symbol = toneSymbol {
                            Image(systemName: symbol)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(ResultColors.color(for: row.tone))
                                .accessibilityHidden(true)
                        }
                        valueText
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: 6)
                if !row.value.isEmpty, row.value != "Unavailable" {
                    AppCopyButton(value: row.value, label: "Copy \(row.label)")
                }
            }
        }
        .frame(minHeight: appDensity.metrics.rowMinHeight, alignment: .topLeading)
    }

    /// A leading symbol for warning/failure tones, shown only under Differentiate
    /// Without Color so tone is not conveyed by text colour alone. Hidden from
    /// VoiceOver — the value text already carries the meaning.
    private var toneSymbol: String? {
        switch row.tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        default: return nil
        }
    }

    @ViewBuilder
    private var valueText: some View {
        let base = Text(row.value)
            .font(appDensity.font(.caption))
            .foregroundStyle(ResultColors.color(for: row.tone))

        switch row.speechStyle {
        case .plain:
            base
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .technical:
            // Record values and identifiers: keep punctuation audible (SPF/DMARC
            // separators are semantically load-bearing) and let VoiceOver use its
            // code-reading heuristics.
            base
                .speechAlwaysIncludesPunctuation()
                .accessibilityTextContentType(.sourceCode)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Maps a row's semantic tone onto the app palette.
///
/// See `Docs/ACCESSIBILITY.md` for the measured contrast ratios behind these
/// colours. Never reach for a literal (`Color(.statusCritical)`, `Color(.statusWarning)`, …) — the system
/// palette fails WCAG AA badly in light mode (systemYellow is 1.28:1 on white).
enum ResultColors {
    static func color(for tone: ResultTone) -> Color {
        switch tone {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .success:
            return Color(.statusPositive)
        case .warning:
            return Color(.statusWarning)
        case .failure:
            return Color(.statusCritical)
        }
    }
}

extension DateFormatter {
    static let certDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension View {
    func appLoadingStyle() -> some View {
        font(.system(.caption, design: .monospaced))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension ChangeImpactClassification {
    var tone: AppStatusTone {
        switch self {
        case .informational: return .neutral
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

extension TLSGrade {
    var tone: ResultTone {
        switch self {
        case .a: return .success
        case .f: return .failure
        default: return .warning
        }
    }
}

extension EmailSecurityGrade {
    var tone: ResultTone {
        switch self {
        case .a: return .success
        case .f: return .failure
        default: return .warning
        }
    }
}

#Preview {
    ContentView(viewModel: DomainViewModel())
}

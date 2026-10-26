import SwiftUI

// One inspection section: the discovered subdomains card. Pure presentation
// over the view model's report data; the shared primitives it builds on
// (CardView, SectionTitleView, LabeledValueRow, ResultColors, appLoadingStyle)
// live in ResultPrimitives.swift.

struct SubdomainsSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let rows: [SubdomainRowViewData]
    let groups: [SubdomainGroup]
    let loading: Bool
    let error: String?
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let showsExtendedPlaceholder: Bool
    let extendedCount: Int
    let extendedLoading: Bool
    let extendedError: String?
    let onLoadExtended: (() -> Void)?

    init(
        isCollapsed: Binding<Bool>,
        rows: [SubdomainRowViewData],
        groups: [SubdomainGroup],
        loading: Bool,
        error: String?,
        provenance: SectionProvenance?,
        confidence: ConfidenceLevel?,
        showsExtendedPlaceholder: Bool,
        extendedCount: Int = 0,
        extendedLoading: Bool = false,
        extendedError: String? = nil,
        onLoadExtended: (() -> Void)? = nil
    ) {
        _isCollapsed = isCollapsed
        self.rows = rows
        self.groups = groups
        self.loading = loading
        self.error = error
        self.provenance = provenance
        self.confidence = confidence
        self.showsExtendedPlaceholder = showsExtendedPlaceholder
        self.extendedCount = extendedCount
        self.extendedLoading = extendedLoading
        self.extendedError = extendedError
        self.onLoadExtended = onLoadExtended
    }

    var body: some View {
        CollapsibleSectionView(title: "Subdomains", isCollapsed: $isCollapsed, subtitle: "\(rows.count) found") {
            CardView(allowsHorizontalScroll: false) {
                SectionTrustMetadataView(provenance: provenance, confidence: confidence)
                if loading {
                    ProgressView("Checking certificate transparency…")
                        .appLoadingStyle()
                } else if rows.isEmpty {
                    MessageRowView(text: error ?? "No passive subdomains found", isError: false)
                    if showsExtendedPlaceholder {
                        MessageRowView(text: "Extended subdomain discovery available in Pro+", isError: false)
                            .padding(.top, 4)
                    }
                } else {
                    if let onLoadExtended, extendedCount == 0, !extendedLoading, !showsExtendedPlaceholder {
                        Button("Load extended results") {
                            onLoadExtended()
                        }
                        .buttonStyle(.bordered)
                        .font(appDensity.font(.caption2))
                    }
                    groupList
                    subdomainRows
                    extendedStatus
                }
            }
        }
    }

    @ViewBuilder
    private var extendedStatus: some View {
        if extendedLoading {
            ProgressView("Loading extended subdomains…")
                .appLoadingStyle()
                .padding(.top, 4)
        } else if extendedCount > 0 {
            MessageRowView(text: "\(extendedCount) extended results included", isError: false)
                .padding(.top, 4)
        } else if let extendedError {
            MessageRowView(text: extendedError, isError: false)
                .padding(.top, 4)
        } else if showsExtendedPlaceholder {
            MessageRowView(text: "Extended subdomain discovery available in Pro+", isError: false)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var groupList: some View {
        if !groups.isEmpty {
            Text("Groups")
                .font(appDensity.font(.caption2))
                .foregroundStyle(ThemeToken.textSecondary)
            ForEach(groups) { group in
                HStack {
                    Text("\(group.label).*")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(ThemeToken.info)
                    Spacer()
                    Text("\(group.subdomains.count)")
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(ThemeToken.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var subdomainRows: some View {
        ForEach(rows) { row in
            HStack(spacing: 8) {
                Text(row.hostname)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer()
                if row.isInteresting {
                    Text("Interesting")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(ThemeToken.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ThemeToken.warningSurface)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

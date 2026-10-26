import SwiftUI

// One inspection section: the email security card. Pure presentation over the
// view model's report data; the shared primitives it builds on (CardView,
// SectionTitleView, LabeledValueRow, ResultColors, appLoadingStyle) live in
// ResultPrimitives.swift.

struct EmailSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let rows: [EmailRowViewData]
    let assessment: EmailSecuritySummary?
    let loading: Bool
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let error: String?

    var body: some View {
        CollapsibleSectionView(title: "Email", isCollapsed: $isCollapsed) {
            CardView {
                SectionTrustMetadataView(provenance: provenance, confidence: confidence)
                HStack {
                    Spacer()
                    AppStatusBadgeView(model: AppStatusFactory.email(nil, error: error))
                        .opacity(loading ? 0 : 1)
                }
                if let assessment, let grade = assessment.grade {
                    LabeledValueRow(row: InfoRowViewData(label: "Grade", value: grade.rawValue, tone: grade.tone))
                    if !assessment.reasons.isEmpty {
                        Text(assessment.reasons.joined(separator: " | "))
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }
                if loading {
                    ProgressView("Checking email records…")
                        .appLoadingStyle()
                } else if let error {
                    MessageRowView(text: error, isError: true)
                } else if rows.isEmpty {
                    MessageRowView(text: "No email security records found", isError: false)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(row.label)
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(ThemeToken.info)
                                    .frame(width: 76, alignment: .leading)
                                AppStatusBadgeView(model: emailRowBadge(row))
                            }
                            Text(row.detail)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            if let auxiliaryDetail = row.auxiliaryDetail {
                                Text(auxiliaryDetail)
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(ThemeToken.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func emailRowBadge(_ row: EmailRowViewData) -> AppStatusBadgeModel {
        switch row.statusTone {
        case .success:
            return .init(title: row.status, systemImage: "checkmark.shield.fill", foreground: .positive, background: .positiveSurface)
        case .warning:
            return .init(title: row.status, systemImage: "shield.lefthalf.filled", foreground: .warning, background: .warningSurface)
        case .failure:
            return .init(title: row.status, systemImage: "minus.circle", foreground: .textSecondary, background: .surfaceElevated)
        case .primary, .secondary:
            return .init(title: row.status, systemImage: "circle", foreground: .textSecondary, background: .surfaceElevated)
        }
    }
}

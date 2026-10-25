import SwiftUI

// The summary strip above the result sections: risk, insights, the sticky
// header, progress and the status banner. Split out of ContentView.swift (A13).

struct SummaryView: View {
    @Environment(\.appDensity) private var appDensity
    let fields: [SummaryFieldViewData]

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            SectionTitleView(title: "Summary")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: appDensity.metrics.cardSpacing) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing) {
                        Text(field.label)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                        Text(field.value)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(ResultColors.color(for: field.tone))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: appDensity.metrics.rowMinHeight + 12, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(appDensity.metrics.cardPadding)
                    .background(Color(.appSurface))
                    .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
                }
            }
        }
    }
}

struct RiskSummaryCardView: View {
    @Environment(\.appDensity) private var appDensity
    let report: DomainReport

    private var topFactors: [RiskFactor] {
        Array(report.riskAssessment.factors.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            SectionTitleView(title: "Risk")
            CardView(allowsHorizontalScroll: false) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.riskAssessment.score)")
                            .font(appDensity.font(.largeTitle, weight: .bold))
                            .foregroundStyle(levelColor)
                        Text(report.riskAssessment.level.title)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(levelColor)
                    }
                    Spacer()
                    Text("Deterministic")
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                }

                if topFactors.isEmpty {
                    Text("No major risk factors identified")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.appTextSecondary))
                } else {
                    ForEach(Array(topFactors.enumerated()), id: \.offset) { _, factor in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(factorColor(factor.impact))
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)
                            Text(factor.description)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    private var levelColor: Color {
        switch report.riskAssessment.level {
        case .low:
            return Color(.statusPositive)
        case .medium:
            return Color(.statusWarning)
        case .high:
            return Color(.statusCritical)
        }
    }

    private func factorColor(_ impact: RiskImpact) -> Color {
        switch impact {
        case .positive:
            return Color(.statusPositive)
        case .neutral:
            return .secondary
        case .negative:
            return Color(.statusCritical)
        }
    }
}

struct InsightsSummaryCardView: View {
    @Environment(\.appDensity) private var appDensity
    let insights: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            SectionTitleView(title: "Insights")
            CardView(allowsHorizontalScroll: false) {
                if insights.isEmpty {
                    Text("No deterministic insights triggered")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.appTextSecondary))
                } else {
                    ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.statusInfo))
                                .padding(.top, 2)
                            Text(insight)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }
}

struct StickyLookupSummaryView: View {
    @Environment(\.appDensity) private var appDensity

    let domain: String
    let availability: DomainAvailabilityStatus?
    let primaryIP: String?
    let sslInfo: SSLCertificateInfo?
    let sslError: String?
    let emailSecurity: EmailSecurityResult?
    let emailError: String?
    let changeSummary: DomainChangeSummary?

    var body: some View {
        CardView(allowsHorizontalScroll: false) {
            VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
                HStack(alignment: .center, spacing: 10) {
                    Text(domain)
                        .font(appDensity.font(.headline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    AppCopyButton(value: domain, label: "Copy domain")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        AppStatusBadgeView(model: AppStatusFactory.availability(availability))
                        AppStatusBadgeView(model: AppStatusFactory.tls(sslInfo: sslInfo, error: sslError))
                        AppStatusBadgeView(model: AppStatusFactory.email(emailSecurity, error: emailError))
                        AppStatusBadgeView(model: AppStatusFactory.change(changeSummary))
                    }
                }

                if let primaryIP {
                    HStack(spacing: 8) {
                        Label(primaryIP, systemImage: "network")
                            .font(appDensity.font(.caption))
                            .foregroundStyle(Color(.appTextSecondary))
                        Spacer(minLength: 6)
                        AppCopyButton(value: primaryIP, label: "Copy IP")
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

struct LookupProgressOverviewView: View {
    @Environment(\.appDensity) private var appDensity
    let steps: [String]

    var body: some View {
        CardView(allowsHorizontalScroll: false) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running lookup…")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(.primary)
                    Text(steps.isEmpty ? "Preparing requests" : steps.joined(separator: " • "))
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                }
                Spacer()
            }
        }
    }
}

struct LookupStatusBannerView: View {
    @Environment(\.appDensity) private var appDensity
    let message: String
    let resultSource: LookupResultSource

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
            Text(message)
                .font(appDensity.font(.caption))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(appDensity.metrics.cardPadding - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))
    }

    private var color: Color {
        switch resultSource {
        case .live:
            return Color(.statusPositive)
        case .cached:
            return .secondary
        case .mixed:
            return Color(.statusWarning)
        case .snapshot:
            return Color(.statusWarning)
        }
    }

    private var iconName: String {
        switch resultSource {
        case .live:
            return "bolt.horizontal"
        case .cached:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .mixed:
            return "arrow.triangle.branch"
        case .snapshot:
            return "archivebox"
        }
    }
}

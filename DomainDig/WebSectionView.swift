import SwiftUI

// One inspection section: the TLS, headers and redirects cards. Pure
// presentation over the view model's report data; the shared primitives it
// builds on (CardView, SectionTitleView, LabeledValueRow, ResultColors,
// appLoadingStyle) live in ResultPrimitives.swift.

struct WebSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool

    private let certificateRows: [InfoRowViewData]
    private let sslInfo: SSLCertificateInfo?
    private let tlsSummary: WebResultSummary?
    private let sslLoading: Bool
    private let sslError: String?
    private let tlsProvenance: SectionProvenance?
    private let responseRows: [InfoRowViewData]
    private let headers: [HTTPHeader]
    private let headersLoading: Bool
    private let headersError: String?
    private let httpProvenance: SectionProvenance?
    private let redirects: [RedirectHopViewData]
    private let redirectLoading: Bool
    private let redirectError: String?
    private let redirectProvenance: SectionProvenance?
    private let finalURL: String?

    init(isCollapsed: Binding<Bool>, data: WebSectionViewData) {
        _isCollapsed = isCollapsed
        certificateRows = data.certificateRows
        sslInfo = data.sslInfo
        tlsSummary = data.tlsSummary
        sslLoading = data.tls.isLoading
        sslError = data.tls.error
        tlsProvenance = data.tls.provenance
        responseRows = data.responseRows
        headers = data.headers
        headersLoading = data.http.isLoading
        headersError = data.http.error
        httpProvenance = data.http.provenance
        redirects = data.redirectRows
        redirectLoading = data.redirect.isLoading
        redirectError = data.redirect.error
        redirectProvenance = data.redirect.provenance
        finalURL = data.finalURL
    }

    var body: some View {
        CollapsibleSectionView(title: "Web", isCollapsed: $isCollapsed) {
            CardView {
                HStack {
                    Text("TLS")
                        .font(appDensity.font(.subheadline, weight: .semibold))
                        .foregroundStyle(ThemeToken.info)
                    Spacer()
                    if !sslLoading {
                        AppStatusBadgeView(model: AppStatusFactory.tls(sslInfo: sslInfo, error: sslError))
                    }
                }
                SectionTrustMetadataView(provenance: tlsProvenance, confidence: nil)
                if !sslLoading, let tlsSummary {
                    LabeledValueRow(row: InfoRowViewData(label: "TLS Grade", value: tlsSummary.tlsGrade.rawValue, tone: tlsSummary.tlsGrade.tone))
                    ForEach(Array(tlsSummary.tlsHighlights.enumerated()), id: \.offset) { _, highlight in
                        MessageRowView(text: highlight, isError: isTLSHighlightError(highlight))
                    }
                }
                if sslLoading {
                    ProgressView("Checking certificate…")
                        .appLoadingStyle()
                } else if let sslError {
                    MessageRowView(text: sslError, isError: true)
                } else {
                    ForEach(certificateRows) { row in
                        LabeledValueRow(row: row)
                    }
                    if let sslInfo, !sslInfo.subjectAltNames.isEmpty {
                        Text("SANs")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(ThemeToken.textSecondary)
                        ForEach(sslInfo.subjectAltNames, id: \.self) { san in
                            HStack(alignment: .top, spacing: 8) {
                                Text(san)
                                    .font(appDensity.font(.caption))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Spacer()
                                AppCopyButton(value: san, label: "Copy certificate SAN")
                            }
                        }
                    }
                }
            }

            CardView {
                Text("Headers")
                    .font(appDensity.font(.subheadline, weight: .semibold))
                    .foregroundStyle(ThemeToken.info)
                SectionTrustMetadataView(provenance: httpProvenance, confidence: nil)
                if headersLoading {
                    ProgressView("Fetching headers…")
                        .appLoadingStyle()
                } else if let headersError {
                    MessageRowView(text: headersError, isError: true)
                } else {
                    ForEach(responseRows) { row in
                        LabeledValueRow(row: row)
                    }
                    if headers.isEmpty {
                        MessageRowView(text: "No HTTP headers returned", isError: false)
                    } else {
                        ForEach(headers) { header in
                            HStack(alignment: .top, spacing: 4) {
                                Text(header.name + ":")
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(header.isSecurityHeader ? ThemeToken.warning : ThemeToken.info)
                                Text(header.value)
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            CardView {
                HStack {
                    Text("Redirects")
                        .font(appDensity.font(.subheadline, weight: .semibold))
                        .foregroundStyle(ThemeToken.info)
                    Spacer()
                    if let finalURL {
                        AppCopyButton(value: finalURL, label: "Copy redirect URL")
                    }
                }
                SectionTrustMetadataView(provenance: redirectProvenance, confidence: nil)
                if redirectLoading {
                    ProgressView("Tracing redirects…")
                        .appLoadingStyle()
                } else if let redirectError {
                    MessageRowView(text: redirectError, isError: true)
                } else if redirects.isEmpty {
                    MessageRowView(text: "No redirect data available", isError: false)
                } else {
                    if let finalURL {
                        LabeledValueRow(row: InfoRowViewData(label: "Final URL", value: finalURL, tone: .secondary))
                    }
                    ForEach(redirects) { redirect in
                        HStack(alignment: .top, spacing: 6) {
                            Text(redirect.stepLabel)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(ThemeToken.textSecondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(redirect.statusCode)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(ThemeToken.info)
                                .frame(width: 36, alignment: .leading)
                            Text(redirect.url)
                                .font(appDensity.font(.caption))
                                .textSelection(.enabled)
                            if redirect.isFinal {
                                Text("(final)")
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(ThemeToken.textSecondary)
                            }
                            Spacer(minLength: 8)
                            AppCopyButton(value: redirect.url, label: "Copy redirect URL")
                        }
                    }
                }
            }
        }
    }

    private func isTLSHighlightError(_ highlight: String) -> Bool {
        let normalized = highlight.lowercased()
        if normalized.contains("no weak tls indicators were detected") {
            return false
        }
        return normalized.contains("expires")
            || normalized.contains("weak")
            || normalized.contains("tls 1.0")
            || normalized.contains("tls 1.1")
    }
}

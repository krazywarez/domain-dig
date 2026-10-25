import SwiftUI

// One inspection section: the DNS records card. Pure presentation over the
// view model's report data; the shared primitives it builds on (CardView,
// SectionTitleView, LabeledValueRow, ResultColors, appLoadingStyle) live in
// ResultPrimitives.swift.

struct DNSSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let dnssecLabel: String?
    let patternSummary: DNSPatternSummary?
    let sections: [DNSRecordSectionViewData]
    let ptrMessage: SectionMessageViewData?
    let loading: Bool
    let dnsProvenance: SectionProvenance?
    let ptrProvenance: SectionProvenance?
    let sectionError: String?
    let history: [DNSHistoryEvent]
    let historyLoading: Bool
    let historyError: String?
    let onLoadHistory: (() -> Void)?

    init(
        isCollapsed: Binding<Bool>,
        dnssecLabel: String?,
        patternSummary: DNSPatternSummary?,
        sections: [DNSRecordSectionViewData],
        ptrMessage: SectionMessageViewData?,
        loading: Bool,
        dnsProvenance: SectionProvenance?,
        ptrProvenance: SectionProvenance?,
        sectionError: String?,
        history: [DNSHistoryEvent] = [],
        historyLoading: Bool = false,
        historyError: String? = nil,
        onLoadHistory: (() -> Void)? = nil
    ) {
        _isCollapsed = isCollapsed
        self.dnssecLabel = dnssecLabel
        self.patternSummary = patternSummary
        self.sections = sections
        self.ptrMessage = ptrMessage
        self.loading = loading
        self.dnsProvenance = dnsProvenance
        self.ptrProvenance = ptrProvenance
        self.sectionError = sectionError
        self.history = history
        self.historyLoading = historyLoading
        self.historyError = historyError
        self.onLoadHistory = onLoadHistory
    }

    var body: some View {
        CollapsibleSectionView(title: "DNS", isCollapsed: $isCollapsed, subtitle: dnssecLabel) {
            if loading {
                LoadingCardView(text: "Querying DNS…")
            } else if let sectionError, sections.isEmpty {
                MessageCardView(text: sectionError, isError: true)
            } else {
                provenanceCard
                ForEach(sections) { section in
                    CardView {
                        Text(section.title)
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(.statusInfo))

                        if let message = section.message {
                            MessageRowView(text: message.text, isError: message.isError)
                        }

                        ForEach(section.rows) { row in
                            LabeledValueRow(row: row)
                        }

                        if let wildcardTitle = section.wildcardTitle {
                            Text(wildcardTitle)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(.appTextSecondary))
                                .padding(.top, 4)
                            ForEach(section.wildcardRows) { row in
                                LabeledValueRow(row: row)
                            }
                        }
                    }
                }

                if let ptrMessage {
                    CardView {
                        Text("PTR")
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(.statusInfo))
                        SectionTrustMetadataView(provenance: ptrProvenance, confidence: nil)
                        MessageRowView(text: ptrMessage.text, isError: ptrMessage.isError)
                    }
                }

                CardView(allowsHorizontalScroll: false) {
                    HStack {
                        Text("History")
                            .font(appDensity.font(.subheadline, weight: .semibold))
                            .foregroundStyle(Color(.statusInfo))
                        Spacer()
                        if let onLoadHistory, history.isEmpty, !historyLoading {
                            Button("Load") {
                                onLoadHistory()
                            }
                            .buttonStyle(.bordered)
                            .font(appDensity.font(.caption2))
                        }
                    }
                    historyContent
                }
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if historyLoading {
            ProgressView("Loading DNS history…")
                .appLoadingStyle()
        } else if !history.isEmpty {
            ForEach(history) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.date.formatted(date: .abbreviated, time: .omitted))
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
                    Text(event.summary)
                        .font(appDensity.font(.caption))
                    if !event.aRecords.isEmpty {
                        Text("A: \(event.aRecords.joined(separator: ", "))")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                    if !event.nameservers.isEmpty {
                        Text("NS: \(event.nameservers.joined(separator: ", "))")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                }
            }
        } else if let historyError {
            MessageRowView(text: historyError, isError: false)
        }
    }

    @ViewBuilder
    private var provenanceCard: some View {
        if dnsProvenance != nil {
            CardView(allowsHorizontalScroll: false) {
                SectionTrustMetadataView(provenance: dnsProvenance, confidence: nil)
                if let patternSummary {
                    if !patternSummary.providers.isEmpty {
                        MessageRowView(text: "Providers: \(patternSummary.providers.joined(separator: ", "))", isError: false)
                    }
                    if !patternSummary.patterns.isEmpty {
                        ForEach(Array(patternSummary.patterns.enumerated()), id: \.offset) { _, pattern in
                            MessageRowView(text: pattern, isError: false)
                        }
                    }
                }
            }
        }
    }
}

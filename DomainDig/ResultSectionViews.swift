import MapKit
import SwiftUI

// Result detail section views extracted from ContentView.swift — one per
// inspection domain (availability/DNS, ownership, intelligence, subdomains,
// DNS records, web, email, network, ports). Pure presentation over the
// view-model report data; the shared primitives (CardView, SectionTitleView,
// LabeledValueRow, ResultColors, appLoadingStyle) remain in ContentView.swift.

struct DomainSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let rows: [InfoRowViewData]
    let suggestions: [DomainSuggestionViewData]
    let showSuggestions: Bool
    let availabilityLoading: Bool
    let suggestionsLoading: Bool
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let snapshotNote: String?
    let trackedDomain: TrackedDomain?
    let workflows: [DomainWorkflow]
    let trackingLimitMessage: String?
    let pricingLoading: Bool
    let pricingError: String?
    let showsPricingPlaceholder: Bool
    let onTrack: () -> Void
    let onTogglePinned: () -> Void
    let onEditNote: (() -> Void)?
    let onAddToWorkflow: (() -> Void)?
    let onOpenWorkflow: ((DomainWorkflow) -> Void)?
    let onRunWorkflow: ((DomainWorkflow) -> Void)?

    var body: some View {
        CollapsibleSectionView(title: "Domain", isCollapsed: $isCollapsed) {
            if let trackedDomain {
                HStack(spacing: 8) {
                    // Icon-only: the header also carries Pin and Note, and the
                    // full "Tracked" pill compresses at larger text sizes.
                    // VoiceOver still hears the word via the label.
                    Image(systemName: "eye.fill")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.statusPositive))
                        .padding(6)
                        .background(Color(.statusPositiveSurface), in: Circle())
                        .fixedSize()
                        .accessibilityLabel("Tracked")
                    Button {
                        onTogglePinned()
                    } label: {
                        Image(systemName: trackedDomain.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.bordered)
                    .font(appDensity.font(.caption))
                    .accessibilityLabel("Pin domain")
                    .accessibilityValue(trackedDomain.isPinned ? "Pinned" : "Not pinned")
                    .accessibilityAddTraits(trackedDomain.isPinned ? .isSelected : [])
                    if let onEditNote {
                        Button("Note") {
                            onEditNote()
                        }
                        .buttonStyle(.bordered)
                        .font(appDensity.font(.caption))
                        // Never compress into a vertical letter column.
                        .fixedSize()
                    }
                }
            } else {
                Button("Track") {
                    AppHaptics.track()
                    onTrack()
                }
                .buttonStyle(.bordered)
                .font(appDensity.font(.caption))
                .fixedSize()
            }
        } content: {
            CardView(allowsHorizontalScroll: false) {
                SectionTrustMetadataView(
                    provenance: provenance,
                    confidence: confidence,
                    note: snapshotNote == nil ? nil : "Audit note present"
                )
                ForEach(rows) { row in
                    LabeledValueRow(row: row)
                }
                if let trackedDomain {
                    TrackedDomainDetailHeaderView(trackedDomain: trackedDomain)
                        .padding(.top, 4)
                } else if let trackingLimitMessage {
                    MessageRowView(text: trackingLimitMessage, isError: false)
                        .padding(.top, 4)
                }
                if let onAddToWorkflow {
                    Button {
                        onAddToWorkflow()
                    } label: {
                        Label("Add to workflow", systemImage: "plus.rectangle.on.folder")
                            .font(appDensity.font(.caption))
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
                if !workflows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Part of workflow")
                            .font(appDensity.font(.caption))
                            .foregroundStyle(Color(.appTextSecondary))

                        ForEach(workflows) { workflow in
                            HStack {
                                Text(workflow.name)
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if let onOpenWorkflow {
                                    Button("Open") {
                                        onOpenWorkflow(workflow)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(appDensity.font(.caption2))
                                }
                                if let onRunWorkflow {
                                    Button("Run") {
                                        onRunWorkflow(workflow)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(appDensity.font(.caption2))
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                if availabilityLoading {
                    ProgressView("Checking availability…")
                        .appLoadingStyle()
                        .padding(.top, 4)
                }
                if showSuggestions {
                    Text("Suggestions")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.appTextSecondary))
                        .padding(.top, 4)
                    if suggestionsLoading {
                        ProgressView("Checking alternatives…")
                            .appLoadingStyle()
                    } else if suggestions.isEmpty {
                        MessageRowView(text: "No suggestions", isError: false)
                    } else {
                        ForEach(suggestions) { suggestion in
                            HStack {
                                Text(suggestion.domain)
                                    .font(appDensity.font(.caption))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Spacer()
                                AppStatusBadgeView(model: AppStatusFactory.availability(suggestion.availabilityStatus))
                            }
                        }
                    }
                }
                if pricingLoading {
                    ProgressView("Loading external pricing…")
                        .appLoadingStyle()
                        .padding(.top, 4)
                } else if let pricingError {
                    MessageRowView(text: pricingError, isError: false)
                        .padding(.top, 4)
                } else if showsPricingPlaceholder {
                    MessageRowView(text: "Pricing signals available in Pro+", isError: false)
                        .padding(.top, 4)
                }
            }
        }
    }
}

struct OwnershipSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let rows: [InfoRowViewData]
    let loading: Bool
    let error: String?
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let showsHistoryPlaceholder: Bool
    let history: [DomainOwnershipHistoryEvent]
    let historyLoading: Bool
    let historyError: String?
    let historyCreditStatus: UsageCreditStatus?
    let onLoadHistory: (() -> Void)?

    init(
        isCollapsed: Binding<Bool>,
        rows: [InfoRowViewData],
        loading: Bool,
        error: String?,
        provenance: SectionProvenance?,
        confidence: ConfidenceLevel?,
        showsHistoryPlaceholder: Bool,
        history: [DomainOwnershipHistoryEvent] = [],
        historyLoading: Bool = false,
        historyError: String? = nil,
        historyCreditStatus: UsageCreditStatus? = nil,
        onLoadHistory: (() -> Void)? = nil
    ) {
        _isCollapsed = isCollapsed
        self.rows = rows
        self.loading = loading
        self.error = error
        self.provenance = provenance
        self.confidence = confidence
        self.showsHistoryPlaceholder = showsHistoryPlaceholder
        self.history = history
        self.historyLoading = historyLoading
        self.historyError = historyError
        self.historyCreditStatus = historyCreditStatus
        self.onLoadHistory = onLoadHistory
    }

    var body: some View {
        CollapsibleSectionView(title: "Ownership", isCollapsed: $isCollapsed) {
            CardView(allowsHorizontalScroll: false) {
                SectionTrustMetadataView(provenance: provenance, confidence: confidence)
                if loading {
                    ProgressView("Fetching RDAP ownership…")
                        .appLoadingStyle()
                } else {
                    ForEach(rows) { row in
                        LabeledValueRow(row: row)
                    }
                    if let error, rows.allSatisfy({ $0.value == "Unavailable" }) {
                        MessageRowView(text: error, isError: error != "Unavailable")
                            .padding(.top, 4)
                    }
                    historyBlock
                }
            }
        }
    }

    @ViewBuilder
    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(appDensity.font(.caption))
                    .foregroundStyle(Color(.appTextSecondary))
                Spacer()
                if let onLoadHistory, history.isEmpty, !historyLoading, !showsHistoryPlaceholder {
                    Button("Load") {
                        onLoadHistory()
                    }
                    .buttonStyle(.bordered)
                    .font(appDensity.font(.caption2))
                }
            }
            if historyLoading {
                ProgressView("Loading history…")
                    .appLoadingStyle()
            } else if !history.isEmpty {
                ForEach(history) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.date.formatted(date: .abbreviated, time: .omitted))
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                        Text(event.summary)
                            .font(appDensity.font(.caption))
                        Text(event.source)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                    }
                }
            } else if let historyError {
                MessageRowView(text: historyError, isError: false)
            } else if showsHistoryPlaceholder {
                MessageRowView(text: "Ownership history available in Pro+", isError: false)
            }
        }
    }
}

struct IntelligenceSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let report: DomainReport
    let showsPlaceholder: Bool

    var body: some View {
        CollapsibleSectionView(title: "Data+ Intelligence", isCollapsed: $isCollapsed) {
            CardView(allowsHorizontalScroll: false) {
                if showsPlaceholder {
                    MessageRowView(text: "Richer intelligence history, hosting analysis, and risk signals are available in Pro+", isError: false)
                } else {
                    if let provider = report.inferredProvider {
                        intelligenceBlock(title: "Infrastructure") {
                            LabeledValueRow(row: .init(label: "Provider", value: provider.name, tone: .primary))
                            if !provider.evidence.isEmpty {
                                MessageRowView(text: provider.evidence.joined(separator: " • "), isError: false)
                            }
                            if !report.priorProviders.isEmpty {
                                LabeledValueRow(row: .init(label: "Prior", value: report.priorProviders.joined(separator: ", "), tone: .secondary))
                            }
                        }
                    }
                    if let classification = report.domainClassification {
                        intelligenceBlock(title: "Classification") {
                            LabeledValueRow(row: .init(label: "Purpose", value: classification.kind.title, tone: .primary))
                            MessageRowView(text: classification.reasons.joined(separator: " • "), isError: false)
                        }
                    }
                    intelligenceBlock(title: "Risk Signals") {
                        if report.riskSignals.isEmpty {
                            MessageRowView(text: "No material historical risk signals detected", isError: false)
                        } else {
                            ForEach(report.riskSignals.prefix(4)) { signal in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.title)
                                        .font(appDensity.font(.caption, weight: .semibold))
                                    Text(signal.detail)
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }
                            }
                        }
                    }
                    intelligenceBlock(title: "Ownership History") {
                        if report.ownershipTransitions.isEmpty {
                            MessageRowView(text: "No ownership transitions observed locally", isError: false)
                        } else {
                            ForEach(report.ownershipTransitions.prefix(4)) { event in
                                intelligenceEventRow(date: event.date, title: event.summary)
                            }
                        }
                    }
                    intelligenceBlock(title: "Hosting History") {
                        if report.hostingTransitions.isEmpty {
                            MessageRowView(text: "No hosting transitions observed locally", isError: false)
                        } else {
                            ForEach(report.hostingTransitions.prefix(4)) { event in
                                intelligenceEventRow(date: event.date, title: event.summary)
                            }
                        }
                    }
                    intelligenceBlock(title: "Subdomain Intelligence") {
                        if report.subdomainHistory.isEmpty {
                            MessageRowView(text: "No subdomain history available", isError: false)
                        } else {
                            ForEach(report.subdomainHistory.prefix(5)) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.hostname)
                                            .font(appDensity.font(.caption))
                                        Spacer()
                                        if item.isEphemeral {
                                            Text("Ephemeral")
                                                .font(appDensity.font(.caption2))
                                                .foregroundStyle(Color(.statusWarning))
                                        }
                                    }
                                    Text("First \(item.firstSeen.formatted(date: .abbreviated, time: .omitted)) • Last \(item.lastSeen.formatted(date: .abbreviated, time: .omitted)) • Seen \(item.recurrenceCount)x")
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(Color(.appTextSecondary))
                                }
                            }
                        }
                    }
                    intelligenceBlock(title: "Timeline") {
                        if report.intelligenceTimeline.isEmpty {
                            MessageRowView(text: "No inferred intelligence events yet", isError: false)
                        } else {
                            ForEach(report.intelligenceTimeline.prefix(5)) { event in
                                intelligenceEventRow(date: event.date, title: "\(event.title): \(event.detail)")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func intelligenceBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(appDensity.font(.subheadline, weight: .semibold))
                .foregroundStyle(Color(.statusInfo))
            content()
        }
    }

    private func intelligenceEventRow(date: Date, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(appDensity.font(.caption2))
                .foregroundStyle(Color(.appTextSecondary))
            Text(title)
                .font(appDensity.font(.caption))
        }
    }
}

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
    let extendedCreditStatus: UsageCreditStatus?
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
        extendedCreditStatus: UsageCreditStatus? = nil,
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
        self.extendedCreditStatus = extendedCreditStatus
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
                .foregroundStyle(Color(.appTextSecondary))
            ForEach(groups) { group in
                HStack {
                    Text("\(group.label).*")
                        .font(appDensity.font(.caption))
                        .foregroundStyle(Color(.statusInfo))
                    Spacer()
                    Text("\(group.subdomains.count)")
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.appTextSecondary))
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
                        .foregroundStyle(Color(.statusWarning))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.statusWarningSurface))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

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
    let showsHistoryPlaceholder: Bool
    let historyCreditStatus: UsageCreditStatus?
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
        showsHistoryPlaceholder: Bool = false,
        historyCreditStatus: UsageCreditStatus? = nil,
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
        self.showsHistoryPlaceholder = showsHistoryPlaceholder
        self.historyCreditStatus = historyCreditStatus
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
                        if let onLoadHistory, history.isEmpty, !historyLoading, !showsHistoryPlaceholder {
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
        } else if showsHistoryPlaceholder {
            MessageRowView(text: "DNS history available in Pro+", isError: false)
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

struct WebSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let certificateRows: [InfoRowViewData]
    let sslInfo: SSLCertificateInfo?
    let tlsSummary: WebResultSummary?
    let sslLoading: Bool
    let sslError: String?
    let tlsProvenance: SectionProvenance?
    let responseRows: [InfoRowViewData]
    let headers: [HTTPHeader]
    let headersLoading: Bool
    let headersError: String?
    let httpProvenance: SectionProvenance?
    let redirects: [RedirectHopViewData]
    let redirectLoading: Bool
    let redirectError: String?
    let redirectProvenance: SectionProvenance?
    let finalURL: String?

    var body: some View {
        CollapsibleSectionView(title: "Web", isCollapsed: $isCollapsed) {
            CardView {
                HStack {
                    Text("TLS")
                        .font(appDensity.font(.subheadline, weight: .semibold))
                        .foregroundStyle(Color(.statusInfo))
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
                            .foregroundStyle(Color(.appTextSecondary))
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
                    .foregroundStyle(Color(.statusInfo))
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
                                    .foregroundStyle(header.isSecurityHeader ? Color(.statusWarning) : Color(.statusInfo))
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
                        .foregroundStyle(Color(.statusInfo))
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
                                .foregroundStyle(Color(.appTextSecondary))
                                .frame(width: 16, alignment: .trailing)
                            Text(redirect.statusCode)
                                .font(appDensity.font(.caption))
                                .foregroundStyle(Color(.statusInfo))
                                .frame(width: 36, alignment: .leading)
                            Text(redirect.url)
                                .font(appDensity.font(.caption))
                                .textSelection(.enabled)
                            if redirect.isFinal {
                                Text("(final)")
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(Color(.appTextSecondary))
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
                            .foregroundStyle(Color(.appTextSecondary))
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
                                    .foregroundStyle(Color(.statusInfo))
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
                                    .foregroundStyle(Color(.appTextSecondary))
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
            return .init(title: row.status, systemImage: "checkmark.shield.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
        case .warning:
            return .init(title: row.status, systemImage: "shield.lefthalf.filled", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
        case .failure:
            return .init(title: row.status, systemImage: "minus.circle", foregroundColor: Color(.appTextSecondary), backgroundColor: Color(.appSurfaceElevated))
        case .primary, .secondary:
            return .init(title: row.status, systemImage: "circle", foregroundColor: Color(.appTextSecondary), backgroundColor: Color(.appSurfaceElevated))
        }
    }
}

struct NetworkSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let reachabilityRows: [ReachabilityRowViewData]
    let reachabilityLoading: Bool
    let reachabilityError: String?
    let reachabilityProvenance: SectionProvenance?
    let locationRows: [InfoRowViewData]
    let geolocation: IPGeolocation?
    let geolocationLoading: Bool
    let geolocationError: String?
    let geolocationProvenance: SectionProvenance?
    let geolocationConfidence: ConfidenceLevel?
    let standardPortRows: [PortScanRowViewData]
    let customPortRows: [PortScanRowViewData]
    let portScanLoading: Bool
    let portScanError: String?
    let portScanProvenance: SectionProvenance?
    let customPortScanLoading: Bool
    let customPortScanError: String?
    let isCloudflareProxied: Bool
    @Binding var customPortsExpanded: Bool
    @Binding var customPortInput: String
    let onScanCustomPorts: () -> Void

    var body: some View {
        CollapsibleSectionView(title: "Network", isCollapsed: $isCollapsed) {
            CardView {
                Text("Reachability")
                    .font(appDensity.font(.subheadline, weight: .semibold))
                    .foregroundStyle(Color(.statusInfo))
                SectionTrustMetadataView(provenance: reachabilityProvenance, confidence: nil)
                if reachabilityLoading {
                    ProgressView("Checking ports…")
                        .appLoadingStyle()
                } else if let reachabilityError {
                    MessageRowView(text: reachabilityError, isError: true)
                } else {
                    ForEach(reachabilityRows) { row in
                        HStack {
                            Text(row.portLabel)
                                .font(appDensity.font(.caption))
                            Spacer()
                            Text(row.latencyLabel)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.appTextSecondary))
                            AppStatusBadgeView(model: reachabilityBadge(row))
                        }
                    }
                }
            }

            CardView(allowsHorizontalScroll: false) {
                Text("Location")
                    .font(appDensity.font(.subheadline, weight: .semibold))
                    .foregroundStyle(Color(.statusInfo))
                SectionTrustMetadataView(provenance: geolocationProvenance, confidence: geolocationConfidence)
                if geolocationLoading {
                    ProgressView("Looking up location…")
                        .appLoadingStyle()
                } else if let geolocationError, geolocation == nil {
                    MessageRowView(text: geolocationError, isError: geolocationError != "No A record available")
                } else if let geolocation {
                    ForEach(locationRows) { row in
                        LabeledValueRow(row: row)
                    }
                    if let latitude = geolocation.latitude, let longitude = geolocation.longitude {
                        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
                        ))) {
                            Marker(geolocation.ip, coordinate: coordinate)
                        }
                        .mapStyle(.standard)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .cornerRadius(8)
                    }
                } else {
                    MessageRowView(text: "No location data available", isError: false)
                }
            }

            CardView(allowsHorizontalScroll: false) {
                Text("Port Scan")
                    .font(appDensity.font(.subheadline, weight: .semibold))
                    .foregroundStyle(Color(.statusInfo))
                SectionTrustMetadataView(provenance: portScanProvenance, confidence: nil)

                if isCloudflareProxied {
                    Text("Domain is behind Cloudflare's proxy. Results reflect the edge, not the origin.")
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(Color(.statusWarning))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if portScanLoading {
                    ProgressView("Scanning ports…")
                        .appLoadingStyle()
                } else if let portScanError, standardPortRows.isEmpty {
                    MessageRowView(text: portScanError, isError: true)
                } else {
                    Text("Standard Ports")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(.appTextSecondary))
                    PortRowsView(rows: standardPortRows)
                }

                DisclosureGroup("Custom Ports", isExpanded: $customPortsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("8888, 9000, 27017", text: $customPortInput)
                            .font(appDensity.font(.caption))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                            .padding(10)
                            .background(Color(.appSurface))
                            .clipShape(RoundedRectangle(cornerRadius: appDensity.metrics.cardCornerRadius))

                        Button("Scan") {
                            AppHaptics.refresh()
                            onScanCustomPorts()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(.accentFill))
                        .disabled(customPortScanLoading)

                        if customPortScanLoading {
                            ProgressView("Scanning custom ports…")
                                .appLoadingStyle()
                        } else if let customPortScanError {
                            MessageRowView(text: customPortScanError, isError: true)
                        } else {
                            PortRowsView(rows: customPortRows)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(.caption, design: .monospaced))
                .tint(.secondary)
            }
        }
    }

    private func reachabilityBadge(_ row: ReachabilityRowViewData) -> AppStatusBadgeModel {
        switch row.statusTone {
        case .success:
            return .init(title: row.statusLabel, systemImage: "checkmark.circle.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
        case .warning:
            return .init(title: row.statusLabel, systemImage: "exclamationmark.triangle.fill", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
        case .failure:
            return .init(title: row.statusLabel, systemImage: "xmark.circle.fill", foregroundColor: Color(.statusCritical), backgroundColor: Color(.statusCriticalSurface))
        case .primary, .secondary:
            return .init(title: row.statusLabel, systemImage: "circle", foregroundColor: Color(.appTextSecondary), backgroundColor: Color(.appSurfaceElevated))
        }
    }
}

struct PortRowsView: View {
    @Environment(\.appDensity) private var appDensity
    let rows: [PortScanRowViewData]

    var body: some View {
        if rows.isEmpty {
            MessageRowView(text: "No results", isError: false)
        } else {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing - 1) {
                    HStack {
                        Text(row.portLabel)
                            .font(appDensity.font(.caption))
                            .frame(width: 52, alignment: .leading)
                        Text(row.service)
                            .font(appDensity.font(.caption))
                            .foregroundStyle(.primary)
                        Spacer()
                        if let durationLabel = row.durationLabel {
                            Text(durationLabel)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.appTextSecondary))
                        }
                        AppStatusBadgeView(model: portBadge(row))
                    }
                    if let banner = row.banner {
                        Text(banner)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(Color(.appTextSecondary))
                            .padding(.leading, 8)
                    }
                }
                .frame(minHeight: appDensity.metrics.rowMinHeight, alignment: .topLeading)
            }
        }
    }

    private func portBadge(_ row: PortScanRowViewData) -> AppStatusBadgeModel {
        switch row.statusTone {
        case .success:
            return .init(title: row.statusLabel, systemImage: "checkmark.circle.fill", foregroundColor: Color(.statusPositive), backgroundColor: Color(.statusPositiveSurface))
        case .warning:
            return .init(title: row.statusLabel, systemImage: "exclamationmark.triangle.fill", foregroundColor: Color(.statusWarning), backgroundColor: Color(.statusWarningSurface))
        case .failure:
            return .init(title: row.statusLabel, systemImage: "xmark.circle.fill", foregroundColor: Color(.statusCritical), backgroundColor: Color(.statusCriticalSurface))
        case .primary, .secondary:
            return .init(title: row.statusLabel, systemImage: "circle", foregroundColor: Color(.appTextSecondary), backgroundColor: Color(.appSurfaceElevated))
        }
    }
}

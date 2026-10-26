import SwiftUI

// One inspection section: the derived risk and timeline card. Pure
// presentation over the view model's report data; the shared primitives it
// builds on (CardView, SectionTitleView, LabeledValueRow, ResultColors,
// appLoadingStyle) live in ResultPrimitives.swift.

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
                                        .foregroundStyle(ThemeToken.textSecondary)
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
                                                .foregroundStyle(ThemeToken.warning)
                                        }
                                    }
                                    Text("First \(item.firstSeen.formatted(date: .abbreviated, time: .omitted)) • Last \(item.lastSeen.formatted(date: .abbreviated, time: .omitted)) • Seen \(item.recurrenceCount)x")
                                        .font(appDensity.font(.caption2))
                                        .foregroundStyle(ThemeToken.textSecondary)
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
                .foregroundStyle(ThemeToken.info)
            content()
        }
    }

    private func intelligenceEventRow(date: Date, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(appDensity.font(.caption2))
                .foregroundStyle(ThemeToken.textSecondary)
            Text(title)
                .font(appDensity.font(.caption))
        }
    }
}

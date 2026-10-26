import SwiftUI

struct BatchResultsView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.cardSpacing) {
            HStack(alignment: .top) {
                SectionTitleView(title: title)
                Spacer()
                if viewModel.batchLookupRunning {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: Double(viewModel.batchCompletedCount), total: Double(max(viewModel.batchTotalCount, 1)))
                            .tint(ThemeToken.info)
                            .frame(width: 120)
                        Text(viewModel.batchProgressLabel)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                } else if !viewModel.batchResults.isEmpty {
                    Text("\(viewModel.batchResults.count) domains")
                        .font(appDensity.font(.caption2))
                        .foregroundStyle(ThemeToken.textSecondary)
                }
            }

            if viewModel.batchResults.isEmpty {
                EmptyStateCardView(
                    title: "No Batch Results Yet",
                    message: "Batch runs collect availability, IP, and change status for multiple domains in one pass.",
                    suggestion: "Switch to Bulk mode, paste a list of domains, then run a batch lookup.",
                    systemImage: "square.stack.3d.up"
                )
            } else {
                CardView(allowsHorizontalScroll: false) {
                    ForEach(viewModel.batchResults) { result in
                        if let entry = viewModel.historyEntry(for: result) {
                            NavigationLink {
                                HistoryDetailView(viewModel: viewModel, entry: entry)
                            } label: {
                                BatchResultRowView(result: result)
                            }
                            .buttonStyle(.plain)
                        } else {
                            BatchResultRowView(result: result)
                        }
                    }
                }
            }
        }
    }
}

struct BatchResultRowView: View {
    @Environment(\.appDensity) private var appDensity
    let result: BatchLookupResult

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 1) {
            // Same reflow as WatchlistRowView: wide while it fits, stacked at
            // accessibility sizes so the badge cannot letter-wrap vertically.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    domainTitle
                    Spacer(minLength: 8)
                    sourceLabel
                    AppStatusBadgeView(model: quickStatusBadge)
                }
                VStack(alignment: .leading, spacing: 6) {
                    domainTitle
                    HStack(spacing: 8) {
                        AppStatusBadgeView(model: quickStatusBadge)
                        sourceLabel
                    }
                }
            }

            HStack(spacing: 10) {
                AppStatusBadgeView(model: availabilityBadgeModel)
                if let riskScore = result.riskScore, let riskLevel = result.riskLevel {
                    Text("Risk \(riskScore) \(riskLevel.title)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .font(appDensity.font(.caption2))
            .foregroundStyle(ThemeToken.textSecondary)

            HStack(spacing: 10) {
                Text(result.primaryIP ?? "No IP")
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(result.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
            }
            .font(appDensity.font(.caption2))
            .foregroundStyle(ThemeToken.textSecondary)

            if let summaryMessage = result.summaryMessage {
                Text(summaryMessage)
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(ThemeToken.textSecondary)
            }

            if let changeClassification = result.changeClassification {
                Text("Impact: \(changeClassification.title)")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(changeClassification.tone.foreground)
            }

            if let errorMessage = result.errorMessage {
                Text(errorMessage)
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(result.status == .failed ? ThemeToken.critical : ThemeToken.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .frame(minHeight: appDensity.metrics.rowMinHeight + 12, alignment: .topLeading)
        // One VoiceOver stop per row: domain as the label, status as the value,
        // everything else on the More Content rotor. Reading all eight text
        // elements inline would make a 200-domain sweep unnavigable. `.high`
        // importance is spoken without the rotor; the rest waits for a swipe.
        // Extracted to a modifier — inlined, the chain broke the type-checker.
        .modifier(BatchRowAccessibility(
            domain: result.domain,
            status: "\(quickStatusBadge.title), \(availabilityText)",
            risk: riskDescription,
            ip: result.primaryIP ?? "none",
            checked: result.timestamp.formatted(date: .abbreviated, time: .shortened),
            source: result.resultSource.label,
            changeLabel: changeContentLabel,
            changeValue: changeContentValue
        ))
    }

    private var domainTitle: some View {
        Text(result.domain)
            .font(appDensity.font(.callout))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceLabel: some View {
        Text(result.resultSource.label.lowercased())
            .font(appDensity.font(.caption2))
            .foregroundStyle(ThemeToken.textSecondary)
    }

    private var changeContentLabel: String {
        result.changeClassification != nil ? "Impact" : "Status"
    }

    private var changeContentValue: String {
        if let change = result.changeClassification {
            return change.title
        }
        return result.errorMessage ?? result.summaryMessage ?? quickStatusBadge.title
    }

    private var riskDescription: String {
        if let score = result.riskScore, let level = result.riskLevel {
            return "\(score), \(level.title)"
        }
        return "not scored"
    }

    private var availabilityText: String {
        switch result.availability {
        case .available:
            return "Available"
        case .registered:
            return "Registered"
        case .unknown, .none:
            return "Unknown"
        }
    }

    private var availabilityBadgeModel: AppStatusBadgeModel {
        guard result.status == .failed else {
            return AppStatusFactory.availability(result.availability)
        }

        return .init(
            title: availabilityText,
            systemImage: "exclamationmark.circle",
            foreground: .textSecondary,
            background: .surfaceElevated
        )
    }

    private var quickStatusBadge: AppStatusBadgeModel {
        switch result.status {
        case .pending:
            return .init(title: "Pending", systemImage: "clock", foreground: .textSecondary, background: .surfaceElevated)
        case .running:
            return .init(title: "Running", systemImage: "arrow.clockwise", foreground: .info, background: .infoSurface)
        case .completed:
            if result.changeClassification == .critical || result.certificateWarningLevel == .critical || result.riskLevel == .high {
                return .init(title: "Critical", systemImage: "exclamationmark.octagon.fill", foreground: .critical, background: .criticalSurface)
            }
            if result.changeClassification == .warning || result.changeSeverity == .medium || result.certificateWarningLevel == .warning {
                return .init(title: "Warning", systemImage: "exclamationmark.triangle.fill", foreground: .warning, background: .warningSurface)
            }
            if result.quickStatus == "Changed" {
                return .init(title: "Changed", systemImage: "arrow.triangle.2.circlepath", foreground: .info, background: .infoSurface)
            }
            return .init(title: "Stable", systemImage: "checkmark.circle.fill", foreground: .positive, background: .positiveSurface)
        case .failed:
            return .init(title: "Failed", systemImage: "xmark.circle.fill", foreground: .critical, background: .criticalSurface)
        }
    }
}

/// Row-level VoiceOver treatment for a batch result: a single element whose
/// label is the domain and whose value is the status, with the remaining fields
/// on the More Content rotor. Extracted from the row body because inlining the
/// full modifier chain broke Swift's type-checker.
private struct BatchRowAccessibility: ViewModifier {
    let domain: String
    let status: String
    let risk: String
    let ip: String
    let checked: String
    let source: String
    let changeLabel: String
    let changeValue: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(domain)
            .accessibilityValue(status)
            .accessibilityCustomContent("Risk", risk, importance: .high)
            .accessibilityCustomContent("IP address", ip)
            .accessibilityCustomContent("Checked", checked)
            .accessibilityCustomContent("Source", source)
            .accessibilityCustomContent(LocalizedStringResource(stringLiteral: changeLabel), changeValue)
    }
}

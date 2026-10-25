import SwiftUI

// Snapshot comparison: the change summary and the diff list. Split out of
// ContentView.swift (A13).

struct DomainChangeSummaryView: View {
    @Environment(\.appDensity) private var appDensity
    let summary: DomainChangeSummary
    @State private var showsDetails = false

    var body: some View {
        CardView(allowsHorizontalScroll: false) {
            HStack {
                Label(summary.hasChanges ? "Changed" : "Stable", systemImage: summary.hasChanges ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(appDensity.font(.caption))
                    .foregroundStyle(summary.hasChanges ? severityTone(summary.severity).foreground : Color(.statusPositive))
                Spacer()
                Text(summary.severity.title.uppercased())
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(summary.hasChanges ? severityTone(summary.severity).foreground : Color(.appTextSecondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((summary.hasChanges ? severityTone(summary.severity) : AppStatusTone.neutral).surface)
                    .clipShape(Capsule())
                Text(summary.impactClassification.title.uppercased())
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(summary.impactClassification.tone.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(summary.impactClassification.tone.surface)
                    .clipShape(Capsule())
                Text(summary.generatedAt, style: .time)
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Inference")
                    .font(appDensity.font(.caption2))
                    .foregroundStyle(Color(.appTextSecondary))
                Text(summary.message)
                    .font(appDensity.font(.caption))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            if !summary.observedFacts.isEmpty || summary.contextNote != nil {
                DisclosureGroup(showsDetails ? "Hide Details" : "Show Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !summary.observedFacts.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Observed")
                                    .font(appDensity.font(.caption2))
                                    .foregroundStyle(Color(.appTextSecondary))
                                ForEach(Array(summary.observedFacts.enumerated()), id: \.offset) { _, fact in
                                    Text(fact)
                                        .font(appDensity.font(.caption))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }

                        if let riskScoreDelta = summary.riskScoreDelta {
                            Text("Risk delta: \(riskScoreDelta >= 0 ? "+" : "")\(riskScoreDelta)")
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(riskScoreDelta > 0 ? Color(.statusWarning) : .secondary)
                        }

                        if let contextNote = summary.contextNote {
                            Text(contextNote)
                                .font(appDensity.font(.caption2))
                                .foregroundStyle(Color(.statusWarning))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(appDensity.font(.caption))
                .tint(.secondary)
            }
        }
    }

    private func severityTone(_ severity: ChangeSeverity) -> AppStatusTone {
        switch severity {
        case .low:
            return .neutral
        case .medium:
            return .warning
        case .high:
            return .critical
        }
    }

}

struct DomainDiffView: View {
    let title: String
    let sections: [DomainDiffSection]
    let contextNote: String?
    let showsUnchanged: Bool
    let highlightedSectionID: String?

    @State private var collapsedSections = Set<String>()
    @State private var showsLowSeverity = false

    private var filteredSections: [DomainDiffSection] {
        sections
            .map { section in
                let items = section.items.filter { item in
                    if !showsUnchanged, !item.hasChanges {
                        return false
                    }
                    if showsLowSeverity {
                        return true
                    }
                    return item.severity >= .medium || (showsUnchanged && item.changeType == .unchanged)
                }
                return DomainDiffSection(id: section.id, title: section.title, items: items)
            }
            .filter { !$0.items.isEmpty }
    }

    private var hasLowSeverityChanges: Bool {
        sections.flatMap(\.items).contains { $0.hasChanges && $0.severity == .low }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitleView(title: title)
                Spacer()
                if hasLowSeverityChanges {
                    Button(showsLowSeverity ? "Hide Low" : "Show Low") {
                        showsLowSeverity.toggle()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(.caption, design: .monospaced))
                }
            }
            if let contextNote {
                MessageCardView(text: contextNote, isError: false)
            }
            if filteredSections.isEmpty {
                MessageCardView(text: "No comparison data available", isError: false)
            } else {
                ForEach(filteredSections) { section in
                    CardView(allowsHorizontalScroll: false) {
                        DisclosureGroup(isExpanded: binding(for: section)) {
                            let visibleItems = showsUnchanged ? section.items : section.items.filter(\.hasChanges)

                            ForEach(visibleItems) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.label)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(Color(.appTextSecondary))
                                        Spacer()
                                        Text("\(item.changeType.marker) \(item.severity.title) • \(changeLabel(for: item.changeType))")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(changeTone(for: item).foreground)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(changeTone(for: item).surface)
                                            .clipShape(Capsule())
                                    }

                                    if let oldValue = item.oldValue {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Old")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(Color(.appTextSecondary))
                                            Text(oldValue)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(Color(.appTextSecondary))
                                                .textSelection(.enabled)
                                        }
                                    }

                                    if let newValue = item.newValue {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("New")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(Color(.appTextSecondary))
                                            Text(newValue)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(item.hasChanges ? .primary : .secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(item.hasChanges ? changeTone(for: item).surface : Color(.appSurface))
                                .cornerRadius(8)
                            }
                        } label: {
                            HStack {
                                Text(section.title)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(sectionColor(section))
                                Spacer()
                                Text(section.severity.title)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(sectionColor(section))
                            }
                        }
                    }
                    .id(section.id)
                    .overlay {
                        if highlightedSectionID == section.id {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.statusInfo).opacity(0.55), lineWidth: 1)
                        }
                    }
                }
            }
        }
        .onAppear {
            collapsedSections = Set(sections.filter { !showsUnchanged && !$0.hasChanges }.map(\.id))
        }
    }

    private func changeLabel(for changeType: DiffChangeType) -> String {
        switch changeType {
        case .added:
            return "Added"
        case .removed:
            return "Removed"
        case .changed:
            return "Changed"
        case .unchanged:
            return "Unchanged"
        }
    }

    private func changeTone(for item: DomainDiffItem) -> AppStatusTone {
        if item.changeType == .unchanged {
            return .neutral
        }

        switch item.severity {
        case .low:
            return .info
        case .medium:
            return .warning
        case .high:
            return .critical
        }
    }

    private func sectionColor(_ section: DomainDiffSection) -> Color {
        switch section.severity {
        case .low:
            return .blue
        case .medium:
            return Color(.statusWarning)
        case .high:
            return Color(.statusCritical)
        }
    }

    private func binding(for section: DomainDiffSection) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(section.id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSections.remove(section.id)
                } else {
                    collapsedSections.insert(section.id)
                }
            }
        )
    }
}

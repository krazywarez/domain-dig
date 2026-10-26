import SwiftUI

// One inspection section: the availability and domain card. Pure presentation
// over the view model's report data; the shared primitives it builds on
// (CardView, SectionTitleView, LabeledValueRow, ResultColors, appLoadingStyle)
// live in ResultPrimitives.swift.

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
                        .foregroundStyle(ThemeToken.positive)
                        .padding(6)
                        .background(ThemeToken.positiveSurface, in: Circle())
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
                            .foregroundStyle(ThemeToken.textSecondary)

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
                        .foregroundStyle(ThemeToken.textSecondary)
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
            }
        }
    }
}

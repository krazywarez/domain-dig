import SwiftUI

struct TimelineView: View {
    @Environment(\.appDensity) private var appDensity
    @Bindable var viewModel: DomainViewModel
    let domain: String

    @State private var presentedDiff: DomainDiff?
    @State private var focusedSectionID: String?

    private var timelineSections: [TimelineSection] {
        viewModel.timelineSections(for: domain)
    }

    private var compareButtonDisabled: Bool {
        viewModel.selectedSnapshots.count != 2 && viewModel.historyEntries(for: domain).count < 2
    }

    var body: some View {
        List {
            ForEach(timelineSections) { section in
                Section(section.title) {
                    ForEach(section.entries) { summary in
                        if let entry = viewModel.historyEntry(withID: summary.historyEntryID) {
                            NavigationLink {
                                HistoryDetailView(viewModel: viewModel, entry: entry)
                            } label: {
                                TimelineRow(summary: summary, entry: entry)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    viewModel.toggleSnapshotSelection(entry)
                                } label: {
                                    Label(
                                        viewModel.selectedSnapshotIDs.contains(entry.id) ? "Selected" : "Compare",
                                        systemImage: viewModel.selectedSnapshotIDs.contains(entry.id) ? "checkmark.circle.fill" : "arrow.left.arrow.right"
                                    )
                                }

                                Button(role: .destructive) {
                                    viewModel.removeHistoryEntries(withIDs: [entry.id])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .themedListRowBackground(.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeToken.background)
        .navigationTitle(domain)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Grouping", selection: $viewModel.timelineGrouping) {
                        ForEach(TimelineGroupingOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Group timeline")

                Button("Compare") {
                    if viewModel.selectedSnapshots.count == 2 {
                        presentedDiff = viewModel.generateDiffForSelectedSnapshots()
                    } else {
                        let entries = viewModel.historyEntries(for: domain)
                        guard entries.count >= 2 else { return }
                        presentedDiff = viewModel.generateDiff(from: entries[1], to: entries[0])
                    }
                    focusedSectionID = viewModel.currentDiffTargetSectionID
                }
                .disabled(compareButtonDisabled)

                Menu("Export") {
                    Button("Export TXT") {
                        ExportPresenter.share(
                            filename: "\(domain)-timeline.txt",
                            contents: viewModel.exportTimelineText(domain: domain, includeDiffSummary: true)
                        )
                    }

                    Button("Export JSON") {
                        guard let data = viewModel.exportTimelineJSONData(domain: domain, includeDiffSummary: true) else { return }
                        ExportPresenter.share(filename: "\(domain)-timeline.json", data: data)
                    }
                }
            }
        }
        .sheet(item: $presentedDiff) { diff in
            NavigationStack {
                TimelineDiffView(viewModel: viewModel, diff: diff, focusedSectionID: $focusedSectionID)
            }
        }
    }
}

private struct TimelineRow: View {
    @Environment(\.appDensity) private var appDensity
    let summary: SnapshotSummary
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: appDensity.metrics.rowSpacing + 1) {
            HStack(alignment: .center, spacing: 8) {
                Text(summary.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(appDensity.font(.callout))
                    .foregroundStyle(.primary)
                Spacer()
                if let severity = summary.severitySummary {
                    AppStatusBadgeView(
                        model: .init(
                            title: severity.title,
                            systemImage: "arrow.triangle.2.circlepath",
                            foreground: severity == .high ? .critical : .warning,
                            background: (severity == .high ? AppStatusTone.critical : .warning).surface
                        )
                    )
                }
            }

            Text(summary.changeSummaryMessage ?? "No change summary")
                .font(appDensity.font(.caption))
                .foregroundStyle(ThemeToken.textSecondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                AppStatusBadgeView(model: AppStatusFactory.availability(summary.availability))
                if let riskScore = summary.riskScore {
                    Text("Risk \(riskScore)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .font(appDensity.font(.caption2))
            .foregroundStyle(ThemeToken.textSecondary)

            if !entry.intelligenceTimeline.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.intelligenceTimeline.prefix(2))) { event in
                        Text("\(event.title): \(event.detail)")
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(ThemeToken.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                if let primaryIP = summary.primaryIP {
                    Text(primaryIP)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(summary.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
            }
            .font(appDensity.font(.caption2))
            .foregroundStyle(ThemeToken.textSecondary)
        }
    }
}

struct TimelineDiffView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: DomainViewModel
    let diff: DomainDiff
    @Binding var focusedSectionID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Previous Change") {
                            viewModel.moveToPreviousDiffChange()
                            focusedSectionID = viewModel.currentDiffTargetSectionID
                            scroll(proxy: proxy)
                        }
                        .disabled(viewModel.activeDiffChangeIndex == 0)

                        Button("Next Change") {
                            viewModel.moveToNextDiffChange()
                            focusedSectionID = viewModel.currentDiffTargetSectionID
                            scroll(proxy: proxy)
                        }
                        .disabled(viewModel.activeDomainDiff?.changedSectionIDs.isEmpty != false || viewModel.currentDiffTargetSectionID == viewModel.activeDomainDiff?.changedSectionIDs.last)

                        Spacer()
                    }

                    DomainDiffView(
                        title: "Snapshot Diff",
                        sections: diff.sections,
                        contextNote: diff.contextNote,
                        showsUnchanged: false,
                        highlightedSectionID: focusedSectionID
                    )
                }
                .padding()
            }
            .background(ThemeToken.background)
            .navigationTitle("Compare Snapshots")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                scroll(proxy: proxy)
            }
            .onChange(of: focusedSectionID) { _, _ in
                scroll(proxy: proxy)
            }
        }
    }

    private func scroll(proxy: ScrollViewProxy) {
        guard let focusedSectionID else { return }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(focusedSectionID, anchor: .top)
        }
    }
}

import SwiftUI

struct BatchSweepSummaryView: View {
    @Bindable var viewModel: DomainViewModel
    let summary: BatchSweepSummary

    @State private var showUnchangedDomains = false

    private var visibleResults: [BatchLookupResult] {
        if showUnchangedDomains {
            return summary.results
        }

        return summary.results.filter(\.hasMeaningfulChange)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Overview") {
                    statRow(label: "Checked", value: "\(summary.totalDomains)")
                    statRow(label: "Changed", value: "\(summary.changedDomains)")
                    statRow(label: "Warnings", value: "\(summary.warningDomains)")
                    statRow(label: "Unchanged", value: "\(summary.unchangedDomains)")
                }

                Section {
                    Toggle("Show unchanged domains", isOn: $showUnchangedDomains)
                }

                BatchResultsSection(
                    viewModel: viewModel,
                    results: visibleResults,
                    emptyTitle: "Changed Domains",
                    emptyText: "No domains with changes or warnings"
                )
            }
            .navigationTitle(summary.source == .watchlistRefresh ? "Sweep Summary" : "Batch Summary")
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(.appTextSecondary))
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

/// A batch's results, each opening its history entry where one was saved.
/// Titled `emptyTitle`, with `emptyText` under it, when nothing is shown.
struct BatchResultsSection: View {
    @Bindable var viewModel: DomainViewModel
    let results: [BatchLookupResult]
    let emptyTitle: String
    let emptyText: String

    var body: some View {
        Section(results.isEmpty ? emptyTitle : "Results") {
            if results.isEmpty {
                Text(emptyText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(.appTextSecondary))
            } else {
                ForEach(results) { result in
                    if let entry = viewModel.historyEntry(for: result) {
                        NavigationLink {
                            HistoryDetailView(viewModel: viewModel, entry: entry)
                        } label: {
                            BatchResultRowView(result: result)
                        }
                    } else {
                        BatchResultRowView(result: result)
                    }
                }
            }
        }
    }
}

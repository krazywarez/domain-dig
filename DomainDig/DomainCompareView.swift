import SwiftUI

/// Side-by-side comparison of two tracked domains' latest reports, reusing the
/// same section-diff rendering (`DomainDiffView`) that time-based history diffs
/// use, via `DiffService.compare(domainA:domainB:)`.
struct DomainCompareView: View {
    @Bindable var viewModel: DomainViewModel
    @State private var domainAID: UUID?
    @State private var domainBID: UUID?

    private var states: [PortfolioDomainStatus] {
        viewModel.portfolioDashboardData.domainStates
    }

    private var stateA: PortfolioDomainStatus? {
        states.first { $0.trackedDomain.id == domainAID }
    }

    private var stateB: PortfolioDomainStatus? {
        states.first { $0.trackedDomain.id == domainBID }
    }

    private var result: DomainComparisonResult? {
        guard let stateA, let stateB, stateA.trackedDomain.id != stateB.trackedDomain.id else {
            return nil
        }
        return DiffService.compare(domainA: stateA.report, domainB: stateB.report)
    }

    var body: some View {
        List {
            Section("Domains") {
                domainPicker("Domain A", selection: $domainAID)
                domainPicker("Domain B", selection: $domainBID)
            }

            if domainAID != nil, domainAID == domainBID {
                Section {
                    Text("Choose two different domains to compare.")
                        .font(.callout)
                        .foregroundStyle(ThemeToken.textSecondary)
                }
            }

            if let result {
                Section {
                    DomainDiffView(
                        title: "\(result.domainA) vs \(result.domainB)",
                        sections: result.sections,
                        contextNote: result.contextNote,
                        showsUnchanged: true,
                        highlightedSectionID: nil
                    )
                }
                .listRowBackground(Color.clear)
            } else if domainAID == nil || domainBID == nil {
                Section {
                    EmptyStateCardView(
                        title: "Pick Two Domains",
                        message: "Select a domain in each slot to see a side-by-side comparison across DNS, TLS, ownership, and risk.",
                        suggestion: "Both domains must already be tracked.",
                        systemImage: "arrow.left.arrow.right",
                        showsCardBackground: false
                    )
                }
                .themedListRowBackground(.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeToken.background)
        .navigationTitle("Compare Domains")
    }

    private func domainPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("Select a domain").tag(UUID?.none)
            ForEach(states) { state in
                Text(state.trackedDomain.domain).tag(Optional(state.trackedDomain.id))
            }
        }
    }
}

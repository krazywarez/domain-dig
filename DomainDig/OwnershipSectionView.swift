import SwiftUI

// One inspection section: the registration and ownership card. Pure
// presentation over the view model's report data; the shared primitives it
// builds on (CardView, SectionTitleView, LabeledValueRow, ResultColors,
// appLoadingStyle) live in ResultPrimitives.swift.

struct OwnershipSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    let rows: [InfoRowViewData]
    let loading: Bool
    let error: String?
    let provenance: SectionProvenance?
    let confidence: ConfidenceLevel?
    let history: [DomainOwnershipHistoryEvent]
    let historyLoading: Bool
    let historyError: String?
    let onLoadHistory: (() -> Void)?

    init(
        isCollapsed: Binding<Bool>,
        rows: [InfoRowViewData],
        loading: Bool,
        error: String?,
        provenance: SectionProvenance?,
        confidence: ConfidenceLevel?,
        history: [DomainOwnershipHistoryEvent] = [],
        historyLoading: Bool = false,
        historyError: String? = nil,
        onLoadHistory: (() -> Void)? = nil
    ) {
        _isCollapsed = isCollapsed
        self.rows = rows
        self.loading = loading
        self.error = error
        self.provenance = provenance
        self.confidence = confidence
        self.history = history
        self.historyLoading = historyLoading
        self.historyError = historyError
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
                    .foregroundStyle(ThemeToken.textSecondary)
                Spacer()
                if let onLoadHistory, history.isEmpty, !historyLoading {
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
                            .foregroundStyle(ThemeToken.textSecondary)
                        Text(event.summary)
                            .font(appDensity.font(.caption))
                        Text(event.source)
                            .font(appDensity.font(.caption2))
                            .foregroundStyle(ThemeToken.textSecondary)
                    }
                }
            } else if let historyError {
                MessageRowView(text: historyError, isError: false)
            }
        }
    }
}

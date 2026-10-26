import SwiftUI

/// Settings → App Info. Shows app/build metadata and links out to docs, source,
/// privacy, support, and the App Store. The actionable rows are driven by a
/// single declarative `AppInfoRow` model so titles, icons, and destinations live
/// in one place; only the Share row is special-cased (a `ShareLink` view).
struct AppInfoView: View {
    @Environment(\.openURL) private var openURL
    @State private var cloudSyncService = CloudSyncService.shared
    @State private var activeSheet: AppInfoSheet?

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: AppInfo.versionDisplay)
                LabeledContent("Storage", value: cloudSyncService.isEnabled ? "Local-first + iCloud" : "Local-only")
                LabeledContent("Backup Schema", value: "v\(DomainDigBackup.currentSchemaVersion)")
                LabeledContent("Minimum iOS", value: AppInfo.minimumOS)
            }

            Section("Resources") {
                ForEach(resourceRows) { row($0) }
            }

            Section("Support") {
                ForEach(supportRows) { row($0) }
            }

            Section {
                Button {
                    openURL(AppLinks.writeReview)
                } label: {
                    Label("Rate DomainDig", systemImage: "star")
                }
                .accessibilityHint("Opens the App Store")

                ShareLink(item: AppLinks.appStoreListing) {
                    Label("Share DomainDig", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("Opens the share sheet")
            } header: {
                Text("Support the App")
            } footer: {
                Text(AppLinks.copyright)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("App Info")
        .task {
            await cloudSyncService.refreshAvailability()
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .whatsNew:
                    WhatsNewView()
                case .acknowledgements:
                    AcknowledgementsView()
                case .reportIssue:
                    ReportIssueView()
                }
            }
        }
    }

    private var resourceRows: [AppInfoRow] {
        [
            AppInfoRow(title: "What's New", systemImage: "sparkles", action: .sheet(.whatsNew)),
            AppInfoRow(title: "Documentation & FAQ", systemImage: "book", action: .openURL(AppLinks.documentation)),
            AppInfoRow(title: "Source Code", systemImage: "chevron.left.forwardslash.chevron.right", action: .openURL(AppLinks.sourceCode)),
            AppInfoRow(title: "Privacy Policy", systemImage: "hand.raised", action: .openURL(AppLinks.privacyPolicy)),
            AppInfoRow(title: "Acknowledgements", systemImage: "checkmark.seal", action: .sheet(.acknowledgements))
        ]
    }

    private var supportRows: [AppInfoRow] {
        [
            AppInfoRow(title: "Report an Issue", systemImage: "ladybug", action: .sheet(.reportIssue)),
            AppInfoRow(
                title: "Contact",
                systemImage: "envelope",
                action: .mail(address: AppLinks.supportEmail, subject: "DomainDig", body: "")
            )
        ]
    }

    @ViewBuilder
    private func row(_ item: AppInfoRow) -> some View {
        switch item.action {
        case .openURL(let url):
            Link(destination: url) {
                Label(item.title, systemImage: item.systemImage)
            }
            .accessibilityHint("Opens outside the app")
        case .mail(let address, let subject, let body):
            Button {
                if let url = Self.mailURL(to: address, subject: subject, body: body) {
                    openURL(url)
                }
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
            .accessibilityHint("Opens your mail app")
        case .sheet(let sheet):
            Button {
                activeSheet = sheet
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
        }
    }

    static func mailURL(to address: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        var query: [URLQueryItem] = []
        if !subject.isEmpty { query.append(URLQueryItem(name: "subject", value: subject)) }
        if !body.isEmpty { query.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}

private struct AppInfoRow: Identifiable {
    enum Action {
        case openURL(URL)
        case mail(address: String, subject: String, body: String)
        case sheet(AppInfoSheet)
    }

    let id = UUID()
    let title: String
    let systemImage: String
    let action: Action
}

private enum AppInfoSheet: String, Identifiable {
    case whatsNew
    case acknowledgements
    case reportIssue

    var id: String { rawValue }
}

// MARK: - Sheets

private struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    private let notes = ReleaseNotes.bundled()

    var body: some View {
        Form {
            if let notes {
                Section {
                    ForEach(Array(notes.highlights.enumerated()), id: \.offset) { _, highlight in
                        Label(highlight, systemImage: "sparkle")
                            .labelStyle(.titleAndIcon)
                    }
                } header: {
                    Text("Version \(notes.version)")
                }
            } else {
                Section {
                    Text("Release notes are unavailable.")
                        .foregroundStyle(ThemeToken.textSecondary)
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Dependencies") {
                Text("DomainDig has no third-party dependencies. It is built entirely on Apple's frameworks.")
            }
            Section("License") {
                Text("DomainDig is released under the MIT License.")
                Text(AppLinks.copyright)
                    .foregroundStyle(ThemeToken.textSecondary)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct ReportIssueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let diagnostics = AppInfo.diagnosticsReport

    var body: some View {
        Form {
            Section {
                Text("These details are included so issues can be reproduced. They are only added when you send a report — nothing is collected in the background.")
                    .foregroundStyle(ThemeToken.textSecondary)
            }

            Section("Included Diagnostics") {
                Text(diagnostics)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section {
                Button {
                    if let url = AppInfoView.mailURL(
                        to: AppLinks.supportEmail,
                        subject: "DomainDig Issue Report",
                        body: "\n\n---\n\(diagnostics)"
                    ) {
                        openURL(url)
                    }
                } label: {
                    Label("Email Report", systemImage: "envelope")
                }
                .accessibilityHint("Opens your mail app with the diagnostics prefilled")

                Link(destination: AppLinks.sourceCode.appendingPathComponent("issues/new")) {
                    Label("Open on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityHint("Opens outside the app")
            }
        }
        .navigationTitle("Report an Issue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

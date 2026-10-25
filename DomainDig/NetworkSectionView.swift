import MapKit
import SwiftUI

// One inspection section: the reachability, location and ports cards. Pure
// presentation over the view model's report data; the shared primitives it
// builds on (CardView, SectionTitleView, LabeledValueRow, ResultColors,
// appLoadingStyle) live in ResultPrimitives.swift.

struct NetworkSectionView: View {
    @Environment(\.appDensity) private var appDensity
    @Binding var isCollapsed: Bool
    @Binding var customPortsExpanded: Bool
    @Binding var customPortInput: String
    let onScanCustomPorts: () -> Void

    private let reachabilityRows: [ReachabilityRowViewData]
    private let reachabilityLoading: Bool
    private let reachabilityError: String?
    private let reachabilityProvenance: SectionProvenance?
    private let locationRows: [InfoRowViewData]
    private let geolocation: IPGeolocation?
    private let geolocationLoading: Bool
    private let geolocationError: String?
    private let geolocationProvenance: SectionProvenance?
    private let geolocationConfidence: ConfidenceLevel?
    private let standardPortRows: [PortScanRowViewData]
    private let customPortRows: [PortScanRowViewData]
    private let portScanLoading: Bool
    private let portScanError: String?
    private let portScanProvenance: SectionProvenance?
    private let customPortScanLoading: Bool
    private let customPortScanError: String?
    private let isCloudflareProxied: Bool

    init(
        isCollapsed: Binding<Bool>,
        customPortsExpanded: Binding<Bool>,
        customPortInput: Binding<String>,
        data: NetworkSectionViewData,
        onScanCustomPorts: @escaping () -> Void
    ) {
        _isCollapsed = isCollapsed
        _customPortsExpanded = customPortsExpanded
        _customPortInput = customPortInput
        self.onScanCustomPorts = onScanCustomPorts
        reachabilityRows = data.reachabilityRows
        reachabilityLoading = data.reachability.isLoading
        reachabilityError = data.reachability.error
        reachabilityProvenance = data.reachability.provenance
        locationRows = data.locationRows
        geolocation = data.geolocation
        geolocationLoading = data.location.isLoading
        geolocationError = data.location.error
        geolocationProvenance = data.location.provenance
        geolocationConfidence = data.location.confidence
        standardPortRows = data.standardPortRows
        customPortRows = data.customPortRows
        portScanLoading = data.portScan.isLoading
        portScanError = data.portScan.error
        portScanProvenance = data.portScan.provenance
        customPortScanLoading = data.customPortScan.isLoading
        customPortScanError = data.customPortScan.error
        isCloudflareProxied = data.isCloudflareProxied
    }

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

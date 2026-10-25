import SwiftUI

// What each result section needs in order to draw itself. Split out of
// ResultSectionViews.swift along with the views that consume them (A13).

// MARK: - Section view data

/// What one card inside a result section needs to know about its own state:
/// whether the data is still arriving, what failed, where it came from and how
/// much to trust it.
///
/// These four travelled as a positional group repeated once per card, which is
/// how `NetworkSectionView` came to declare 22 init parameters and
/// `WebSectionView` 17 (A10). The views keep their own stored properties —
/// unpacking happens in the init, so the bodies are unchanged — but a caller
/// now names three groups instead of counting out twenty-two arguments.
struct SectionPanelViewData {
    var isLoading = false
    var error: String?
    var provenance: SectionProvenance?
    var confidence: ConfidenceLevel?
}

/// The Web section's three cards: TLS, headers, redirects.
struct WebSectionViewData {
    var tls = SectionPanelViewData()
    var certificateRows: [InfoRowViewData] = []
    var sslInfo: SSLCertificateInfo?
    var tlsSummary: WebResultSummary?

    var http = SectionPanelViewData()
    var responseRows: [InfoRowViewData] = []
    var headers: [HTTPHeader] = []

    var redirect = SectionPanelViewData()
    var redirectRows: [RedirectHopViewData] = []
    var finalURL: String?
}

/// The Network section's cards: reachability, location, ports. Custom port
/// scanning carries its own state because it runs separately, after the user
/// asks for it.
struct NetworkSectionViewData {
    var reachability = SectionPanelViewData()
    var reachabilityRows: [ReachabilityRowViewData] = []

    var location = SectionPanelViewData()
    var locationRows: [InfoRowViewData] = []
    var geolocation: IPGeolocation?

    var portScan = SectionPanelViewData()
    var standardPortRows: [PortScanRowViewData] = []
    var customPortRows: [PortScanRowViewData] = []
    var customPortScan = SectionPanelViewData()

    var isCloudflareProxied = false
}

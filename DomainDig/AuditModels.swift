import Foundation

enum AuditStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case draft
    case inReview = "in_review"
    case complete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draft:
            return "Draft"
        case .inReview:
            return "In Review"
        case .complete:
            return "Complete"
        }
    }
}

enum AuditFindingSeverity: String, Codable, Sendable, CaseIterable, Identifiable {
    case informational
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

enum AuditFindingStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case open
    case reviewing
    case resolved

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

enum AuditChecklistArea: String, Codable, Sendable, CaseIterable, Identifiable {
    case dnsReview
    case certificateReview
    case redirectReview
    case headerReview
    case ownershipReview
    case infrastructureReview
    case monitoringHistoryReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dnsReview:
            return "DNS Review"
        case .certificateReview:
            return "Certificate Review"
        case .redirectReview:
            return "Redirect Review"
        case .headerReview:
            return "Header Review"
        case .ownershipReview:
            return "Ownership Review"
        case .infrastructureReview:
            return "Infrastructure Review"
        case .monitoringHistoryReview:
            return "Monitoring History Review"
        }
    }

    var prompt: String {
        switch self {
        case .dnsReview:
            return "Validate authoritative records, nameservers, and DNSSEC posture."
        case .certificateReview:
            return "Review certificate validity, expiry, issuer, and transport security."
        case .redirectReview:
            return "Confirm redirect targets, hop count, and protocol transitions."
        case .headerReview:
            return "Check security headers and HTTP response posture."
        case .ownershipReview:
            return "Review registration, registrar, and ownership evidence."
        case .infrastructureReview:
            return "Assess reachability, exposed services, and network context."
        case .monitoringHistoryReview:
            return "Compare this audit with prior snapshots and repeated issues."
        }
    }
}

struct AuditChecklistItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let area: AuditChecklistArea
    var title: String
    var detail: String
    var isComplete: Bool
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        area: AuditChecklistArea,
        title: String,
        detail: String,
        isComplete: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.area = area
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
        self.completedAt = completedAt
    }
}

enum AuditEvidenceAssetKind: String, Codable, Sendable {
    case screenshot
    case document
    case note
}

struct AuditEvidenceAsset: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    var kind: AuditEvidenceAssetKind
    var reference: String

    init(id: UUID = UUID(), title: String, kind: AuditEvidenceAssetKind, reference: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.reference = reference
    }
}

struct AuditEvidenceSnapshot: Codable {
    var capturedAt: Date
    var lookup: HistoryEntry
    var report: DomainReport
    var historicalContext: [SnapshotSummary]
    var screenshots: [AuditEvidenceAsset]
}

struct AuditFinding: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var severity: AuditFindingSeverity
    var summary: String
    var evidenceReferences: [String]
    var notes: String
    var status: AuditFindingStatus
    var checklistAreas: [AuditChecklistArea]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        severity: AuditFindingSeverity,
        summary: String,
        evidenceReferences: [String],
        notes: String,
        status: AuditFindingStatus = .open,
        checklistAreas: [AuditChecklistArea] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.summary = summary
        self.evidenceReferences = evidenceReferences
        self.notes = notes
        self.status = status
        self.checklistAreas = checklistAreas
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AuditSession: Identifiable, Codable {
    var id: UUID
    var domain: String
    var createdAt: Date
    var reviewer: String
    var status: AuditStatus
    var evidence: AuditEvidenceSnapshot
    var findings: [AuditFinding]
    var notes: String
    var checklist: [AuditChecklistItem]

    init(
        id: UUID = UUID(),
        domain: String,
        createdAt: Date = Date(),
        reviewer: String,
        status: AuditStatus,
        evidence: AuditEvidenceSnapshot,
        findings: [AuditFinding] = [],
        notes: String = "",
        checklist: [AuditChecklistItem] = AuditChecklistArea.defaultItems
    ) {
        self.id = id
        self.domain = domain
        self.createdAt = createdAt
        self.reviewer = reviewer
        self.status = status
        self.evidence = evidence
        self.findings = findings
        self.notes = notes
        self.checklist = checklist
    }

    var completedChecklistCount: Int {
        checklist.filter(\.isComplete).count
    }

    var checklistProgress: Double {
        guard !checklist.isEmpty else { return 0 }
        return Double(completedChecklistCount) / Double(checklist.count)
    }

    var highestSeverity: AuditFindingSeverity? {
        findings.max { lhs, rhs in
            lhs.severity.sortOrder < rhs.severity.sortOrder
        }?.severity
    }

    var keyRisks: [AuditFinding] {
        findings
            .filter { $0.severity == .high || $0.severity == .medium }
            .sorted { lhs, rhs in
                if lhs.severity.sortOrder == rhs.severity.sortOrder {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.severity.sortOrder > rhs.severity.sortOrder
            }
    }
}

extension AuditFindingSeverity {
    var sortOrder: Int {
        switch self {
        case .informational:
            return 0
        case .low:
            return 1
        case .medium:
            return 2
        case .high:
            return 3
        }
    }
}

extension AuditChecklistArea {
    static var defaultItems: [AuditChecklistItem] {
        allCases.map { area in
            AuditChecklistItem(
                area: area,
                title: area.title,
                detail: area.prompt
            )
        }
    }
}

struct AuditTimelinePoint: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let domain: String
    let createdAt: Date
    let status: AuditStatus
    let findingCount: Int
    let openHighSeverityCount: Int
    let repeatedIssueCount: Int
}

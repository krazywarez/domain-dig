import Foundation
import SwiftUI

/// Workflow surface of `DomainViewModel`: looking up workflows, the
/// collaboration permission checks for a workflow, the CRUD mutators, and
/// running a workflow's domains as a batch.
///
/// `runWorkflow`/`rerunCurrentDomain` drive `startBatchLookup` (the shared batch
/// primitive used by manual and watchlist runs too), which stays on the main
/// type along with `persistWorkflows` and the `normalizedDomain(s)` helpers.
extension DomainViewModel {
    func workflow(withID id: UUID) -> DomainWorkflow? {
        workflows.first(where: { $0.id == id })
    }

    func workflowsContaining(domain: String) -> [DomainWorkflow] {
        let normalized = normalizedDomain(domain)
        guard !normalized.isEmpty else { return [] }
        return workflows.filter { workflow in
            workflow.domains.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
        }
    }

    func canEdit(_ workflow: DomainWorkflow) -> Bool {
        workflow.collaboration?.canEdit ?? true
    }

    func canDelete(_ workflow: DomainWorkflow) -> Bool {
        workflow.collaboration?.isOwner ?? true
    }

    func collaborationLabel(for workflow: DomainWorkflow) -> String? {
        guard let collaboration = workflow.collaboration, collaboration.isShared else { return nil }
        return "\(collaboration.ownership.title) • \(collaboration.permission.title)"
    }

    @discardableResult
    func createWorkflow(name: String, domains: [String], notes: String? = nil) -> DomainWorkflow? {
        let normalizedDomains = normalizedDomains(domains)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !normalizedDomains.isEmpty else { return nil }
        guard FeatureAccessService.canCreateWorkflow(currentCount: workflows.count) else {
            upgradePrompt = FeatureAccessService.upgradePromptForWorkflows(currentCount: workflows.count)
            return nil
        }

        let workflow = DomainWorkflow(
            name: trimmedName,
            domains: normalizedDomains,
            createdAt: Date(),
            updatedAt: Date(),
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            collaboration: CollaborationMetadata(
                scope: .privateDatabase,
                ownership: .owner,
                permission: .editable
            )
        )
        workflows.insert(workflow, at: 0)
        persistWorkflows()
        return workflow
    }

    func updateWorkflow(_ workflow: DomainWorkflow, name: String, domains: [String], notes: String?) {
        guard canEdit(workflow) else { return }
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        let normalizedDomains = normalizedDomains(domains)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !normalizedDomains.isEmpty else { return }

        workflows[index].name = trimmedName
        workflows[index].domains = normalizedDomains
        workflows[index].notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        workflows[index].updatedAt = Date()
        persistWorkflows()
    }

    func deleteWorkflow(_ workflow: DomainWorkflow) {
        guard canDelete(workflow) else { return }
        CloudSyncService.shared.recordWorkflowDeletion(workflow)
        workflows.removeAll { $0.id == workflow.id }
        if latestWorkflowRunSummary?.workflowID == workflow.id {
            latestWorkflowRunSummary = nil
        }
        if activeWorkflowRunID == workflow.id {
            activeWorkflowRunID = nil
            activeWorkflowRunName = nil
        }
        persistWorkflows()
    }

    func addDomains(_ domains: [String], to workflow: DomainWorkflow) {
        guard canEdit(workflow) else { return }
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        let mergedDomains = normalizedDomains(workflows[index].domains + domains)
        guard mergedDomains != workflows[index].domains else { return }
        workflows[index].domains = mergedDomains
        workflows[index].updatedAt = Date()
        persistWorkflows()
    }

    func removeWorkflowDomains(at offsets: IndexSet, from workflow: DomainWorkflow) {
        guard canEdit(workflow) else { return }
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[index].domains.remove(atOffsets: offsets)
        workflows[index].updatedAt = Date()
        persistWorkflows()
    }

    func moveWorkflowDomains(from offsets: IndexSet, to destination: Int, in workflow: DomainWorkflow) {
        guard canEdit(workflow) else { return }
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[index].domains.move(fromOffsets: offsets, toOffset: destination)
        workflows[index].updatedAt = Date()
        persistWorkflows()
    }

    func runWorkflow(_ workflow: DomainWorkflow) {
        guard !workflow.domains.isEmpty else { return }
        guard FeatureAccessService.canRunBatch(domainCount: workflow.domains.count) else {
            upgradePrompt = FeatureAccessService.upgradePromptForBatch(domainCount: workflow.domains.count)
            return
        }
        startBatchLookup(domains: workflow.domains, source: .workflow, workflow: workflow)
    }

    func rerunCurrentDomain(in workflow: DomainWorkflow) {
        guard workflow.domains.contains(where: { $0.caseInsensitiveCompare(searchedDomain) == .orderedSame }) else {
            return
        }
        runWorkflow(workflow)
    }

    func refreshWorkflowList() async {
        workflows = Self.loadWorkflows(defaults: defaults)
        await Task.yield()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

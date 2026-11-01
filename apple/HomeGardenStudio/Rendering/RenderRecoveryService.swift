import Foundation
import Observation

@Observable @MainActor final class RenderRecoveryService {
    private(set) var entries: [RenderRecoveryEntry] = []
    private(set) var isBusy = false
    @ObservationIgnored private let gateway: any RenderGatewayTransport
    @ObservationIgnored private let storage: any RenderRecoveryStorage
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let makeID: @Sendable () -> UUID

    convenience init(account: AccountService, storage: any RenderRecoveryStorage) {
        self.init(transport: AccountRenderGateway(account: account), storage: storage)
    }
    init(transport: any RenderGatewayTransport, storage: any RenderRecoveryStorage,
         now: @escaping @Sendable () -> Date = { Date() }, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        gateway = transport; self.storage = storage; self.now = now; self.makeID = makeID
    }

    /// Local only. Relaunch never sends a paid generation automatically.
    func reload() async throws {
        let identity = try currentIdentity()
        let stored = try await storage.entries()
        try requireIdentity(identity)
        entries = stored.filter { $0.account == identity }
    }

    func fetchModels() async throws -> RenderModelCatalog {
        try begin(); defer { isBusy = false }
        let identity = try currentIdentity()
        let catalog = try await gateway.models()
        try requireIdentity(identity)
        guard catalog.providers.count <= 3, Set(catalog.providers.map(\.provider)).count == catalog.providers.count,
              catalog.providers.allSatisfy({ provider in provider.models.count <= 100 && provider.models.allSatisfy {
                  !$0.id.isEmpty && $0.id.utf8.count <= 80 && $0.sizes.count <= 10 && $0.qualities.count <= 10 &&
                  ($0.priceMicros?.count ?? 0) <= 100 && ($0.priceMicros?.values.allSatisfy { (1...500_000_000).contains($0) } ?? true)
              } }) else { throw RenderRecoveryError.invalidResponse }
        return catalog
    }

    func quote(input: RenderInput, projectID: UUID, photoUploadConsent: Bool) async throws -> RenderQuoteDraft {
        guard photoUploadConsent else { throw RenderRecoveryError.consentRequired }
        try begin(); defer { isBusy = false }
        let identity = try currentIdentity()
        try input.validate()
        let request = FrozenRenderRequest(input)
        let result = try await gateway.quote(body: request.encoded())
        try requireIdentity(identity); try result.validate()
        guard result.provider == input.provider, result.model == input.model, result.size == input.size,
              result.quality == input.quality, result.expiry > now(), result.expiry.timeIntervalSince(now()) <= 15 * 60 else {
            throw RenderRecoveryError.invalidResponse
        }
        return RenderQuoteDraft(account: identity, projectID: projectID, quote: result, request: request)
    }

    /// Approval is for this exact frozen quote/payload, not for a later edited document snapshot.
    @discardableResult func submit(_ draft: RenderQuoteDraft, approved: Bool) async throws -> RenderRecoveryEntry {
        guard approved else { throw RenderRecoveryError.approvalRequired }
        try begin(); defer { isBusy = false }
        try requireIdentity(draft.account); try draft.quote.validate()
        guard draft.quote.expiry > now() else { throw RenderRecoveryError.quoteExpired }
        let prior = try await storage.entries().first { $0.account == draft.account && $0.quote.quoteId == draft.quote.quoteId }
        try requireIdentity(draft.account)
        if let prior {
            guard prior.projectID == draft.projectID, prior.quote == draft.quote,
                  RenderHash.hex(try draft.submission(id: prior.id)) == prior.requestSHA256 else { throw RenderRecoveryError.invalidInput }
            try await reload()
            return prior // The quote already owns one retry identity; never mint another.
        }
        let id = makeID(), request = try draft.submission(id: id), date = now()
        let entry = RenderRecoveryEntry(id: id, account: draft.account, projectID: draft.projectID, quote: draft.quote,
            requestSHA256: RenderHash.hex(request), requestByteCount: request.count, createdAt: date, updatedAt: date,
            revision: 0, state: .prepared, jobID: nil, result: nil, resultExpiresAt: nil, refunded: false, issue: nil)
        // No network submission until UUID + exact payload + account/project association are committed.
        try await storage.insert(entry, request: request)
        try requireIdentity(entry.account)
        return try await dispatch(entry, request: request)
    }

    /// Explicit recovery only. Unknown jobs use the persisted POST identity; known jobs use GET.
    @discardableResult func recover(id: UUID) async throws -> RenderRecoveryEntry {
        try begin(); defer { isBusy = false }
        let entry = try await storage.entry(id: id)
        try requireIdentity(entry.account)
        if entry.state == .failed || entry.state == .acknowledged {
            try await reload(); return entry
        }
        if let jobID = entry.jobID {
            do {
                let reply = try await gateway.job(id: jobID)
                try requireIdentity(entry.account)
                return try await accept(reply, entry: entry)
            } catch {
                try? await reload()
                throw error
            }
        }
        // Never obtain a fresh quote or generate a different key after an ambiguous outcome.
        let request = try await storage.request(id: id)
        try requireIdentity(entry.account)
        return try await dispatch(entry, request: request)
    }

    func savedResult(id: UUID, projectID: UUID) async throws -> SavedRenderResult? {
        let entry = try await storage.entry(id: id)
        try requireIdentity(entry.account)
        guard entry.projectID == projectID else { throw RenderRecoveryError.projectMismatch }
        let saved = try await storage.savedResult(id: id)
        try requireIdentity(entry.account)
        guard saved == nil || (saved?.account == entry.account && saved?.projectID == projectID) else {
            throw RenderRecoveryError.projectMismatch
        }
        return saved
    }

    func deleteRecovery(id: UUID, confirmed: Bool) async throws {
        guard confirmed else { throw RenderRecoveryError.confirmationRequired }
        try begin(); defer { isBusy = false }
        let entry = try await storage.entry(id: id)
        try requireIdentity(entry.account)
        guard !entry.state.isUnresolved else { throw RenderRecoveryError.unresolvedRecovery }
        try await storage.remove(id: id); try await reload()
    }

    /// Call only after AccountService.deleteAccount succeeded; it does not cancel Apple purchases.
    /// Allowed while a request is finishing: the durable tombstone fences that request's later writes.
    func deleteAccountRecovery(identity: RenderAccountIdentity, serverDeletionConfirmed: Bool) async throws {
        guard serverDeletionConfirmed else { throw RenderRecoveryError.confirmationRequired }
        try await storage.deleteAccount(identity)
        entries.removeAll { $0.account == identity }
    }

    private func dispatch(_ initial: RenderRecoveryEntry, request: Data) async throws -> RenderRecoveryEntry {
        try requireIdentity(initial.account)
        try FrozenRenderRequest.validatePersisted(request, entry: initial)
        var uncertain = initial
        uncertain.state = .uncertain; uncertain.issue = .requestUncertain; uncertain.updatedAt = now()
        // Mark uncertainty before sending. A crash anywhere after this write preserves the original retry identity.
        let entry = try await storage.update(uncertain)
        try requireIdentity(entry.account)
        do {
            let reply = try await gateway.submit(body: request)
            try requireIdentity(entry.account)
            return try await accept(reply, entry: entry)
        } catch {
            try? await reload()
            throw error
        }
    }

    private func accept(_ reply: RenderJobReply, entry initial: RenderRecoveryEntry) async throws -> RenderRecoveryEntry {
        try reply.validate(for: initial); try requireIdentity(initial.account)
        var entry = initial
        entry.jobID = reply.jobId; entry.resultExpiresAt = reply.resultExpiresAt
        entry.refunded = reply.refunded; entry.updatedAt = now()
        switch reply.status {
        case .pending:
            guard entry.result == nil else { throw RenderRecoveryError.invalidResponse }
            entry.state = .pending; entry.issue = nil
            entry = try await storage.update(entry)
        case .failed:
            entry.state = .failed; entry.issue = .providerFailed
            entry = try await storage.update(entry)
        case .succeeded:
            // Save the server ID before image decoding or disk operations can fail; retries then use GET only.
            if entry.jobID != initial.jobID || entry.resultExpiresAt != initial.resultExpiresAt {
                entry = try await storage.update(entry)
            }
            let saved: SavedRenderResult?
            do { saved = try await storage.savedResult(id: entry.id) }
            catch RenderRecoveryError.storageCorrupt { saved = nil }
            catch RenderRecoveryError.invalidImage { saved = nil }
            if saved == nil {
                guard let base64 = reply.imageBase64, let png = Data(base64Encoded: base64), !base64.isEmpty else {
                    entry.state = .unavailable; entry.issue = .resultUnavailable
                    entry = try await storage.update(entry)
                    try await reload(); return entry
                }
                let info = try RenderImageValidator.validate(png)
                entry.state = .saved; entry.result = info; entry.issue = .acknowledgementPending
                // Any interrupted PNG or receipt commit throws here, before acknowledge can run.
                entry = try await storage.saveResult(png, entry: entry)
            }
            try requireIdentity(entry.account)
            if reply.acknowledged {
                entry.state = .acknowledged; entry.issue = nil
                entry = try await storage.update(entry)
            } else if reply.resultExpired != true, let expiry = reply.resultExpiresAt, Date(timeIntervalSince1970: Double(expiry) / 1000) > now() {
                entry = try await acknowledgeSaved(entry)
            } else {
                entry.state = .saved; entry.issue = .acknowledgementPending
                entry = try await storage.update(entry)
            }
        }
        try await reload()
        return entry
    }

    private func acknowledgeSaved(_ initial: RenderRecoveryEntry) async throws -> RenderRecoveryEntry {
        var entry = initial
        // Verify the durable bytes again immediately before acknowledgement; an in-memory result is insufficient.
        guard let saved = try await storage.savedResult(id: entry.id), saved.jobID == entry.jobID,
              saved.image == entry.result else { throw RenderRecoveryError.storageFailure }
        try requireIdentity(entry.account)
        guard let jobID = entry.jobID else { throw RenderRecoveryError.invalidResponse }
        do {
            let result = try await gateway.acknowledge(id: jobID)
            try requireIdentity(entry.account)
            guard result.ok else { throw RenderRecoveryError.invalidResponse }
            entry.state = .acknowledged; entry.issue = nil; entry.updatedAt = now()
            return try await storage.update(entry)
        } catch {
            // Keep the verified local image. A later explicit recovery checks server state before acknowledging again.
            try requireIdentity(entry.account)
            entry.state = .saved; entry.issue = .acknowledgementPending; entry.updatedAt = now()
            if let updated = try? await storage.update(entry) { entry = updated }
            return entry
        }
    }

    private func begin() throws {
        guard !isBusy else { throw RenderRecoveryError.busy }
        isBusy = true
    }
    private func currentIdentity() throws -> RenderAccountIdentity {
        guard let identity = gateway.identity else { throw RenderRecoveryError.noAccount }
        try identity.validate(); return identity
    }
    private func requireIdentity(_ expected: RenderAccountIdentity) throws {
        guard try currentIdentity() == expected else { throw RenderRecoveryError.accountChanged }
    }
}

import Foundation
import Observation

/// A sheet lifetime belongs to one exact account and origin. Late work cannot cross that boundary.
@Observable @MainActor final class RenderPresentationScope {
    let identity: RenderAccountIdentity
    private var generation = UUID()
    private var active = true
    private var removed = Set<UUID>()
    init(identity: RenderAccountIdentity) { self.identity = identity }
    static func identity(for account: AccountService) -> RenderAccountIdentity? {
        guard account.state != .credentialConflict, account.state != .deletionPending,
              let id = account.accountID, let origin = account.gatewayOrigin else { return nil }
        return RenderAccountIdentity(accountId: id, origin: origin)
    }
    func ticket() -> UUID { generation }
    func accepts(_ ticket: UUID, current: RenderAccountIdentity?) -> Bool {
        active && ticket == generation && current == identity
    }
    func open() { active = true; generation = UUID() }
    func close() { active = false; generation = UUID() }
    func removeRecovery(_ id: UUID) { removed.insert(id); generation = UUID() }
    func removalFailed(_ id: UUID) { removed.remove(id) }
    func entries(_ entries: [RenderRecoveryEntry], current: RenderAccountIdentity?) -> [RenderRecoveryEntry] {
        guard active, current == identity else { return [] }
        return entries.filter { $0.account == identity && !removed.contains($0.id) }
    }
    func result(_ saved: SavedRenderResult?, entries: [RenderRecoveryEntry], current: RenderAccountIdentity?) -> SavedRenderResult? {
        guard let saved, saved.account == identity,
              self.entries(entries, current: current).contains(where: { $0.id == saved.recoveryID && $0.result != nil }) else { return nil }
        return saved
    }
}

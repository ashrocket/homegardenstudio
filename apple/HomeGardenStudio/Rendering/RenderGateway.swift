import Foundation

@MainActor protocol RenderGatewayTransport: AnyObject {
    var identity: RenderAccountIdentity? { get }
    func models() async throws -> RenderModelCatalog
    func quote(body: Data) async throws -> RenderQuote
    func submit(body: Data) async throws -> RenderJobReply
    func job(id: UUID) async throws -> RenderJobReply
    func acknowledge(id: UUID) async throws -> RenderAcknowledgement
}

/// The account service is the only layer that handles the bearer and the pinned gateway origin.
@MainActor final class AccountRenderGateway: RenderGatewayTransport {
    private let account: AccountService
    init(account: AccountService) { self.account = account }
    var identity: RenderAccountIdentity? {
        guard let id = account.accountID, let origin = account.gatewayOrigin else { return nil }
        return RenderAccountIdentity(accountId: id, origin: origin)
    }
    func models() async throws -> RenderModelCatalog {
        try await account.authenticatedRequest("GET", path: "/v1/render/models")
    }
    func quote(body: Data) async throws -> RenderQuote {
        try await account.authenticatedRequest("POST", path: "/v1/render/quotes", body: body)
    }
    func submit(body: Data) async throws -> RenderJobReply {
        try await account.authenticatedRequest("POST", path: "/v1/render/jobs", body: body, timeout: 90)
    }
    func job(id: UUID) async throws -> RenderJobReply {
        try await account.authenticatedRequest("GET", path: "/v1/render/jobs/" + id.uuidString.lowercased(), timeout: 90)
    }
    func acknowledge(id: UUID) async throws -> RenderAcknowledgement {
        try await account.authenticatedRequest("POST", path: "/v1/render/jobs/" + id.uuidString.lowercased() + "/ack", body: Data("{}".utf8))
    }
}

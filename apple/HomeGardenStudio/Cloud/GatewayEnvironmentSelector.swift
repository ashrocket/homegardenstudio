import Foundation
import StoreKit

@MainActor protocol AppEnvironmentClient {
    func verifiedEnvironment() async throws -> EntitlementEnvironment
}

@MainActor struct LiveAppEnvironmentClient: AppEnvironmentClient {
    func verifiedEnvironment() async throws -> EntitlementEnvironment {
        let result = try await AppTransaction.shared
        guard case .verified(let transaction) = result else { throw GatewayError.verificationFailed }
        switch transaction.environment {
        case .production: return .production
        case .sandbox: return .sandbox
        default: throw GatewayError.verificationFailed
        }
    }
}

nonisolated struct GatewaySelection: Sendable {
    let client: GatewayClient
    let environment: EntitlementEnvironment
}

@MainActor enum GatewayEnvironmentSelector {
    static func select(productionURL: URL?, sandboxURL: URL?,
                       environment: any AppEnvironmentClient = LiveAppEnvironmentClient(),
                       transport: any GatewayTransport = URLSessionGatewayTransport()) async throws -> GatewaySelection {
        let verified = try await environment.verifiedEnvironment()
        let url = verified == .production ? productionURL : sandboxURL
        let client = try GatewayClient(baseURL: url, transport: transport, expectedEnvironment: verified)
        // Shared origins would merge credentials across independent financial environments.
        if let productionURL, let sandboxURL,
           try GatewayClient(baseURL: productionURL).origin == GatewayClient(baseURL: sandboxURL).origin {
            throw GatewayError.invalidConfiguration
        }
        return GatewaySelection(client: client, environment: verified)
    }
}

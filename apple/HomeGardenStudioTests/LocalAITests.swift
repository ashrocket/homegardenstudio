import XCTest
@testable import HomeGardenStudio

nonisolated final class LocalAITests: XCTestCase {
    func testBudgetInputUsesExactDecimalMicros() {
        XCTAssertEqual(CreditDisplay.parseBudget("1.99"), 1_990_000)
        XCTAssertEqual(CreditDisplay.parseBudget("0.000001"), 1)
        XCTAssertNil(CreditDisplay.parseBudget("1oops"))
        XCTAssertNil(CreditDisplay.parseBudget("0.0000001"))
        XCTAssertNil(CreditDisplay.parseBudget("501"))
        XCTAssertNil(CreditDisplay.parseBudget("-1"))
    }
    func testLoopbackConfigurationRejectsRemoteAndCredentialURLs() {
        for endpoint in ["https://example.com/v1/chat/completions", "http://192.168.1.1/chat", "http://127.0.0.1.evil.test/chat", "http://user:secret@127.0.0.1/chat", "http://127.0.0.1/chat?key=secret", "http://127.0.0.1/"] {
            XCTAssertThrowsError(try LocalModelConfiguration(endpoint: endpoint, model: "local"))
        }
        XCTAssertNoThrow(try LocalModelConfiguration(endpoint: "http://127.0.0.1:11434/v1/chat/completions", model: "local"))
        XCTAssertThrowsError(try LocalModelConfiguration(endpoint: "http://localhost:1234/chat", model: ""))
    }
    func testPromptRetainsUncertaintyAndDoesNotApplyGeometry() throws {
        let prompt = try AssistantPrompt.make(task: .critique, brief: "Position estimated. Photo not registered.", question: "Review placement")
        XCTAssertTrue(prompt.contains("Position estimated")); XCTAssertTrue(prompt.contains("no geometry edits"))
        XCTAssertThrowsError(try AssistantPrompt.make(task: .describe, brief: String(repeating: "x", count: 12_001), question: ""))
    }
    func testLocalResponseUsesOnlyExplicitEndpoint() async throws {
        let config = try LocalModelConfiguration(endpoint: "http://127.0.0.1:1234/explicit-chat", model: "synthetic-local")
        let transport = LocalFixtureTransport(response: Data(#"{"choices":[{"message":{"content":"Estimated planting idea"}}]}"#.utf8))
        let result = try await LoopbackAssistant.respond(configuration: config, prompt: "Synthetic plan", transport: transport)
        XCTAssertEqual(result, "Estimated planting idea")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.url, config.endpoint)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
    }
    func testLocalResponseRejectsHTMLAndOversize() async throws {
        let config = try LocalModelConfiguration(endpoint: "http://localhost:1234/chat", model: "synthetic")
        for data in [Data("<html>not a chat response</html>".utf8), Data(repeating: 0, count: 256 * 1024 + 1)] {
            do { _ = try await LoopbackAssistant.respond(configuration: config, prompt: "Synthetic", transport: LocalFixtureTransport(response: data)); XCTFail("Must reject invalid response") }
            catch { XCTAssertTrue(error is LocalAIError) }
        }
    }
}
private actor LocalFixtureTransport: LocalModelTransport {
    let response: Data
    private(set) var lastRequest: URLRequest?
    init(response: Data) { self.response = response }
    func send(_ request: URLRequest) async throws -> Data { lastRequest = request; return response }
}

import XCTest
@testable import HomeGardenStudio

nonisolated final class RenderPresentationTests: XCTestCase {
    func testUSDDisplayPreservesEveryQuotedMicro() {
        let locale = Locale(identifier: "en_US")
        for (micros, expected) in [(0, "$0.00"), (1, "$0.000001"), (100, "$0.0001"), (4500, "$0.0045"), (11000, "$0.011"), (1000000, "$1.00"), (1990000, "$1.99"), (499999999, "$499.999999")] {
            XCTAssertEqual(CreditDisplay.usd(micros, locale: locale), expected)
        }
    }
    @MainActor func testVisibleRecoveryRequiresExactAccountOriginAndLiveEntry() {
        let fixture = makeFixture(), scope = RenderPresentationScope(identity: fixture.entry.account)
        let other = RenderAccountIdentity(accountId: UUID(), origin: fixture.entry.account.origin)
        let otherOrigin = RenderAccountIdentity(accountId: fixture.entry.account.accountId, origin: "https://other.example")
        XCTAssertEqual(scope.entries([fixture.entry], current: fixture.entry.account).count, 1)
        XCTAssertTrue(scope.entries([fixture.entry], current: other).isEmpty)
        XCTAssertTrue(scope.entries([fixture.entry], current: otherOrigin).isEmpty)
        XCTAssertNil(scope.result(fixture.saved, entries: [fixture.entry], current: other))
        XCTAssertNil(scope.result(fixture.saved, entries: [], current: fixture.entry.account))
        XCTAssertNotNil(scope.result(fixture.saved, entries: [fixture.entry], current: fixture.entry.account))
    }
    @MainActor func testAccountSwitchDiscardsSuspendedImageCompletion() async {
        let fixture = makeFixture(), scope = RenderPresentationScope(identity: fixture.entry.account)
        let suspension = PresentationSuspension(), ticket = scope.ticket()
        var current: RenderAccountIdentity? = fixture.entry.account
        let completion = Task { @MainActor () -> SavedRenderResult? in
            await suspension.wait()
            guard scope.accepts(ticket, current: current) else { return nil }
            return scope.result(fixture.saved, entries: [fixture.entry], current: current)
        }
        await suspension.untilWaiting()
        current = RenderAccountIdentity(accountId: UUID(), origin: fixture.entry.account.origin)
        scope.close()
        await suspension.release()
        let result = await completion.value
        XCTAssertNil(result)
        // Switching back to the same UUID creates a new lifetime, never reviving old completions.
        current = fixture.entry.account; scope.open()
        XCTAssertFalse(scope.accepts(ticket, current: current))
        XCTAssertTrue(scope.accepts(scope.ticket(), current: current))
    }
    @MainActor func testRemovalClearsCachedImageAndFencesSuspendedAttachment() async {
        let fixture = makeFixture(), scope = RenderPresentationScope(identity: fixture.entry.account)
        let suspension = PresentationSuspension(), ticket = scope.ticket()
        let completion = Task { @MainActor () -> SavedRenderResult? in
            await suspension.wait()
            guard scope.accepts(ticket, current: fixture.entry.account) else { return nil }
            return scope.result(fixture.saved, entries: [fixture.entry], current: fixture.entry.account)
        }
        await suspension.untilWaiting()
        scope.removeRecovery(fixture.entry.id)
        XCTAssertTrue(scope.entries([fixture.entry], current: fixture.entry.account).isEmpty)
        XCTAssertNil(scope.result(fixture.saved, entries: [fixture.entry], current: fixture.entry.account))
        await suspension.release()
        let result = await completion.value
        XCTAssertNil(result)
        // A failed disk deletion allows a deliberate fresh view, but not the suspended old action.
        scope.removalFailed(fixture.entry.id)
        XCTAssertNotNil(scope.result(fixture.saved, entries: [fixture.entry], current: fixture.entry.account))
        XCTAssertFalse(scope.accepts(ticket, current: fixture.entry.account))
    }
    private func makeFixture() -> (entry: RenderRecoveryEntry, saved: SavedRenderResult) {
        let account = RenderAccountIdentity(accountId: UUID(), origin: "https://gateway.example")
        let id = UUID(), project = UUID(), job = UUID(), now = Date(timeIntervalSince1970: 1)
        let digest = String(repeating: "0", count: 64)
        let image = RenderImageInfo(width: 1, height: 1, byteCount: 3, sha256: digest)
        let quote = RenderQuote(quoteId: UUID(), provider: .managed, model: "synthetic", size: "1024x1024", quality: "low", debitMicros: 100, funding: .balance, expiresAt: 1000, destinationHost: "provider.example", providerBilling: false, inputDigest: digest)
        let entry = RenderRecoveryEntry(id: id, account: account, projectID: project, quote: quote, requestSHA256: digest, requestByteCount: 3, createdAt: now, updatedAt: now, revision: 0, state: .acknowledged, jobID: job, result: image, resultExpiresAt: 1000, refunded: false, issue: nil)
        let saved = SavedRenderResult(recoveryID: id, account: account, projectID: project, jobID: job, fileURL: URL(fileURLWithPath: "/synthetic-fixture.png"), png: Data([1,2,3]), image: image, label: "Synthetic unit fixture")
        return (entry, saved)
    }
}

private actor PresentationSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil }
    }
    func untilWaiting() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import HomeGardenStudio

nonisolated final class RenderRecoveryTests: XCTestCase {
    @MainActor func testConsentPrecedesAnyQuoteBytesAndApprovalPrecedesOutbox() async throws {
        let f = try fixture(); defer { f.clean() }
        do { _ = try await f.service.quote(input: f.input, projectID: f.projectID, photoUploadConsent: false); XCTFail("Expected consent") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .consentRequired) }
        XCTAssertEqual(f.transport.quoteBodies.count, 0)
        let draft = try await f.draft()
        do { _ = try await f.service.submit(draft, approved: false); XCTFail("Expected approval") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .approvalRequired) }
        let entries = try await f.storage.entries()
        XCTAssertTrue(entries.isEmpty); XCTAssertTrue(f.transport.submittedBodies.isEmpty)
    }

    @MainActor func testFrozenPayloadAndUUIDAreDurableBeforeRequestAndImageBeforeAcknowledgement() async throws {
        let f = try fixture(); defer { f.clean() }
        let expectedID = f.fixedID
        f.transport.beforeSubmit = { body in
            let entries = try await f.storage.entries()
            XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].id, expectedID)
            XCTAssertEqual(entries[0].state, .uncertain)
            let stored = try await f.storage.request(id: expectedID)
            XCTAssertEqual(stored, body)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(fields["idempotency_key"] as? String, expectedID.uuidString.lowercased())
            XCTAssertEqual(fields["quote_id"] as? String, f.transport.quoteID.uuidString.lowercased())
            XCTAssertEqual(fields["layout_image_png_base64"] as? String, f.png.base64EncodedString())
            XCTAssertEqual(fields["photo_upload_consent"] as? Bool, true)
            XCTAssertEqual(fields["prompt"] as? String, f.input.prompt)
        }
        f.transport.beforeAck = {
            let entry = try await f.storage.entry(id: expectedID)
            let saved = try await f.storage.savedResult(id: expectedID)
            XCTAssertEqual(entry.state, .saved)
            XCTAssertEqual(saved?.png, f.png)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved?.fileURL)), f.png)
        }
        let entry = try await f.service.submit(f.draft(), approved: true)
        XCTAssertEqual(entry.state, .acknowledged); XCTAssertEqual(f.transport.ackCount, 1)
        let saved = try await f.service.savedResult(id: entry.id, projectID: f.projectID)
        XCTAssertEqual(saved?.image.width, 2); XCTAssertEqual(saved?.image.height, 2)
        XCTAssertEqual(saved?.label, RenderLimits.aiLabel)
    }

    @MainActor func testResponseLossAndRelaunchPreserveExactReplayIdentity() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.submitError = .offline
        do { _ = try await f.service.submit(f.draft(), approved: true); XCTFail("Expected transport loss") }
        catch { XCTAssertTrue(error is RenderTestFailure) }
        let original = try XCTUnwrap(f.transport.submittedBodies.first)
        let persisted = try await f.storage.entry(id: f.fixedID)
        XCTAssertEqual(persisted.state, .uncertain); XCTAssertNil(persisted.jobID)
        let reopened = try FileRenderRecoveryStorage(rootURL: f.root)
        let transport = RenderTestGateway(identity: f.identity, png: f.png)
        transport.quoteID = f.transport.quoteID; transport.jobID = f.transport.jobID
        let service = RenderRecoveryService(transport: transport, storage: reopened, now: { RenderTestGateway.date })
        try await service.reload()
        XCTAssertTrue(transport.submittedBodies.isEmpty); XCTAssertEqual(transport.getCount, 0)
        let recovered = try await service.recover(id: f.fixedID)
        XCTAssertEqual(recovered.id, f.fixedID); XCTAssertEqual(recovered.state, .acknowledged)
        XCTAssertEqual(transport.submittedBodies, [original]); XCTAssertEqual(transport.ackCount, 1)
    }

    @MainActor func testRepeatedApprovalOfSameQuoteKeepsOneIdentityAndOneSubmission() async throws {
        let f = try fixture(); defer { f.clean() }
        let draft = try await f.draft()
        let first = try await f.service.submit(draft, approved: true)
        let otherWindow = RenderRecoveryService(transport: f.transport, storage: f.storage, now: { RenderTestGateway.date })
        let again = try await otherWindow.submit(draft, approved: true)
        XCTAssertEqual(first.id, again.id); XCTAssertEqual(f.transport.submittedBodies.count, 1)
        let entries = try await f.storage.entries(); XCTAssertEqual(entries.count, 1)
    }

    @MainActor func testKnownPendingJobUsesGETAndNeverAnotherSubmission() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.status = .pending
        let entry = try await f.service.submit(f.draft(), approved: true)
        XCTAssertEqual(entry.state, .pending); XCTAssertEqual(entry.jobID, f.transport.jobID)
        XCTAssertEqual(f.transport.ackCount, 0)
        f.transport.status = .succeeded
        let recovered = try await f.service.recover(id: entry.id)
        XCTAssertEqual(recovered.state, .acknowledged)
        XCTAssertEqual(f.transport.submittedBodies.count, 1); XCTAssertEqual(f.transport.getCount, 1)
    }

    @MainActor func testInterruptedResultBeforeRenameNeverAcknowledges() async throws {
        try await exerciseInterruptedSave(.resultBeforeRename)
    }
    @MainActor func testInterruptedReceiptAfterImageSyncNeverAcknowledges() async throws {
        try await exerciseInterruptedSave(.resultAfterSync)
    }
    @MainActor private func exerciseInterruptedSave(_ interruption: RenderStorageWriteStage) async throws {
        let f = try fixture(fault: { if $0 == interruption { throw RenderTestFailure.interrupted } }); defer { f.clean() }
        do { _ = try await f.service.submit(f.draft(), approved: true); XCTFail("Expected interrupted disk write") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .storageFailure) }
        XCTAssertEqual(f.transport.ackCount, 0)
        let record = try await f.storage.entry(id: f.fixedID)
        XCTAssertEqual(record.id, f.fixedID); XCTAssertEqual(record.jobID, f.transport.jobID)
        XCTAssertNil(record.result)
        let reopened = try FileRenderRecoveryStorage(rootURL: f.root)
        let recovery = RenderRecoveryService(transport: f.transport, storage: reopened, now: { RenderTestGateway.date })
        let finished = try await recovery.recover(id: f.fixedID)
        XCTAssertEqual(finished.state, .acknowledged)
        XCTAssertEqual(f.transport.submittedBodies.count, 1); XCTAssertEqual(f.transport.getCount, 1); XCTAssertEqual(f.transport.ackCount, 1)
    }

    @MainActor func testInterruptedInitialJournalNeverSendsJob() async throws {
        let f = try fixture(fault: { if $0 == .recordBeforeCommit { throw RenderTestFailure.interrupted } }); defer { f.clean() }
        do { _ = try await f.service.submit(f.draft(), approved: true); XCTFail("Expected interrupted outbox") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .storageFailure) }
        let entries = try await f.storage.entries()
        XCTAssertTrue(entries.isEmpty); XCTAssertTrue(f.transport.submittedBodies.isEmpty); XCTAssertEqual(f.transport.ackCount, 0)
    }

    @MainActor func testAckFailurePreservesImageAndOnlyRetriesAckAfterGET() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.ackError = .offline
        let entry = try await f.service.submit(f.draft(), approved: true)
        XCTAssertEqual(entry.state, .saved); XCTAssertEqual(entry.issue, .acknowledgementPending)
        let saved = try await f.service.savedResult(id: entry.id, projectID: f.projectID)
        XCTAssertEqual(saved?.png, f.png)
        f.transport.ackError = nil
        let recovered = try await f.service.recover(id: entry.id)
        XCTAssertEqual(recovered.state, .acknowledged)
        XCTAssertEqual(f.transport.submittedBodies.count, 1); XCTAssertEqual(f.transport.getCount, 1); XCTAssertEqual(f.transport.ackCount, 2)
    }

    @MainActor func testLostAckCanRecoverServerAcknowledgementAfterRetentionExpires() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.ackError = .offline
        let entry = try await f.service.submit(f.draft(), approved: true)
        f.transport.serverAcknowledged = true; f.transport.omitImage = true; f.transport.resultExpired = true
        let recovered = try await f.service.recover(id: entry.id)
        XCTAssertEqual(recovered.state, .acknowledged)
        XCTAssertEqual(f.transport.ackCount, 1); XCTAssertEqual(f.transport.submittedBodies.count, 1)
        let saved = try await f.service.savedResult(id: entry.id, projectID: f.projectID)
        XCTAssertEqual(saved?.png, f.png)
    }

    @MainActor func testInvalidPNGAndMismatchedPaidReplyNeverAcknowledge() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.png = Data([1, 2, 3])
        do { _ = try await f.service.submit(f.draft(), approved: true); XCTFail("Expected invalid image") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .invalidImage) }
        XCTAssertEqual(f.transport.ackCount, 0)
        let persisted = try await f.storage.entry(id: f.fixedID)
        XCTAssertEqual(persisted.jobID, f.transport.jobID)
        f.transport.png = f.png; f.transport.debit = 101
        do { _ = try await f.service.recover(id: f.fixedID); XCTFail("Expected changed debit rejection") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .invalidResponse) }
        XCTAssertEqual(f.transport.ackCount, 0); XCTAssertEqual(f.transport.submittedBodies.count, 1)
    }

    @MainActor func testMissingRetainedResultDoesNotGenerateAgain() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.omitImage = true
        let entry = try await f.service.submit(f.draft(), approved: true)
        XCTAssertEqual(entry.state, .unavailable); XCTAssertEqual(f.transport.ackCount, 0)
        _ = try await f.service.recover(id: entry.id)
        XCTAssertEqual(f.transport.submittedBodies.count, 1); XCTAssertEqual(f.transport.getCount, 1)
    }

    @MainActor func testAccountOriginAndProjectIsolation() async throws {
        let f = try fixture(); defer { f.clean() }
        let entry = try await f.service.submit(f.draft(), approved: true)
        do { _ = try await f.service.savedResult(id: entry.id, projectID: UUID()); XCTFail("Expected project mismatch") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .projectMismatch) }
        f.transport.identity = RenderAccountIdentity(accountId: UUID(), origin: f.identity.origin)
        do { _ = try await f.service.recover(id: entry.id); XCTFail("Expected account mismatch") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .accountChanged) }
        try await f.service.reload(); XCTAssertTrue(f.service.entries.isEmpty)
        f.transport.identity = RenderAccountIdentity(accountId: f.identity.accountId, origin: "https://other.example")
        do { _ = try await f.service.savedResult(id: entry.id, projectID: f.projectID); XCTFail("Expected origin mismatch") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .accountChanged) }
        XCTAssertEqual(f.transport.submittedBodies.count, 1)
    }

    @MainActor func testDeletionRequiresConfirmationAndTombstonePreventsResurrection() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.status = .pending
        let pending = try await f.service.submit(f.draft(), approved: true)
        let request = try await f.storage.request(id: pending.id)
        do { try await f.service.deleteAccountRecovery(identity: f.identity, serverDeletionConfirmed: false); XCTFail("Expected confirmation") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .confirmationRequired) }
        do { try await f.service.deleteRecovery(id: pending.id, confirmed: true); XCTFail("Expected unresolved recovery guard") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .unresolvedRecovery) }
        let otherIdentity = RenderAccountIdentity(accountId: UUID(), origin: f.identity.origin)
        let other = RenderTestGateway(identity: otherIdentity, png: f.png)
        let otherService = RenderRecoveryService(transport: other, storage: f.storage, now: { RenderTestGateway.date })
        let otherQuote = try await otherService.quote(input: f.input, projectID: UUID(), photoUploadConsent: true)
        let otherEntry = try await otherService.submit(otherQuote, approved: true)
        f.transport.identity = nil
        try await f.service.deleteAccountRecovery(identity: f.identity, serverDeletionConfirmed: true)
        let remaining = try await f.storage.entries()
        XCTAssertEqual(remaining.map(\.id), [otherEntry.id])
        do { try await f.storage.insert(pending, request: request); XCTFail("Expected deleted-account fence") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .accountDeleted) }
    }

    @MainActor func testStorageQuotaRejectsBeforePaidSubmission() async throws {
        let f = try fixture(limits: RenderStorageLimits(maximumEntries: 1)); defer { f.clean() }
        f.transport.status = .pending
        _ = try await f.service.submit(f.draft(), approved: true)
        let second = RenderRecoveryService(transport: f.transport, storage: f.storage, now: { RenderTestGateway.date })
        f.transport.quoteID = UUID()
        let draft = try await second.quote(input: f.input, projectID: f.projectID, photoUploadConsent: true)
        do { _ = try await second.submit(draft, approved: true); XCTFail("Expected full journal") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .storageFull) }
        XCTAssertEqual(f.transport.submittedBodies.count, 1)
    }

    @MainActor func testCorruptRequestIsPreservedWithoutResubmission() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.submitError = .offline
        do { _ = try await f.service.submit(f.draft(), approved: true) } catch { }
        let path = f.root.appendingPathComponent(f.fixedID.uuidString.lowercased()).appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: path)
        f.transport.submitError = nil
        do { _ = try await f.service.recover(id: f.fixedID); XCTFail("Expected corrupted request refusal") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .storageCorrupt) }
        XCTAssertEqual(f.transport.submittedBodies.count, 1); XCTAssertEqual(f.transport.ackCount, 0)
        let entries = try await f.storage.entries(); XCTAssertEqual(entries.count, 1)
    }

    @MainActor func testStaleJournalUpdateCannotDiscardSavedResult() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.status = .pending
        let old = try await f.service.submit(f.draft(), approved: true)
        f.transport.status = .succeeded
        let latest = try await f.service.recover(id: old.id)
        XCTAssertEqual(latest.state, .acknowledged)
        do { _ = try await f.storage.update(old); XCTFail("Expected stale write rejection") }
        catch { XCTAssertEqual(error as? RenderRecoveryError, .storageConflict) }
        let saved = try await f.storage.savedResult(id: old.id)
        XCTAssertEqual(saved?.png, f.png)
    }

    @MainActor func testFailedRefundedJobNeverRegeneratesDuringRecovery() async throws {
        let f = try fixture(); defer { f.clean() }
        f.transport.status = .failed
        let failed = try await f.service.submit(f.draft(), approved: true)
        XCTAssertEqual(failed.state, .failed); XCTAssertTrue(failed.refunded)
        _ = try await f.service.recover(id: failed.id)
        XCTAssertEqual(f.transport.submittedBodies.count, 1); XCTAssertEqual(f.transport.getCount, 0); XCTAssertEqual(f.transport.ackCount, 0)
        try await f.service.deleteRecovery(id: failed.id, confirmed: true)
        let entries = try await f.storage.entries(); XCTAssertTrue(entries.isEmpty)
    }

    @MainActor func testPNGByteDimensionSignatureAndTruncationBounds() throws {
        let png = try Self.png()
        XCTAssertNoThrow(try RenderImageValidator.validate(png))
        XCTAssertThrowsError(try RenderImageValidator.validate(Data(png.prefix(8))))
        XCTAssertThrowsError(try RenderImageValidator.validate(Data(repeating: 0, count: RenderLimits.imageBytes + 1)))
        var huge = png; huge.replaceSubrange(16..<20, with: [0x7f, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try RenderImageValidator.validate(huge))
        var bad = png; bad[0] = 0
        XCTAssertThrowsError(try RenderImageValidator.validate(bad))
        XCTAssertThrowsError(try RenderImageValidator.validate(png, media: .jpeg))
    }

    @MainActor func testSnakeCaseJobDecodingMatchesGateway() throws {
        let id = UUID(), data = try JSONSerialization.data(withJSONObject: [
            "job_id": id.uuidString.lowercased(), "status": "pending", "debit_micros": 100,
            "funding": "balance", "refunded": false, "provider_billing": false, "provider": "managed",
            "model": "gpt-image-2", "label": RenderLimits.aiLabel, "acknowledged": false,
        ])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(RenderJobReply.self, from: data)
        XCTAssertEqual(result.jobId, id); XCTAssertEqual(result.debitMicros, 100)
    }

    @MainActor private func fixture(limits: RenderStorageLimits = RenderStorageLimits(),
                                   fault: @escaping @Sendable (RenderStorageWriteStage) throws -> Void = { _ in }) throws -> RenderFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hgs-render-test-" + UUID().uuidString, isDirectory: true)
        let identity = RenderAccountIdentity(accountId: UUID(), origin: "https://gateway.example")
        let png = try Self.png(), fixedID = UUID()
        let storage = try FileRenderRecoveryStorage(rootURL: root, limits: limits, fault: fault)
        let transport = RenderTestGateway(identity: identity, png: png)
        let service = RenderRecoveryService(transport: transport, storage: storage, now: { RenderTestGateway.date }, makeID: { fixedID })
        let input = RenderInput(provider: .managed, model: "gpt-image-2", size: "1024x1024", quality: "low", prompt: "Synthetic layout fixture", layoutPNG: png)
        return RenderFixture(root: root, identity: identity, png: png, fixedID: fixedID, projectID: UUID(),
                             storage: storage, transport: transport, service: service, input: input)
    }
    nonisolated private static func png() throws -> Data {
        let pixels = Data([0, 128, 0, 255, 0, 128, 0, 255, 0, 128, 0, 255, 0, 128, 0, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderTestFailure.interrupted }
        return output as Data
    }
}

private nonisolated enum RenderTestFailure: Error { case offline, interrupted }
@MainActor private struct RenderFixture {
    let root: URL
    let identity: RenderAccountIdentity
    let png: Data
    let fixedID: UUID
    let projectID: UUID
    let storage: FileRenderRecoveryStorage
    let transport: RenderTestGateway
    let service: RenderRecoveryService
    let input: RenderInput
    func draft() async throws -> RenderQuoteDraft { try await service.quote(input: input, projectID: projectID, photoUploadConsent: true) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private final class RenderTestGateway: RenderGatewayTransport {
    nonisolated static let date = Date(timeIntervalSince1970: 1_793_534_400)
    var identity: RenderAccountIdentity?
    var png: Data
    var quoteID = UUID()
    var jobID = UUID()
    var status = RenderJobStatus.succeeded
    var submitError: RenderTestFailure?
    var ackError: RenderTestFailure?
    var debit = 100
    var serverAcknowledged = false
    var omitImage = false
    var resultExpired = false
    var quoteBodies: [Data] = []
    var submittedBodies: [Data] = []
    var getCount = 0
    var ackCount = 0
    var beforeSubmit: ((Data) async throws -> Void)?
    var beforeAck: (() async throws -> Void)?
    init(identity: RenderAccountIdentity, png: Data) { self.identity = identity; self.png = png }
    func models() async throws -> RenderModelCatalog { RenderModelCatalog(providers: []) }
    func quote(body: Data) async throws -> RenderQuote {
        quoteBodies.append(body)
        return RenderQuote(quoteId: quoteID, provider: .managed, model: "gpt-image-2", size: "1024x1024", quality: "low",
            debitMicros: 100, funding: .balance, expiresAt: Int64(Self.date.addingTimeInterval(600).timeIntervalSince1970 * 1000),
            destinationHost: "api.openai.com", providerBilling: false, inputDigest: String(repeating: "a", count: 64))
    }
    func submit(body: Data) async throws -> RenderJobReply {
        submittedBodies.append(body); try await beforeSubmit?(body)
        if let submitError { throw submitError }
        return reply()
    }
    func job(id: UUID) async throws -> RenderJobReply { getCount += 1; XCTAssertEqual(id, jobID); return reply() }
    func acknowledge(id: UUID) async throws -> RenderAcknowledgement {
        ackCount += 1; XCTAssertEqual(id, jobID); try await beforeAck?()
        if let ackError { throw ackError }
        return RenderAcknowledgement(ok: true)
    }
    private func reply() -> RenderJobReply {
        RenderJobReply(jobId: jobID, status: status, errorCode: status == .failed ? "PROVIDER_FAILED_OR_UNCERTAIN" : nil,
            imageBase64: status == .succeeded && !omitImage ? png.base64EncodedString() : nil, mediaType: status == .succeeded ? "image/png" : nil,
            debitMicros: debit, funding: .balance, refunded: status == .failed, providerBilling: false, provider: .managed,
            model: "gpt-image-2", label: RenderLimits.aiLabel,
            resultExpiresAt: status == .succeeded ? Int64(Self.date.addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000) : nil,
            resultExpired: resultExpired, acknowledged: serverAcknowledged)
    }
}

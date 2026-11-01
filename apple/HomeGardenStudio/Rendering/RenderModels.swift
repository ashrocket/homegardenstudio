import Foundation
import CryptoKit
import ImageIO

nonisolated enum RenderRecoveryError: Error, LocalizedError, Equatable {
    case consentRequired, approvalRequired, noAccount, accountChanged, projectMismatch, busy
    case invalidInput, invalidResponse, invalidImage, quoteExpired, storageFull, storageCorrupt
    case storageFailure, storageConflict, resultUnavailable, accountDeleted, confirmationRequired, unresolvedRecovery

    var errorDescription: String? {
        switch self {
        case .consentRequired: "Approve uploading the layout and any source photo before requesting a cloud quote."
        case .approvalRequired: "Approve this quote's provider, destination and debit before submitting."
        case .noAccount: "Load or deliberately create a cloud account first."
        case .accountChanged: "This recovery belongs to a different cloud account or gateway."
        case .projectMismatch: "This image belongs to another project. Open its original project to attach it."
        case .busy: "Another render recovery operation is in progress."
        case .invalidInput: "The render request is invalid or exceeds the supported size."
        case .invalidResponse: "The service returned an inconsistent render response. No acknowledgement was sent."
        case .invalidImage: "The image is not a complete supported PNG or JPEG, or exceeds the image limits."
        case .quoteExpired: "This quote has expired. Review a new quote before submitting a new request."
        case .storageFull: "Render recovery storage is full. Export or remove completed recovery items before submitting."
        case .storageCorrupt: "The saved render recovery could not be verified. It has been preserved."
        case .storageFailure: "The render could not be saved safely. Recovery remains available; no new paid request was created."
        case .storageConflict: "This recovery changed in another window. Reload it before continuing."
        case .resultUnavailable: "No recoverable image is available. Check the recorded job or refund status."
        case .accountDeleted: "Recovery for this deleted account cannot be recreated."
        case .confirmationRequired: "Confirm removal of the local recovery copy."
        case .unresolvedRecovery: "Recover this unfinished job before removing its retry record."
        }
    }
}

nonisolated enum CloudRenderProvider: String, Codable, CaseIterable, Sendable { case managed, openai, custom }
nonisolated enum RenderFunding: String, Codable, Sendable { case balance, sponsorWindow = "sponsor_window", provider }
nonisolated enum RenderImageMedia: String, Codable, Sendable { case png = "image/png", jpeg = "image/jpeg" }
nonisolated enum RenderJobStatus: String, Codable, Sendable { case pending, succeeded, failed }
nonisolated enum RenderRecoveryState: String, Codable, Sendable {
    case prepared, uncertain, pending, saved, acknowledged, failed, unavailable
    var isUnresolved: Bool { self == .prepared || self == .uncertain || self == .pending }
}
nonisolated enum RenderRecoveryIssue: String, Codable, Sendable {
    case requestUncertain, storageNeedsAttention, acknowledgementPending, providerFailed, resultUnavailable
}

nonisolated struct RenderAccountIdentity: Codable, Equatable, Hashable, Sendable {
    let accountId: UUID
    let origin: String
    func validate() throws {
        guard let c = URLComponents(string: origin), c.scheme == "https", let host = c.host,
              !host.isEmpty, host == host.lowercased(), c.path.isEmpty, c.port == nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              origin == "https://" + host else { throw RenderRecoveryError.accountChanged }
    }
    var storageKey: String { RenderHash.hex(Data(origin.utf8)) + "-" + accountId.uuidString.lowercased() }
}

nonisolated enum RenderLimits {
    static let requestBytes = 12 * 1024 * 1024
    static let imageBytes = 6 * 1024 * 1024
    static let imageBase64Bytes = 8 * 1024 * 1024
    static let maximumDimension = 4096
    static let maximumPixels = 8_388_608
    static let aiLabel = "AI concept: cloud rendering, not a measured plan"
}
nonisolated enum RenderHash {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

nonisolated struct RenderImageInfo: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let byteCount: Int
    let sha256: String
}
nonisolated enum RenderImageValidator {
    static func validate(_ data: Data, media: RenderImageMedia = .png) throws -> RenderImageInfo {
        guard !data.isEmpty, data.count <= RenderLimits.imageBytes else { throw RenderRecoveryError.invalidImage }
        switch media {
        case .png:
            let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
            guard data.count >= 33, Array(data.prefix(8)) == signature,
                  Array(data.dropFirst(8).prefix(8)) == [0, 0, 0, 13, 73, 72, 68, 82] else { throw RenderRecoveryError.invalidImage }
            let width = bigEndian(data, offset: 16), height = bigEndian(data, offset: 20)
            try checkDimensions(width, height)
        case .jpeg:
            guard data.count >= 4, Array(data.prefix(3)) == [255, 216, 255] else { throw RenderRecoveryError.invalidImage }
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == (media == .png ? "public.png" : "public.jpeg"),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw RenderRecoveryError.invalidImage }
        try checkDimensions(width, height)
        // Decode one bounded image before declaring a returned paid image safely usable.
        let decoding = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, decoding), image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw RenderRecoveryError.invalidImage }
        return RenderImageInfo(width: width, height: height, byteCount: data.count, sha256: RenderHash.hex(data))
    }
    private static func checkDimensions(_ width: Int, _ height: Int) throws {
        guard (1...RenderLimits.maximumDimension).contains(width), (1...RenderLimits.maximumDimension).contains(height),
              width <= RenderLimits.maximumPixels / height else { throw RenderRecoveryError.invalidImage }
    }
    private static func bigEndian(_ data: Data, offset: Int) -> Int {
        data.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
}

nonisolated struct RenderInput: Sendable {
    let provider: CloudRenderProvider
    let model: String
    let size: String
    let quality: String
    let prompt: String
    let layoutPNG: Data
    let sourceImage: Data?
    let sourceMediaType: RenderImageMedia?

    init(provider: CloudRenderProvider, model: String, size: String, quality: String, prompt: String,
         layoutPNG: Data, sourceImage: Data? = nil, sourceMediaType: RenderImageMedia? = nil) {
        self.provider = provider; self.model = model; self.size = size; self.quality = quality; self.prompt = prompt
        self.layoutPNG = layoutPNG; self.sourceImage = sourceImage; self.sourceMediaType = sourceMediaType
    }
    func validate() throws {
        guard !model.isEmpty, model.utf8.count <= 80,
              ["1024x1024", "1536x1024", "1024x1536"].contains(size), ["low", "medium", "high"].contains(quality),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= 8000,
              (sourceImage == nil) == (sourceMediaType == nil) else { throw RenderRecoveryError.invalidInput }
        _ = try RenderImageValidator.validate(layoutPNG)
        if let sourceImage, let sourceMediaType { _ = try RenderImageValidator.validate(sourceImage, media: sourceMediaType) }
    }
}

nonisolated struct RenderModelCatalog: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        let provider: CloudRenderProvider
        let models: [Model]
    }
    struct Model: Decodable, Sendable, Identifiable {
        let id: String
        let sizes: [String]
        let qualities: [String]
        let priceMicros: [String: Int]?
    }
    let providers: [Provider]
}
nonisolated struct RenderQuote: Codable, Equatable, Sendable {
    let quoteId: UUID
    let provider: CloudRenderProvider
    let model: String
    let size: String
    let quality: String
    let debitMicros: Int
    let funding: RenderFunding
    let expiresAt: Int64
    let destinationHost: String
    let providerBilling: Bool
    let inputDigest: String
    var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }

    func validate() throws {
        guard !model.isEmpty, model.utf8.count <= 80, ["1024x1024", "1536x1024", "1024x1536"].contains(size),
              ["low", "medium", "high"].contains(quality), (0...500_000_000).contains(debitMicros),
              expiresAt > 0, destinationHost.utf8.count <= 253, !destinationHost.isEmpty,
              destinationHost.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              inputDigest.count == 64, inputDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              provider == .managed ? debitMicros > 0 && funding != .provider && !providerBilling : debitMicros == 0 && funding == .provider && providerBilling,
              provider == .custom || destinationHost == "api.openai.com" else { throw RenderRecoveryError.invalidResponse }
    }
}

/// Immutable payload and quote approved together. No bearer, provider key, or mutable document reference.
nonisolated struct RenderQuoteDraft: Sendable {
    let account: RenderAccountIdentity
    let projectID: UUID
    let quote: RenderQuote
    fileprivate let request: FrozenRenderRequest
    init(account: RenderAccountIdentity, projectID: UUID, quote: RenderQuote, request: FrozenRenderRequest) {
        self.account = account; self.projectID = projectID; self.quote = quote; self.request = request
    }
    func submission(id: UUID) throws -> Data { try request.submission(quoteID: quote.quoteId, id: id).encoded() }
}

nonisolated struct FrozenRenderRequest: Codable, Sendable {
    let provider: CloudRenderProvider
    let model: String
    let size: String
    let quality: String
    let photoUploadConsent: Bool
    let prompt: String
    let layoutImagePngBase64: String
    let sourceImageBase64: String?
    let sourceMediaType: RenderImageMedia?
    var quoteId: String?
    var idempotencyKey: String?

    init(_ input: RenderInput) {
        provider = input.provider; model = input.model; size = input.size; quality = input.quality
        photoUploadConsent = true; prompt = input.prompt; layoutImagePngBase64 = input.layoutPNG.base64EncodedString()
        sourceImageBase64 = input.sourceImage?.base64EncodedString(); sourceMediaType = input.sourceMediaType
    }
    func submission(quoteID: UUID, id: UUID) -> Self {
        var copy = self
        copy.quoteId = quoteID.uuidString.lowercased(); copy.idempotencyKey = id.uuidString.lowercased()
        return copy
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= RenderLimits.requestBytes else { throw RenderRecoveryError.invalidInput }
        return data
    }
    static func validatePersisted(_ data: Data, entry: RenderRecoveryEntry) throws {
        guard data.count == entry.requestByteCount, data.count <= RenderLimits.requestBytes,
              RenderHash.hex(data) == entry.requestSHA256 else { throw RenderRecoveryError.storageCorrupt }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let request = try decoder.decode(Self.self, from: data)
        guard request.photoUploadConsent, request.quoteId == entry.quote.quoteId.uuidString.lowercased(),
              request.idempotencyKey == entry.id.uuidString.lowercased(), request.provider == entry.quote.provider,
              request.model == entry.quote.model, request.size == entry.quote.size, request.quality == entry.quote.quality,
              request.prompt.utf16.count <= 8000 else { throw RenderRecoveryError.storageCorrupt }
    }
}

nonisolated struct RenderJobReply: Decodable, Sendable {
    let jobId: UUID
    let status: RenderJobStatus
    let errorCode: String?
    let imageBase64: String?
    let mediaType: String?
    let debitMicros: Int
    let funding: RenderFunding
    let refunded: Bool
    let providerBilling: Bool
    let provider: CloudRenderProvider
    let model: String
    let label: String
    let resultExpiresAt: Int64?
    let resultExpired: Bool?
    let acknowledged: Bool

    func validate(for entry: RenderRecoveryEntry) throws {
        guard entry.jobID == nil || entry.jobID == jobId, provider == entry.quote.provider, model == entry.quote.model,
              debitMicros == entry.quote.debitMicros, funding == entry.quote.funding, providerBilling == entry.quote.providerBilling,
              label == RenderLimits.aiLabel, (imageBase64?.utf8.count ?? 0) <= RenderLimits.imageBase64Bytes,
              imageBase64 == nil || mediaType == "image/png", !refunded || status == .failed,
              !acknowledged || status == .succeeded else { throw RenderRecoveryError.invalidResponse }
        if status == .succeeded { guard let expiry = resultExpiresAt, expiry > 0 else { throw RenderRecoveryError.invalidResponse }; _ = expiry }
    }
}
nonisolated struct RenderAcknowledgement: Decodable, Sendable { let ok: Bool }

nonisolated struct RenderRecoveryEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID // Also the immutable idempotency key.
    let account: RenderAccountIdentity
    let projectID: UUID
    let quote: RenderQuote
    let requestSHA256: String
    let requestByteCount: Int
    let createdAt: Date
    var updatedAt: Date
    var revision: Int
    var state: RenderRecoveryState
    var jobID: UUID?
    var result: RenderImageInfo?
    var resultExpiresAt: Int64?
    var refunded: Bool
    var issue: RenderRecoveryIssue?

    func validate() throws {
        try account.validate(); try quote.validate()
        guard (0...1_000_000_000).contains(revision), requestByteCount > 0, requestByteCount <= RenderLimits.requestBytes, requestSHA256.count == 64,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              state != .acknowledged || (jobID != nil && result != nil),
              state != .saved || (jobID != nil && result != nil) else { throw RenderRecoveryError.storageCorrupt }
        if let result {
            guard (1...RenderLimits.imageBytes).contains(result.byteCount), result.sha256.count == 64,
                  (1...RenderLimits.maximumDimension).contains(result.width), (1...RenderLimits.maximumDimension).contains(result.height),
                  result.width <= RenderLimits.maximumPixels / result.height else { throw RenderRecoveryError.storageCorrupt }
        }
    }
}
nonisolated struct SavedRenderResult: Sendable {
    let recoveryID: UUID
    let account: RenderAccountIdentity
    let projectID: UUID
    let jobID: UUID
    let fileURL: URL
    let png: Data
    let image: RenderImageInfo
    let label: String
}

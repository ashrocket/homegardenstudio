import SwiftUI
import UniformTypeIdentifiers
import Combine
import CryptoKit
import ImageIO

extension UTType { nonisolated static let gardenPlan = UTType(exportedAs: "com.ashleyraiteri.homegardenstudio.plan", conformingTo: .package) }

/// FileDocument snapshots may run off the main actor. Only immutable, locked byte snapshots cross that boundary.
nonisolated final class PlanDocument: ReferenceFileDocument, @unchecked Sendable {
    struct Snapshot: Sendable { var project: Data; var originals: [String: Data]; var renders: [String: Data]; var warnings: [String] = []; var projectID: UUID = UUID(); var renderRecords: [RenderAttachmentRecord] = [] }
    static let readableContentTypes: [UTType] = [.gardenPlan]
    let objectWillChange = ObservableObjectPublisher()
    private let lock = NSLock()
    private var content: Snapshot
    private let attachmentLimit: Int
    init() { attachmentLimit = 256 * 1024 * 1024; content = Snapshot(project: (try? EngineCodec.canonicalSnapshot()) ?? Data(), originals: [:], renders: [:]) }
    init(project: Data, originals: [String: Data] = [:], renders: [String: Data] = [:], attachmentLimit: Int = 256 * 1024 * 1024) throws {
        self.attachmentLimit = attachmentLimit
        content = Snapshot(project: try EngineCodec.canonicalSnapshot(project), originals: originals, renders: renders)
    }
    required init(configuration: ReadConfiguration) throws {
        attachmentLimit = 256 * 1024 * 1024
        content = try Self.read(configuration.file)
    }
    static func read(_ wrapper: FileWrapper) throws -> Snapshot {
        guard wrapper.isDirectory, Set(wrapper.fileWrappers?.keys.map { $0 } ?? []).isSubset(of: ["project.json", "Originals", "Renders", "manifest.json"]) else {
            throw EngineError(code: "INVALID_PACKAGE", message: "The plan contains unexpected package entries.")
        }
        guard let projectFile = wrapper.fileWrappers?["project.json"], projectFile.isRegularFile,
              (projectFile.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue ?? 0 <= 8 * 1024 * 1024 else {
            throw EngineError(code: "INVALID_PACKAGE", message: "The plan JSON is missing, too large, or not a regular file.")
        }
        guard wrapper.isDirectory, let data = wrapper.fileWrappers?["project.json"]?.regularFileContents else {
            throw EngineError(code: "INVALID_PACKAGE", message: "The plan package is missing project.json.")
        }
        guard data.count <= 8 * 1024 * 1024 else { throw EngineError(code: "IMPORT_LIMIT", message: "Plan JSON exceeds 8 MB.") }
        var totalAttachmentBytes = 0
        func files(_ name: String) throws -> [String: Data] {
            guard let folder = wrapper.fileWrappers?[name] else { return [:] }
            guard folder.isDirectory else { throw EngineError(code: "INVALID_PACKAGE", message: "\(name) must be a folder.") }
            var result: [String: Data] = [:]
            for (name, file) in folder.fileWrappers ?? [:] {
                guard !name.contains("/"), !name.hasPrefix("."), file.isRegularFile,
                      (file.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue ?? 0 <= 40 * 1024 * 1024 else {
                    throw EngineError(code: "INVALID_PACKAGE", message: "An attachment is not a regular file or exceeds 40 MB.")
                }
                guard let bytes = file.regularFileContents, bytes.count <= 40 * 1024 * 1024 else {
                    throw EngineError(code: "INVALID_PACKAGE", message: "The plan contains an unsupported attachment.")
                }
                totalAttachmentBytes += bytes.count
                guard totalAttachmentBytes <= 256 * 1024 * 1024 else { throw EngineError(code: "IMPORT_LIMIT", message: "Plan attachments exceed 256 MB.") }
                result[name] = bytes
            }
            return result
        }
        let project = try EngineCodec.canonicalSnapshot(data)
        let originals = try files("Originals")
        guard originals.values.reduce(0, { $0 + $1.count }) <= 256 * 1024 * 1024 else {
            throw EngineError(code: "IMPORT_LIMIT", message: "Original attachments exceed this build's 256 MB plan limit.")
        }
        for (name, bytes) in originals {
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard name.hasPrefix(digest + ".") else { throw EngineError(code: "INVALID_PACKAGE", message: "An original attachment does not match its SHA-256 filename.") }
        }
        let decoded = try EngineCodec.decoder().decode(Project.self, from: project)
        var warnings: [String] = []
        for source in decoded.sources {
            if let sha = source.sha256, !originals.keys.contains(where: { $0.hasPrefix(sha + ".") }) {
                warnings.append("Missing original attachment for \(source.title). The layout can be edited, but this source is metadata only.")
            }
            if let sha = source.sha256, let bytes = originals.first(where: { $0.key.hasPrefix(sha + ".") })?.value, bytes.count != source.byteCount {
                throw EngineError(code: "INVALID_PACKAGE", message: "An original attachment does not match its recorded size.")
            }
        }
        var result = Snapshot(project: project, originals: originals, renders: try files("Renders"), warnings: warnings)
        if let manifestFile = wrapper.fileWrappers?["manifest.json"] {
            guard manifestFile.isRegularFile,
                  (manifestFile.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue ?? 0 <= 256 * 1024,
                  let bytes = manifestFile.regularFileContents, bytes.count <= 256 * 1024 else {
                throw EngineError(code: "INVALID_PACKAGE", message: "The native plan manifest is invalid or too large.")
            }
            let manifest = try JSONDecoder().decode(PlanManifest.self, from: bytes)
            guard manifest.version == 1, manifest.renders.count <= 100,
                  Set(manifest.renders.map(\.id)).count == manifest.renders.count,
                  manifest.renders.allSatisfy({ $0.projectID == manifest.projectID && result.renders[$0.filename] != nil && !$0.filename.contains("/") }) else {
                throw EngineError(code: "INVALID_PACKAGE", message: "The native plan manifest references invalid render attachments.")
            }
            for record in manifest.renders {
                guard let bytes = result.renders[record.filename], record.title.utf8.count <= 500, record.provider.utf8.count <= 200, record.inputDigest.utf8.count <= 128,
                      record.createdAt.timeIntervalSince1970.isFinite,
                      record.filename == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() + ".png" else {
                    throw EngineError(code: "INVALID_PACKAGE", message: "A rendered image does not match its recorded checksum.")
                }
                try validateRenderPNG(bytes)
            }
            result.projectID = manifest.projectID; result.renderRecords = manifest.renders
        }
        return result
    }
    func snapshot(contentType: UTType) throws -> Snapshot { lock.withLock { content } }
    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper { try Self.package(snapshot) }
    static func package(_ snapshot: Snapshot) throws -> FileWrapper {
        func folder(_ files: [String: Data]) -> FileWrapper { FileWrapper(directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) }) }
        let manifest = try JSONEncoder().encode(PlanManifest(version: 1, projectID: snapshot.projectID, renders: snapshot.renderRecords))
        return FileWrapper(directoryWithFileWrappers: ["project.json": FileWrapper(regularFileWithContents: snapshot.project), "Originals": folder(snapshot.originals), "Renders": folder(snapshot.renders), "manifest.json": FileWrapper(regularFileWithContents: manifest)])
    }
    @MainActor func update(project: Data) { guard lock.withLock({ content.project != project }) else { return }; objectWillChange.send(); lock.withLock { content.project = project } }
    @MainActor func checkOriginalCapacity(_ data: Data, named name: String) throws {
        let total = lock.withLock {
            content.originals.filter { $0.key != name }.values.reduce(0) { $0 + $1.count }
                + content.renders.values.reduce(0) { $0 + $1.count }
        }
        guard data.count <= 40 * 1024 * 1024, total + data.count <= attachmentLimit else {
            throw EngineError(code: "IMPORT_LIMIT", message: "This attachment exceeds the plan's combined original and render storage limit.")
        }
    }
    /// Called synchronously on the main actor after engine acceptance and before any await.
    /// Readers see either the old project and originals or the complete new pair.
    @MainActor func commitOriginal(_ data: Data, named name: String, project: Data) throws {
        try checkOriginalCapacity(data, named: name)
        objectWillChange.send()
        lock.withLock { content.originals[name] = data; content.project = project }
    }
    var projectID: UUID { lock.withLock { content.projectID } }
    var renderRecords: [RenderAttachmentRecord] { lock.withLock { content.renderRecords } }
    func render(named name: String) -> Data? { lock.withLock { content.renders[name] } }
    @MainActor func attachRender(_ data: Data, record: RenderAttachmentRecord) throws {
        guard record.projectID == projectID, data.starts(with: [137,80,78,71,13,10,26,10]), data.count <= 40 * 1024 * 1024,
              record.title.utf8.count <= 500, record.provider.utf8.count <= 200, record.inputDigest.utf8.count <= 128,
              record.createdAt.timeIntervalSince1970.isFinite else {
            throw EngineError(code: "INVALID_RENDER", message: "This image does not belong to the current plan or is not a supported PNG.")
        }
        try Self.validateRenderPNG(data)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard record.filename == digest + ".png" else { throw EngineError(code: "INVALID_RENDER", message: "The render checksum does not match its filename.") }
        let allowed = lock.withLock {
            let total = content.originals.values.reduce(0) { $0 + $1.count } + content.renders.filter { $0.key != record.filename }.values.reduce(0) { $0 + $1.count } + data.count
            return total <= attachmentLimit && (content.renderRecords.count < 100 || content.renderRecords.contains(where: { $0.id == record.id }))
        }
        guard allowed else { throw EngineError(code: "IMPORT_LIMIT", message: "The plan's render or attachment limit has been reached. The recovery copy is still available.") }
        objectWillChange.send()
        lock.withLock {
            content.renders[record.filename] = data
            content.renderRecords.removeAll { $0.id == record.id }; content.renderRecords.append(record)
        }
    }
    private static func validateRenderPNG(_ data: Data) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height), width <= 8_388_608 / height else {
            throw EngineError(code: "INVALID_RENDER", message: "The rendered PNG is incomplete or exceeds the image limits.")
        }
    }
    func original(sha: String) -> Data? { lock.withLock { content.originals.first { $0.key.hasPrefix(sha + ".") }?.value } }
}

nonisolated struct JSONPlanExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

nonisolated struct PackageExport: FileDocument {
    static var readableContentTypes: [UTType] { [.gardenPlan] }
    let content: PlanDocument.Snapshot
    init(_ content: PlanDocument.Snapshot) { self.content = content }
    init(configuration: ReadConfiguration) throws { content = try PlanDocument.read(configuration.file) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try PlanDocument.package(content) }
}

nonisolated struct RenderAttachmentRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let filename: String
    let title: String
    let provider: String
    let inputDigest: String
    let createdAt: Date
}
nonisolated private struct PlanManifest: Codable, Sendable {
    let version: Int
    let projectID: UUID
    let renders: [RenderAttachmentRecord]
}

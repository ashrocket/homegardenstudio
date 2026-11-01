import SwiftUI
import UniformTypeIdentifiers
import Combine
import CryptoKit

extension UTType { nonisolated static let gardenPlan = UTType(exportedAs: "com.ashleyraiteri.homegardenstudio.plan", conformingTo: .package) }

/// FileDocument snapshots may run off the main actor. Only immutable, locked byte snapshots cross that boundary.
nonisolated final class PlanDocument: ReferenceFileDocument, @unchecked Sendable {
    struct Snapshot: Sendable { var project: Data; var originals: [String: Data]; var renders: [String: Data]; var warnings: [String] = [] }
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
        guard wrapper.isDirectory, Set(wrapper.fileWrappers?.keys.map { $0 } ?? []).isSubset(of: ["project.json", "Originals", "Renders"]) else {
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
        return Snapshot(project: project, originals: originals, renders: try files("Renders"), warnings: warnings)
    }
    func snapshot(contentType: UTType) throws -> Snapshot { lock.withLock { content } }
    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper { Self.package(snapshot) }
    static func package(_ snapshot: Snapshot) -> FileWrapper {
        func folder(_ files: [String: Data]) -> FileWrapper { FileWrapper(directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) }) }
        return FileWrapper(directoryWithFileWrappers: ["project.json": FileWrapper(regularFileWithContents: snapshot.project), "Originals": folder(snapshot.originals), "Renders": folder(snapshot.renders)])
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
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { PlanDocument.package(content) }
}

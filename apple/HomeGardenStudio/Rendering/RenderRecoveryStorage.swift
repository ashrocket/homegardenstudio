import Foundation
import Darwin

nonisolated protocol RenderRecoveryStorage: Sendable {
    func entries() async throws -> [RenderRecoveryEntry]
    func entry(id: UUID) async throws -> RenderRecoveryEntry
    func insert(_ entry: RenderRecoveryEntry, request: Data) async throws
    func request(id: UUID) async throws -> Data
    func update(_ entry: RenderRecoveryEntry) async throws -> RenderRecoveryEntry
    func saveResult(_ png: Data, entry: RenderRecoveryEntry) async throws -> RenderRecoveryEntry
    func savedResult(id: UUID) async throws -> SavedRenderResult?
    func remove(id: UUID) async throws
    func deleteAccount(_ identity: RenderAccountIdentity) async throws
}

nonisolated struct RenderStorageLimits: Sendable {
    let maximumEntries: Int
    let maximumBytes: Int
    init(maximumEntries: Int = 16, maximumBytes: Int = 128 * 1024 * 1024) {
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes
    }
}
nonisolated enum RenderStorageWriteStage: Equatable, Sendable {
    case recordBeforeCommit, resultBeforeRename, resultAfterSync, metadataBeforeRename
}

/// A private app-owned recovery journal. No project package or Keychain credentials are stored here.
/// Atomic replacement + file and parent-directory synchronization precede every successful commit.
actor FileRenderRecoveryStorage: RenderRecoveryStorage {
    private let root: URL
    private let limits: RenderStorageLimits
    private let fault: @Sendable (RenderStorageWriteStage) throws -> Void
    private let metadataLimit = 32 * 1024
    private let manager = FileManager.default

    init(rootURL: URL, limits: RenderStorageLimits = RenderStorageLimits(),
         fault: @escaping @Sendable (RenderStorageWriteStage) throws -> Void = { _ in }) throws {
        guard rootURL.isFileURL, limits.maximumEntries > 0, limits.maximumEntries <= 100,
              limits.maximumBytes > 0, limits.maximumBytes <= 512 * 1024 * 1024 else { throw RenderRecoveryError.invalidInput }
        root = rootURL.standardizedFileURL; self.limits = limits; self.fault = fault
    }

    nonisolated static func applicationDefault() throws -> FileRenderRecoveryStorage {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RenderRecoveryError.storageFailure
        }
        return try FileRenderRecoveryStorage(rootURL: support.appendingPathComponent("HomeGardenStudio/RenderRecovery", isDirectory: true))
    }

    func entries() throws -> [RenderRecoveryEntry] { try locked { try readEntries() } }
    func entry(id: UUID) throws -> RenderRecoveryEntry { try locked { try readEntry(id) } }

    func insert(_ entry: RenderRecoveryEntry, request: Data) throws {
        try locked {
            try entry.validate(); try FrozenRenderRequest.validatePersisted(request, entry: entry)
            try checkAccount(entry.account)
            let current = try readEntries()
            guard current.count < limits.maximumEntries,
                  !manager.fileExists(atPath: directory(entry.id).path) else { throw RenderRecoveryError.storageFull }
            // Reserve room for an atomic image replacement, so a new submission cannot consume earlier jobs' recovery room.
            guard !current.contains(where: { $0.account == entry.account && $0.quote.quoteId == entry.quote.quoteId }) else {
                throw RenderRecoveryError.storageConflict
            }
            let reserved = current.reduce(0) { $0 + reservation($1) }
            guard reservation(entry) <= limits.maximumBytes - reserved else { throw RenderRecoveryError.storageFull }
            let staging = root.appendingPathComponent(".staging-" + UUID().uuidString.lowercased(), isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var committed = false
            defer { if !committed { try? manager.removeItem(at: staging) } }
            try writeAtomic(request, to: staging.appendingPathComponent("request.json"))
            try writeAtomic(try encode(entry), to: staging.appendingPathComponent("entry.json"))
            try synchronizeDirectory(staging)
            try fault(.recordBeforeCommit)
            guard Darwin.rename(staging.path, directory(entry.id).path) == 0 else { throw RenderRecoveryError.storageFailure }
            committed = true
            try synchronizeDirectory(root)
        }
    }

    func request(id: UUID) throws -> Data {
        try locked {
            let entry = try readEntry(id); try checkAccount(entry.account)
            let data = try readBounded(directory(id).appendingPathComponent("request.json"), maximum: RenderLimits.requestBytes)
            try FrozenRenderRequest.validatePersisted(data, entry: entry)
            return data
        }
    }

    func update(_ entry: RenderRecoveryEntry) throws -> RenderRecoveryEntry {
        try locked {
            let old = try readEntry(entry.id)
            try immutableFieldsMatch(old, entry)
            try checkAccount(entry.account); try entry.validate()
            guard old.revision == entry.revision else { throw RenderRecoveryError.storageConflict }
            var next = entry; next.revision += 1
            try writeAtomic(try encode(next), to: directory(entry.id).appendingPathComponent("entry.json"), stage: .metadataBeforeRename)
            return next
        }
    }

    func saveResult(_ png: Data, entry: RenderRecoveryEntry) throws -> RenderRecoveryEntry {
        try locked {
            let old = try readEntry(entry.id)
            try immutableFieldsMatch(old, entry); try checkAccount(entry.account)
            guard old.revision == entry.revision else { throw RenderRecoveryError.storageConflict }
            let info = try RenderImageValidator.validate(png)
            guard entry.result == info, entry.state == .saved, entry.jobID != nil else { throw RenderRecoveryError.invalidResponse }
            try entry.validate()
            if let prior = old.result, prior != info { throw RenderRecoveryError.invalidResponse }
            try writeAtomic(png, to: directory(entry.id).appendingPathComponent("result.png"), stage: .resultBeforeRename)
            // A complete synchronized PNG is necessary but insufficient: its journal receipt must commit too.
            try fault(.resultAfterSync)
            var next = entry; next.revision += 1
            try writeAtomic(try encode(next), to: directory(entry.id).appendingPathComponent("entry.json"), stage: .metadataBeforeRename)
            guard try readSavedResult(entry.id) != nil else { throw RenderRecoveryError.storageFailure }
            return next
        }
    }

    func savedResult(id: UUID) throws -> SavedRenderResult? { try locked { try readSavedResult(id) } }

    func remove(id: UUID) throws {
        try locked {
            let entry = try readEntry(id)
            guard !entry.state.isUnresolved else { throw RenderRecoveryError.unresolvedRecovery }
            try manager.removeItem(at: directory(id)); try synchronizeDirectory(root)
        }
    }

    func deleteAccount(_ identity: RenderAccountIdentity) throws {
        try locked {
            try identity.validate()
            // Durable tombstone first: an operation already in flight cannot recreate the deleted journal.
            try writeAtomic(Data(), to: root.appendingPathComponent(".deleted-" + identity.storageKey))
            for entry in try readEntries() where entry.account == identity {
                try manager.removeItem(at: directory(entry.id))
            }
            try synchronizeDirectory(root)
        }
    }

    private func readSavedResult(_ id: UUID) throws -> SavedRenderResult? {
        let entry = try readEntry(id); try checkAccount(entry.account)
        guard let expected = entry.result, let jobID = entry.jobID else { return nil }
        let url = directory(id).appendingPathComponent("result.png")
        let png = try readBounded(url, maximum: RenderLimits.imageBytes)
        let actual = try RenderImageValidator.validate(png)
        guard expected == actual else { throw RenderRecoveryError.storageCorrupt }
        return SavedRenderResult(recoveryID: id, account: entry.account, projectID: entry.projectID, jobID: jobID,
                                 fileURL: url, png: png, image: actual, label: RenderLimits.aiLabel)
    }
    private func readEntry(_ id: UUID) throws -> RenderRecoveryEntry {
        do {
            let data = try readBounded(directory(id).appendingPathComponent("entry.json"), maximum: metadataLimit)
            let entry = try JSONDecoder().decode(RenderRecoveryEntry.self, from: data)
            guard entry.id == id else { throw RenderRecoveryError.storageCorrupt }
            try entry.validate()
            return entry
        } catch let error as RenderRecoveryError { throw error }
        catch { throw RenderRecoveryError.storageCorrupt }
    }
    private func readEntries() throws -> [RenderRecoveryEntry] {
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [RenderRecoveryEntry] = []
        for url in children {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw RenderRecoveryError.storageCorrupt }
            result.append(try readEntry(id))
            guard result.count <= limits.maximumEntries else { throw RenderRecoveryError.storageCorrupt }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
    private func immutableFieldsMatch(_ a: RenderRecoveryEntry, _ b: RenderRecoveryEntry) throws {
        guard a.id == b.id, a.account == b.account, a.projectID == b.projectID, a.quote == b.quote,
              a.requestSHA256 == b.requestSHA256, a.requestByteCount == b.requestByteCount, a.createdAt == b.createdAt,
              a.jobID == nil || a.jobID == b.jobID else { throw RenderRecoveryError.storageCorrupt }
    }
    private func checkAccount(_ identity: RenderAccountIdentity) throws {
        guard !manager.fileExists(atPath: root.appendingPathComponent(".deleted-" + identity.storageKey).path) else {
            throw RenderRecoveryError.accountDeleted
        }
    }
    private func reservation(_ entry: RenderRecoveryEntry) -> Int {
        entry.requestByteCount + (entry.state == .failed || entry.state == .unavailable ? (entry.result?.byteCount ?? 0) : 2 * RenderLimits.imageBytes) + 2 * metadataLimit
    }
    private func encode(_ entry: RenderRecoveryEntry) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        guard data.count <= metadataLimit else { throw RenderRecoveryError.storageCorrupt }
        return data
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw RenderRecoveryError.storageCorrupt }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var rootURL = root, flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try rootURL.setResourceValues(flags)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            #endif
            let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw RenderRecoveryError.storageFailure }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw RenderRecoveryError.storageFailure }
            defer { flock(fd, LOCK_UN) }
            return try operation()
        } catch let error as RenderRecoveryError { throw error }
        catch { throw RenderRecoveryError.storageFailure }
    }

    private func currentBytes() throws -> Int {
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            throw RenderRecoveryError.storageFailure
        }
        var total = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw RenderRecoveryError.storageCorrupt }
            if values.isRegularFile == true {
                let size = values.fileSize ?? 0
                guard size >= 0, total <= limits.maximumBytes - size else { throw RenderRecoveryError.storageFull }
                total += size
            }
        }
        return total
    }

    private func writeAtomic(_ data: Data, to destination: URL, stage: RenderStorageWriteStage? = nil) throws {
        guard data.count <= limits.maximumBytes - (try currentBytes()) else { throw RenderRecoveryError.storageFull }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RenderRecoveryError.storageFailure }
        var renamed = false
        defer { Darwin.close(fd); if !renamed { try? manager.removeItem(at: temporary) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw RenderRecoveryError.storageFailure }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw RenderRecoveryError.storageFailure }
        if let stage { try fault(stage) }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw RenderRecoveryError.storageFailure }
        renamed = true
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw RenderRecoveryError.storageFailure }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw RenderRecoveryError.storageFailure }
    }
    private func readBounded(_ url: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RenderRecoveryError.storageCorrupt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0, info.st_size <= Int64(maximum) else {
            throw RenderRecoveryError.storageCorrupt
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, maximum - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximum - data.count else { throw RenderRecoveryError.storageCorrupt }
            data.append(chunk)
        }
        return data
    }
}

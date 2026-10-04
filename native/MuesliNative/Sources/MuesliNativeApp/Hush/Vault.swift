import Foundation
import CryptoKit
import Security
import CommonCrypto
import Darwin
import MuesliCore

/// One coordinator owns a vault directory; all operations on that instance are serialized.
final class Vault {
    private struct PendingAudio: Codable {
        let meetingID: UUID
        let chunks: [AudioChunk]
    }

    private struct Contents: Codable {
        let version: Int
        var meetings: [Meeting]
        var pendingAudio: [PendingAudio] = []
    }

    private struct Envelope: Codable {
        let version: Int
        let purpose: String
        let sealed: Data
        let salt: Data?
        let iterations: UInt32?
    }

    enum Failure: LocalizedError {
        case invalidStorage, missingKey, invalidKey, keychain(OSStatus), random(OSStatus)
        case invalidData, invalidBackup, invalidPassword, invalidVector, missingMeeting, io(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidStorage: return "The vault path must be a private directory, not a symbolic link."
            case .missingKey: return "The vault encryption key is missing. Restore an authenticated backup into a new vault."
            case .invalidKey: return "The vault encryption key is invalid."
            case .keychain(let status): return "Keychain access failed (\(status)). Unlock the login Keychain and retry."
            case .random(let status): return "Secure random generation failed (\(status))."
            case .invalidData: return "The vault is damaged, has an unsupported format, or cannot be authenticated."
            case .invalidBackup: return "The backup is damaged, unsupported, or the password/recovery phrase is incorrect. The current vault was not replaced."
            case .invalidPassword: return "Enter a nonempty password or recovery phrase (at most 4,096 UTF-8 bytes)."
            case .invalidVector: return "A semantic query must contain finite values and have nonzero magnitude."
            case .io(let code): return "Private storage I/O failed (\(code))."
            case .missingMeeting: return "Recording meeting no longer exists."
            }
        }
    }

    private static let maximumFileSize = 512 * 1024 * 1024
    private static let backupIterations: UInt32 = 600_000
    private let directory: URL
    private let file: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    init(directory: URL, testMode: Bool = false) throws {
        let root = directory.standardizedFileURL
        guard root.isFileURL else { throw Failure.invalidStorage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidStorage
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        self.directory = root
        self.file = root.appendingPathComponent("vault.pgenc")
        let exists = FileManager.default.fileExists(atPath: file.path)
        let rawKey: Data
        if testMode {
            let keyFile = root.appendingPathComponent("test-vault-key.bin")
            if FileManager.default.fileExists(atPath: keyFile.path) {
                rawKey = try Self.readPrivateFile(keyFile, maximumSize: 32)
            } else {
                guard !exists else { throw Failure.missingKey }
                rawKey = try Self.randomBytes(count: 32)
                try Self.atomicWrite(rawKey, to: keyFile)
            }
        } else {
            // Preserve both the path-derived account and legacy service to unlock existing vaults.
            let account = HushDatabaseEncryption.keychainAccount(directory: root)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: HushDatabaseEncryption.keychainService,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false
            ]
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecSuccess {
                guard let data = result as? Data else { throw Failure.invalidKey }
                rawKey = data
            } else if status == errSecItemNotFound {
                guard !exists else { throw Failure.missingKey }
                rawKey = try Self.randomBytes(count: 32)
                var item = query
                item[kSecValueData as String] = rawKey
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw Failure.keychain(added) }
            } else {
                throw Failure.keychain(status)
            }
        }
        guard rawKey.count == 32 else { throw Failure.invalidKey }
        self.key = SymmetricKey(data: rawKey)
        if exists {
            _ = try load()
        } else {
            try persist(Contents(version: 1, meetings: []))
        }
    }

    /// Domain-separated SQLCipher key; never exports the vault's snapshot encryption key.
    func databaseEncryptionKey() -> Data {
        HushDatabaseEncryption.deriveKey(vaultKey: key)
    }

    func meetings() throws -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        return try load().meetings.sorted(by: Self.newestFirst)
    }

    func save(_ meeting: Meeting) throws {
        lock.lock(); defer { lock.unlock() }
        var contents = try load()
        if let index = contents.meetings.firstIndex(where: { $0.id == meeting.id }) {
            contents.meetings[index] = meeting
        } else {
            contents.meetings.append(meeting)
        }
        try Self.validate(contents)
        try persist(contents)
    }

    func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var contents = try load()
        contents.meetings.removeAll { $0.id == id }
        contents.pendingAudio.removeAll { $0.meetingID == id }
        try persist(contents)
    }

    /// Roll back a failed startup only if its provisional meeting is still untouched.
    /// The check and removal share the append/acknowledgment lock.
    func discardUnusedMeeting(_ provisional: Meeting) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var contents = try load()
        guard let index = contents.meetings.firstIndex(where: { $0.id == provisional.id }) else { return false }
        let meeting = contents.meetings[index]
        guard meeting.title == provisional.title, meeting.startedAt == provisional.startedAt,
              meeting.segments.isEmpty, meeting.scratchNotes.isEmpty, meeting.summary.isEmpty,
              meeting.embeddings.isEmpty,
              !contents.pendingAudio.contains(where: { $0.meetingID == meeting.id }) else { return false }
        contents.meetings.remove(at: index)
        try persist(contents)
        return true
    }

    /// Merge new audio under the same lock as transcript acknowledgments.
    func appendPendingChunks(_ chunks: [AudioChunk], meetingID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var contents = try load()
        guard let meeting = contents.meetings.first(where: { $0.id == meetingID }) else {
            throw Failure.missingMeeting
        }
        let index = contents.pendingAudio.firstIndex(where: { $0.meetingID == meetingID })
        var pending = index.map { contents.pendingAudio[$0].chunks } ?? []
        var ids = Set(pending.map(\.id))
        let completed = Set(meeting.segments.map(\.chunkID))
        let fresh = chunks.filter { !completed.contains($0.id) && ids.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        pending.append(contentsOf: fresh)
        let batch = PendingAudio(meetingID: meetingID, chunks: pending)
        if let index { contents.pendingAudio[index] = batch }
        else { contents.pendingAudio.append(batch) }
        try Self.validate(contents)
        try persist(contents)
    }

    func pendingChunks() throws -> [(meetingID: UUID, chunks: [AudioChunk])] {
        lock.lock(); defer { lock.unlock() }
        return try load().pendingAudio.map { (meetingID: $0.meetingID, chunks: $0.chunks) }
    }

    /// Save the result and acknowledge only its chunk in one encrypted commit.
    /// Concurrent audio appends and the latest meeting notes remain intact.
    func commitTranscription(_ segment: TranscriptSegment, meetingID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var contents = try load()
        guard let meetingIndex = contents.meetings.firstIndex(where: { $0.id == meetingID }),
              let batchIndex = contents.pendingAudio.firstIndex(where: { $0.meetingID == meetingID }),
              contents.pendingAudio[batchIndex].chunks.contains(where: { $0.id == segment.chunkID }) else { return }
        if !contents.meetings[meetingIndex].segments.contains(where: { $0.chunkID == segment.chunkID }) {
            contents.meetings[meetingIndex].segments.append(segment)
            contents.meetings[meetingIndex].segments.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        let remaining = contents.pendingAudio[batchIndex].chunks.filter { $0.id != segment.chunkID }
        if remaining.isEmpty { contents.pendingAudio.remove(at: batchIndex) }
        else { contents.pendingAudio[batchIndex] = PendingAudio(meetingID: meetingID, chunks: remaining) }
        try Self.validate(contents)
        try persist(contents)
    }

    func exportBackup(to destination: URL, recoveryPhrase: String) throws {
        lock.lock(); defer { lock.unlock() }
        let target = destination.standardizedFileURL
        // Never allow an export to overwrite the live vault or its test key.
        guard target.isFileURL,
              target.resolvingSymlinksInPath() != file.resolvingSymlinksInPath(),
              target.resolvingSymlinksInPath() != directory.appendingPathComponent("test-vault-key.bin").resolvingSymlinksInPath()
        else { throw Failure.invalidStorage }
        let salt = try Self.randomBytes(count: 32)
        let backupKey = try Self.passwordKey(recoveryPhrase, salt: salt)
        let contents = try load()
        let envelope = try Self.encrypt(contents, key: backupKey, purpose: "backup", salt: salt,
                                        iterations: Self.backupIterations)
        try Self.atomicWrite(JSONEncoder().encode(envelope), to: target)
    }

    func restoreBackup(from source: URL, recoveryPhrase: String) throws {
        lock.lock(); defer { lock.unlock() }
        let contents: Contents
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Self.readPrivateFile(source))
            guard envelope.version == 1, envelope.purpose == "backup",
                  let salt = envelope.salt, salt.count == 32,
                  envelope.iterations == Self.backupIterations else { throw Failure.invalidBackup }
            let backupKey = try Self.passwordKey(recoveryPhrase, salt: salt)
            contents = try Self.decrypt(envelope, key: backupKey)
            try Self.validate(contents)
        } catch Failure.invalidPassword {
            throw Failure.invalidPassword
        } catch {
            throw Failure.invalidBackup
        }
        // Only a fully decrypted, authenticated, schema-validated snapshot reaches replacement.
        // Re-encrypt with this machine's key; never install the backup key as a local key.
        try persist(contents)
    }

    func search(_ query: String) throws -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        let terms = Self.words(query)
        let contents = try load()
        guard !terms.isEmpty else { return contents.meetings.sorted(by: Self.newestFirst) }
        let wanted = Set(terms)
        let phrase = Self.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return contents.meetings.compactMap { meeting -> (Meeting, Double)? in
            let fields: [(String, Double)] = [(meeting.title, 4), (meeting.summary, 2),
                                            (meeting.scratchNotes, 1.5),
                                            (meeting.segments.map(\.text).joined(separator: " "), 1)]
            var matched = Set<String>()
            var score = 0.0
            for (text, weight) in fields {
                let words = Self.words(text)
                let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
                for term in wanted {
                    if let count = counts[term] {
                        matched.insert(term)
                        score += weight * (1 + log(Double(count)))
                    }
                }
                if !phrase.isEmpty && Self.normalized(text).contains(phrase) { score += weight * 2 }
            }
            // All query words must be present, so adding query terms narrows results.
            guard matched == wanted else { return nil }
            return (meeting, score)
        }.sorted {
            $0.1 == $1.1 ? Self.newestFirst($0.0, $1.0) : $0.1 > $1.1
        }.map { $0.0 }
    }

    func semanticSearch(_ vector: [Float]) throws -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else { throw Failure.invalidVector }
        let queryMagnitude = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard queryMagnitude > 0 else { throw Failure.invalidVector }
        return try load().meetings.compactMap { meeting -> (Meeting, Double)? in
            var best: Double?
            for embedding in meeting.embeddings where embedding.count == vector.count {
                var dot = 0.0
                var magnitudeSquared = 0.0
                for index in vector.indices {
                    let value = Double(embedding[index])
                    dot += Double(vector[index]) * value
                    magnitudeSquared += value * value
                }
                guard magnitudeSquared > 0 else { continue }
                let similarity = dot / (queryMagnitude * sqrt(magnitudeSquared))
                best = max(best ?? -Double.infinity, similarity)
            }
            guard let score = best else { return nil }
            return (meeting, score)
        }.sorted {
            $0.1 == $1.1 ? Self.newestFirst($0.0, $1.0) : $0.1 > $1.1
        }.map { $0.0 }
    }

    /// 256 random bits displayed as eight hex groups; deliberately not a BIP39 phrase.
    static func generateRecoveryPhrase() throws -> String {
        let bytes = try randomBytes(count: 32)
        let groups = stride(from: 0, to: bytes.count, by: 4).map { offset in
            bytes[offset..<(offset + 4)].map { String(format: "%02x", $0) }.joined()
        }
        return "pg1-" + groups.joined(separator: "-")
    }

    private func load() throws -> Contents {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Self.readPrivateFile(file))
            guard envelope.version == 1, envelope.purpose == "vault",
                  envelope.salt == nil, envelope.iterations == nil else { throw Failure.invalidData }
            let contents = try Self.decrypt(envelope, key: key)
            try Self.validate(contents)
            return contents
        } catch {
            throw Failure.invalidData
        }
    }

    private func persist(_ contents: Contents) throws {
        let envelope = try Self.encrypt(contents, key: key, purpose: "vault", salt: nil, iterations: nil)
        try Self.atomicWrite(JSONEncoder().encode(envelope), to: file)
    }

    private static func authenticatedHeader(_ envelope: Envelope) -> Data {
        // Fixed field order and unambiguous delimiters; all defined header fields are authenticated.
        // The legacy domain is part of vault and backup authentication, not product branding.
        Data("PrivateGranola|\(envelope.version)|\(envelope.purpose)|\(envelope.salt?.base64EncodedString() ?? "")|\(envelope.iterations.map { String($0) } ?? "")".utf8)
    }

    private static func encrypt(_ contents: Contents, key: SymmetricKey, purpose: String,
                                salt: Data?, iterations: UInt32?) throws -> Envelope {
        let header = Envelope(version: 1, purpose: purpose, sealed: Data(), salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(contents)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedHeader(header))
        guard let combined = box.combined else { throw Failure.invalidData }
        return Envelope(version: 1, purpose: purpose, sealed: combined, salt: salt, iterations: iterations)
    }

    private static func decrypt(_ envelope: Envelope, key: SymmetricKey) throws -> Contents {
        let box = try AES.GCM.SealedBox(combined: envelope.sealed)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: authenticatedHeader(envelope))
        return try JSONDecoder().decode(Contents.self, from: plaintext)
    }

    private static func validate(_ contents: Contents) throws {
        guard contents.version == 1, Set(contents.meetings.map(\.id)).count == contents.meetings.count else {
            throw Failure.invalidData
        }
        for meeting in contents.meetings {
            guard meeting.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(meeting.segments.map(\.id)).count == meeting.segments.count else { throw Failure.invalidData }
            for segment in meeting.segments {
                guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                      segment.end >= segment.start else { throw Failure.invalidData }
            }
            for embedding in meeting.embeddings {
                guard !embedding.isEmpty, embedding.allSatisfy({ $0.isFinite }) else { throw Failure.invalidData }
            }
        }
        guard Set(contents.pendingAudio.map(\.meetingID)).count == contents.pendingAudio.count else {
            throw Failure.invalidData
        }
        for batch in contents.pendingAudio {
            guard !batch.chunks.isEmpty, Set(batch.chunks.map(\.id)).count == batch.chunks.count else {
                throw Failure.invalidData
            }
            for chunk in batch.chunks {
                guard chunk.start.isFinite, chunk.end.isFinite, chunk.start >= 0, chunk.end >= chunk.start,
                      !chunk.data.isEmpty, !chunk.mimeType.isEmpty else { throw Failure.invalidData }
            }
        }
    }

    private static func passwordKey(_ password: String, salt: Data) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        guard !bytes.isEmpty, bytes.count <= 4_096 else { throw Failure.invalidPassword }
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { output in
            bytes.withUnsafeBytes { input in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        input.bindMemory(to: Int8.self).baseAddress!, bytes.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), backupIterations,
                                        output.bindMemory(to: UInt8.self).baseAddress!, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.invalidBackup }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.random(status) }
        return bytes
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func words(_ text: String) -> [String] {
        normalized(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func newestFirst(_ lhs: Meeting, _ rhs: Meeting) -> Bool {
        lhs.startedAt == rhs.startedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.startedAt > rhs.startedAt
    }

    private static func readPrivateFile(_ url: URL, maximumSize: Int = maximumFileSize) throws -> Data {
        guard url.isFileURL else { throw Failure.invalidStorage }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.io(errno) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.io(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
              info.st_size <= Int64(maximumSize) else { throw Failure.invalidData }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: Int(info.st_size) + 1), data.count <= maximumSize,
              data.count == Int(info.st_size) else { throw Failure.invalidData }
        return data
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL, data.count <= maximumFileSize else { throw Failure.invalidStorage }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".pg-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io(errno) }
        var closed = false
        defer {
            if !closed { Darwin.close(descriptor) }
            Darwin.unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.io(errno) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw Failure.io(errno) }
        let closeStatus = Darwin.close(descriptor)
        closed = true
        guard closeStatus == 0 else { throw Failure.io(errno) }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw Failure.io(errno) }
        // Rename is the commit point. A directory sync is best-effort because some volumes reject it;
        // reporting failure after commit would incorrectly promise that restore left the old data intact.
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parentDescriptor >= 0 {
            _ = fsync(parentDescriptor)
            Darwin.close(parentDescriptor)
        }
    }
}

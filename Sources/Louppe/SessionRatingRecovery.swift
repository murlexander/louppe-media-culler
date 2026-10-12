import Foundation
import CryptoKit
import Darwin

struct SessionContentProof: Sendable {
    let identity: FileOperationJournal.FileIdentity
    let sha256: String
}

enum SessionVerifiedFile: Sendable {
    case identity(FileOperationJournal.FileIdentity)
    case content(SessionContentProof)

    var identity: FileOperationJournal.FileIdentity {
        switch self {
        case .identity(let identity): return identity
        case .content(let proof): return proof.identity
        }
    }
    var proof: SessionContentProof? {
        if case .content(let proof) = self { return proof }
        return nil
    }
}

enum SessionContentCheckState: Equatable {
    case idle
    case checking(done: Int, total: Int)
    case paused
    case finished
}

enum SessionRecoveryPolicy {
    static func hasSavedMetadata(_ entry: SessionEntry) -> Bool {
        entry.rating != Rating.undecided.rawValue || entry.ratedAt != nil
            || entry.stars != nil || entry.starsChangedAt != nil
            || entry.colorLabel != nil || entry.colorChangedAt != nil
    }

    static func isUntouched(_ metadata: PhotoFileMetadataSnapshot) -> Bool {
        metadata.rating == .undecided && metadata.ratedAt == nil
            && metadata.starRating == nil && metadata.starsChangedAt == nil
            && metadata.colorLabel == nil && metadata.colorChangedAt == nil
    }
}

/// One sequential utility lane, bounded to 1 MiB. The held descriptor and path
/// must still identify the scan's regular file before and after reading. Never
/// hash a replacement or accept a symlink. Cancellation is checked per chunk.
enum SessionContentVerifier {
    enum VerificationError: Error { case changedOrUnavailable }

    /// Explicit user confirmation needs a fresh identity check, not a full
    /// read of every RAW/video before their decisions become available.
    static func validateIdentity(_ file: PhotoFile) throws -> FileOperationJournal.FileIdentity {
        try Task.checkCancellation()
        guard let expected = file.scannedIdentity,
              try FileOperationJournal.captureIdentity(at: file.url) == expected else {
            throw VerificationError.changedOrUnavailable
        }
        let descriptor = file.url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw VerificationError.changedOrUnavailable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(info.st_dev) == expected.systemNumber,
              UInt64(info.st_ino) == expected.fileNumber,
              try FileOperationJournal.captureIdentity(at: file.url) == expected else {
            throw VerificationError.changedOrUnavailable
        }
        try Task.checkCancellation()
        return expected
    }

    static func verify(
        _ file: PhotoFile,
        knownProof: SessionContentProof? = nil
    ) throws -> SessionContentProof {
        try Task.checkCancellation()
        guard let expected = file.scannedIdentity,
              try FileOperationJournal.captureIdentity(at: file.url) == expected else {
            throw VerificationError.changedOrUnavailable
        }
        let descriptor = file.url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw VerificationError.changedOrUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(before.st_dev) == expected.systemNumber,
              UInt64(before.st_ino) == expected.fileNumber else {
            throw VerificationError.changedOrUnavailable
        }
        let digest: String
        if let proof = knownProof, proof.identity == expected {
            digest = proof.sha256
        } else {
            var hash = SHA256()
            var count: Int64 = 0
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                count += Int64(data.count)
                guard count <= before.st_size else { throw VerificationError.changedOrUnavailable }
                hash.update(data: data)
            }
            guard count == before.st_size else { throw VerificationError.changedOrUnavailable }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        try Task.checkCancellation()
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              try FileOperationJournal.captureIdentity(at: file.url) == expected else {
            throw VerificationError.changedOrUnavailable
        }
        return SessionContentProof(identity: expected, sha256: digest)
    }
}

/// Keeps canceled/restarted sessions from overlapping physical reads. A canceled
/// queued request exits before opening its file, even if an earlier read was slow.
actor SessionContentVerificationLane {
    static let shared = SessionContentVerificationLane()

    func verify(_ file: PhotoFile, knownProof: SessionContentProof?) async throws -> SessionContentProof {
        try SessionContentVerifier.verify(file, knownProof: knownProof)
    }
}

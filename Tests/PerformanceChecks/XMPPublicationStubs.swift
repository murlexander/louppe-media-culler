#if LOUPPE_TESTING
import Foundation

/// The dependency-free performance harness compiles SessionStore directly
/// instead of linking the Objective-C++ XMPCore target. These inert shapes
/// preserve SessionStore's production lifecycle API; performance coverage for
/// the real planner/worker lives in XCTest where the full package is linked.
enum XMPApplicationProfile: Sendable {
    case universal

    var usesVisibleDecisionKeywordsByDefault: Bool { false }
}

struct XMPPublicationMetadata: Equatable, Hashable, Sendable {
    let decision: Rating
    let stars: StarRating?
    let colorLabel: PhotoColorLabel?
    let profile: XMPApplicationProfile
    let visibleDecisionKeywords: Bool
    let allowExternalLabelRemoval: Bool

    init(
        snapshot: PhotoFileMetadataSnapshot,
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool? = nil,
        allowExternalLabelRemoval: Bool = false
    ) {
        decision = snapshot.rating
        stars = snapshot.starRating
        colorLabel = snapshot.colorLabel
        self.profile = profile
        self.visibleDecisionKeywords = visibleDecisionKeywords
            ?? profile.usesVisibleDecisionKeywordsByDefault
        self.allowExternalLabelRemoval = allowExternalLabelRemoval
    }
}

enum XMPMetadataDimension: String, CaseIterable, Hashable, Sendable {
    case decision
    case stars
    case color
}

struct XMPSameStemConflictDescriptor: Equatable, Sendable, Identifiable {
    enum Role: String, Equatable, Sendable {
        case raw
        case jpeg
        case other
    }

    enum Ineligibility: Equatable, Sendable {
        case ambiguousFamily
        case unsupportedMembers
        case missingSessionIdentity
    }

    enum ResolutionEligibility: Equatable, Sendable {
        case eligible
        case ineligible(Ineligibility)
    }

    struct Member: Equatable, Sendable, Identifiable {
        let id: String
        let exactPath: XMPExactFileSystemPath
        let role: Role
        let metadata: PhotoFileMetadataSnapshot
        let scannedIdentity: FileOperationJournal.FileIdentity
        let wasSelectedForExport: Bool
    }

    let id: String
    let sessionGeneration: UInt64
    let members: [Member]
    let differingDimensions: Set<XMPMetadataDimension>
    let resolutionEligibility: ResolutionEligibility

    var rawMember: Member? { members.first(where: { $0.role == .raw }) }
    var jpegMember: Member? { members.first(where: { $0.role == .jpeg }) }

    /// Must stay identical to the production property in
    /// `Sources/Louppe/XMP/XMPPublication.swift`. SessionStore's mutation
    /// boundary calls this, so a weaker copy here would let the performance
    /// harness pass on input the app rejects.
    var isStructurallyResolvable: Bool {
        guard resolutionEligibility == .eligible,
              members.count == 2,
              members.count(where: { $0.role == .raw }) == 1,
              members.count(where: { $0.role == .jpeg }) == 1,
              let raw = rawMember,
              let jpeg = jpegMember,
              raw.id != jpeg.id,
              raw.exactPath != jpeg.exactPath,
              raw.metadata.fileID == raw.id,
              jpeg.metadata.fileID == jpeg.id,
              FolderScanner.rawExtensions.contains(
                raw.exactPath.url.pathExtension.lowercased()
              ),
              ["jpg", "jpeg"].contains(
                jpeg.exactPath.url.pathExtension.lowercased()
              ) else { return false }
        var actualDifferences: Set<XMPMetadataDimension> = []
        if raw.metadata.rating != jpeg.metadata.rating {
            actualDifferences.insert(.decision)
        }
        if raw.metadata.starRating != jpeg.metadata.starRating {
            actualDifferences.insert(.stars)
        }
        if raw.metadata.colorLabel != jpeg.metadata.colorLabel {
            actualDifferences.insert(.color)
        }
        return !actualDifferences.isEmpty
            && actualDifferences == differingDimensions
    }
}

struct XMPExportApplicationPacket: Equatable, Sendable {
    let source: XMPExactFileSystemPath
    let ownerMediaPath: XMPExactFileSystemPath
    let identity: FileOperationJournal.FileIdentity
    let sourceDigest: Data
}

enum XMPPublicationCategory: Equatable, Sendable {
    case create
    case update
    case alreadyCurrent
    case copyUnchangedApplicationPacket
    case unsupportedMedia
    case sameStemMetadataConflict
    case destinationCollision
    case malformedXMP
    case readOnlyPermissionFailure
    case unsafeFileType
    case externalModificationConflict

    var canPublish: Bool {
        self == .create || self == .update || self == .alreadyCurrent
    }

    var isConflict: Bool {
        self == .sameStemMetadataConflict
            || self == .destinationCollision
            || self == .externalModificationConflict
    }

    var isFailure: Bool {
        self == .malformedXMP
            || self == .readOnlyPermissionFailure
            || self == .unsafeFileType
    }
}

struct XMPExportPreparedFamily: Equatable, Sendable {
    var membership: XMPFamilyMembership? = nil
    let id: String
    let selectedMediaPaths: Set<XMPExactFileSystemPath>
    let allMediaPaths: Set<XMPExactFileSystemPath>
    let category: XMPPublicationCategory
    let canonicalSource: XMPExactFileSystemPath?
    let canonicalSourceIdentity: FileOperationJournal.FileIdentity?
    let canonicalSourceDigest: Data?
    let finalPacket: Data?
    let applicationPackets: [XMPExportApplicationPacket]

    var allFamilyMediaSelected: Bool {
        allMediaPaths.isSubset(of: selectedMediaPaths)
    }
}

struct XMPExportPreparedPlan: Equatable, Sendable {
    let families: [XMPExportPreparedFamily]

    var issueFamilies: [XMPExportPreparedFamily] {
        families.filter { !$0.category.canPublish }
    }

    var familyByMediaPath: [XMPExactFileSystemPath: XMPExportPreparedFamily] {
        var result: [XMPExactFileSystemPath: XMPExportPreparedFamily] = [:]
        for family in families {
            for path in family.selectedMediaPaths { result[path] = family }
        }
        return result
    }
}

struct XMPPublicationPlan: Equatable, Sendable {
    let id = UUID()
    let publishableCount = 0
}

struct XMPPublicationResult: Equatable, Sendable {
    let cancelled = false
}

struct XMPPublicationInput: Sendable {
    let members: [Int]
    let selectedPhysicalFileCount: Int
    let selectedMediaPaths: Set<Int>

    init(
        items: [PhotoItem],
        familyContextItems: [PhotoItem]? = nil,
        sessionGeneration: UInt64 = 0,
        sourceFolder: URL? = nil,
        sourceFolderIdentity: SessionPersistence.SourceFolderIdentity? = nil,
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool = false
    ) throws {
        selectedPhysicalFileCount = items.reduce(0) {
            $0 + $1.individualFiles.count(where: { $0.mediaKind == .photo })
        }
        members = Array(0..<selectedPhysicalFileCount)
        selectedMediaPaths = Set(members)
    }
}

final class XMPPublicationCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum XMPPublicationPlanner {
    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    static func preflight(
        _ input: XMPPublicationInput,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping Progress
    ) async -> XMPPublicationPlan? {
        isCancelled() ? nil : XMPPublicationPlan()
    }
}

enum XMPPublicationWorker {
    typealias Progress = XMPPublicationPlanner.Progress

    static func publish(
        _ plan: XMPPublicationPlan,
        cancelFlag: XMPPublicationCancelFlag,
        progress: @escaping Progress
    ) async -> XMPPublicationResult {
        XMPPublicationResult()
    }
}
#endif

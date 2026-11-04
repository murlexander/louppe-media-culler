import Foundation

/// Folder navigation targets for one index, selection and progress revision.
struct ArchiveFolderTargets {
    let generation: UUID
    let selectedFolderID: String
    let progressRevision: Int
    let next: String?
    let previous: String?
    let nextUnfinished: String?
}

extension SessionStore {
    /// Cached so command enablement does not rescan folders per update.
    var archiveFolderTargets: ArchiveFolderTargets? {
        guard let index = archiveFolderIndex else { return nil }
        if let cached = archiveFolderTargetsCache, cached.generation == index.generation,
           cached.selectedFolderID == archiveSelectedFolderID,
           cached.progressRevision == archiveFolderProgressRevision { return cached }
        let selected = archiveSelectedFolderID
        let targets = ArchiveFolderTargets(generation: index.generation, selectedFolderID: selected,
            progressRevision: archiveFolderProgressRevision,
            next: archiveNextFolderID(after: selected), previous: archivePreviousFolderID(before: selected),
            nextUnfinished: archiveNextUnfinishedFolderID(after: selected))
        archiveFolderTargetsCache = targets
        return targets
    }

    /// `directories` is the index's prepared natural-sibling DFS order. These
    /// queries touch folders only, including when the current node has no media.
    func archiveNextFolderID(after id: String) -> String? {
        // Ordinals are the same pre-order as `directories`: O(1) lookup.
        guard let index = archiveFolderIndex, let position = index.ordinal(for: id) else { return nil }
        return index.directories.dropFirst(position + 1).first {
            !$0.id.isEmpty && (index.node(for: $0.id)?.directCount ?? 0) > 0
        }?.id
    }

    func archivePreviousFolderID(before id: String) -> String? {
        guard let index = archiveFolderIndex, let position = index.ordinal(for: id) else { return nil }
        return index.directories.prefix(position).reversed().first {
            !$0.id.isEmpty && (index.node(for: $0.id)?.directCount ?? 0) > 0
        }?.id
    }

    /// The next folder, in the same order as Next Folder, that still has a
    /// direct item without Yes or No. Folders finished earlier are skipped.
    func archiveNextUnfinishedFolderID(after id: String) -> String? {
        guard let index = archiveFolderIndex, let position = index.ordinal(for: id),
              let progress = archiveFolderProgress else { return nil }
        return index.directories.dropFirst(position + 1).first { directory in
            guard !directory.id.isEmpty, let node = index.node(for: directory.id), node.directCount > 0 else { return false }
            return progress.reviewedCount(for: directory.id, includesDescendants: false, index: index) < node.directCount
        }?.id
    }

    var canSelectNextUnfinishedArchiveFolder: Bool {
        canUseArchiveFolderCommands() && archiveFolderTargets?.nextUnfinished != nil
    }

    @discardableResult
    func selectNextUnfinishedArchiveFolder() -> Bool {
        guard canSelectNextUnfinishedArchiveFolder,
              let id = archiveFolderTargets?.nextUnfinished else { return false }
        selectArchiveFolder(id)
        return archiveSelectedFolderID == id
    }

    func canUseArchiveFolderCommands(allowingActionPalette: Bool = false) -> Bool {
        guard hasArchiveFolders, case .ready = phase,
              !isFileOperationRunning, !isSessionTransitioning, !isPreparingForTermination else { return false }
        return allowingActionPalette
            ? !isSessionCommandPresentationActiveExcludingActionPalette
            : !isSessionCommandPresentationActive
    }

    var canSelectNextArchiveFolder: Bool {
        canUseArchiveFolderCommands() && archiveFolderTargets?.next != nil
    }
    var canSelectPreviousArchiveFolder: Bool {
        canUseArchiveFolderCommands() && archiveFolderTargets?.previous != nil
    }
    var canSelectEnclosingArchiveFolder: Bool {
        canUseArchiveFolderCommands() && archiveFolderIndex?.node(for: archiveSelectedFolderID)?.parentID != nil
    }
    var canSelectAllArchiveMedia: Bool {
        canUseArchiveFolderCommands() && !archiveSelectedFolderID.isEmpty
    }
    var currentItemArchiveFolderID: String? {
        guard let id = currentItem?.primaryFile.id else { return nil }
        // Physical IDs use exact percent-encoded relative paths, just as the
        // index's physical-parent postings do. Never use the display path.
        let parent = id.lastIndex(of: "/").map { String(id[..<$0]) } ?? ""
        return archiveFolderIndex?.node(for: parent) == nil ? nil : parent
    }
    var canRevealCurrentItemArchiveFolder: Bool {
        canUseArchiveFolderCommands() && currentItemArchiveFolderID.map { $0 != archiveSelectedFolderID } == true
    }

    @discardableResult
    func selectNextArchiveFolder() -> Bool {
        guard canSelectNextArchiveFolder, let id = archiveFolderTargets?.next else { return false }
        selectArchiveFolder(id)
        return archiveSelectedFolderID == id
    }
    @discardableResult
    func selectPreviousArchiveFolder() -> Bool {
        guard canSelectPreviousArchiveFolder, let id = archiveFolderTargets?.previous else { return false }
        selectArchiveFolder(id)
        return archiveSelectedFolderID == id
    }
    @discardableResult
    func selectEnclosingArchiveFolder() -> Bool {
        guard canSelectEnclosingArchiveFolder,
              let parent = archiveFolderIndex?.node(for: archiveSelectedFolderID)?.parentID else { return false }
        selectArchiveFolder(parent)
        return archiveSelectedFolderID == parent
    }
    @discardableResult
    func revealCurrentItemArchiveFolder() -> Bool {
        guard canRevealCurrentItemArchiveFolder, let folder = currentItemArchiveFolderID,
              let physicalID = currentItem?.primaryFile.id else { return false }
        selectArchiveFolder(folder)
        guard archiveSelectedFolderID == folder else { return false }
        // Folder position memory may have selected a different item. Restore
        // this physical item through the prepared map, without walking media.
        clearSelection()
        if let index = archiveVisibleIndex(for: physicalID) { setIndex(index) }
        return currentItem?.primaryFile.id == physicalID
    }
}

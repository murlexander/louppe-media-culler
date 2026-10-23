import Foundation

/// Sparse exact-original export. One resource is staged, validated, copied by
/// the existing journaled worker, then released before requesting the next.
/// Earlier completed copies survive a later cloud/disk/cancellation failure.
enum PhotosCopyWorker {
    static func copy(_ items: [PhotoItem], sourceFolder: URL, destination: URL,
                     binding: DurableFileIO.DirectoryBinding,
                     journalDirectory: URL? = nil,
                     cancelFlag: ExportWorker.CancelFlag,
                     downloadProgress: @escaping @Sendable (Int, Int, Double) -> Void = { _, _, _ in },
                     progress: @escaping @Sendable (Int, Int) -> Void) async -> ExportWorker.CopyResult {
        var copied = 0
        var failed = 0
        var inconsistent = 0
        var message: String?
        var journalFailure = false
        var recovery = false
        for (index, item) in items.enumerated() {
            if Task.isCancelled || cancelFlag.isSet { break }
            do {
                guard let reference = item.primaryFile.photosMedia else { throw PhotosRepresentationError.unavailable }
                let lease = try await reference.session.original(for: item) { fraction in
                    downloadProgress(index, items.count, fraction)
                }
                let result: ExportWorker.CopyResult
                do {
                    try Task.checkCancellation()
                    try binding.requireCurrentPath()
                    _ = try ExportDestinationValidator.validateBound(sourceFolder: sourceFolder,
                        destination: destination, items: [lease.item], mode: .copy)
                    let original = lease.item
                    result = await Task.detached(priority: .userInitiated) {
                        ExportWorker.copy([original], to: destination, destinationBinding: binding,
                            journalDirectory: journalDirectory,
                            isCancelled: { cancelFlag.isSet }, cancellationReason: { cancelFlag.reason },
                            progress: { _, _ in })
                    }.value
                } catch { await lease.close(); throw error }
                // Keep the source of unresolved journals intact for recovery.
                // Completed/staged destination files have worker-owned proof.
                if result.requiresRecovery { lease.preserveForRecovery() }
                else { await lease.close() }
                copied += result.copiedFiles; failed += result.failedPhotos
                inconsistent += result.inconsistentPhotos
                message = message ?? result.failureMessage
                journalFailure = result.journalFailure; recovery = result.requiresRecovery
                progress(index + 1, items.count)
                if result.cancelled || journalFailure || recovery || result.failedPhotos > 0 { break }
            } catch is CancellationError { break }
            catch { failed += 1; message = error.localizedDescription; break }
        }
        let cancelled = Task.isCancelled || cancelFlag.isSet
        if !cancelled && copied < items.count { failed = max(failed, items.count - copied) }
        return ExportWorker.CopyResult(copiedFiles: copied, failedPhotos: failed,
            inconsistentPhotos: inconsistent, cancelled: cancelled,
            cancellationReason: cancelled ? (cancelFlag.reason ?? .unrecorded) : nil,
            journalFailure: journalFailure, requiresRecovery: recovery,
            failureMessage: message, xmpSummary: nil)
    }
}

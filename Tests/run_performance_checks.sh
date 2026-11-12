#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/Scripts/lib/xcode_env.sh"
optimization=()
snapshot_only=0
for option in "$@"; do
    case "$option" in
        --optimized) optimization=(-O) ;;
        --snapshot-only) snapshot_only=1 ;;
        *) echo "Usage: $0 [--optimized] [--snapshot-only]" >&2; exit 2 ;;
    esac
done

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

mkdir -p .build/performance-checks/module-cache

swiftc "${optimization[@]}" \
    -sdk "$SDK" \
    -module-cache-path .build/performance-checks/module-cache \
    -D LOUPPE_TESTING \
    -parse-as-library \
    Sources/Louppe/Localization.swift \
    Sources/Louppe/Models.swift \
    Sources/Louppe/XMP/XMPExactFileSystemPath.swift \
    Sources/Louppe/PreparedSessionIndex.swift \
    Sources/Louppe/SelectionState.swift \
    Sources/Louppe/AppDateFormat.swift \
    Sources/Louppe/ForegroundWorkCoordinator.swift \
    Sources/Louppe/ArchiveMetadataIndex.swift \
    Sources/Louppe/PinnedFolders.swift \
    Sources/Louppe/PinnedFolderPreparation.swift \
    Sources/Louppe/SessionOpeningMetadata.swift \
    Sources/Louppe/FolderScanner.swift \
    Sources/Louppe/ArchiveFolderIndex.swift \
    Sources/Louppe/ArchiveFolderProgress.swift \
    Sources/Louppe/MetadataExtractor.swift \
    Sources/Louppe/FujiFilmSimulation.swift \
    Sources/Louppe/VideoSupport.swift \
    Sources/Louppe/RawDisplay.swift \
    Sources/Louppe/MediaReadAccess.swift \
    Sources/Louppe/ImagePipeline.swift \
    Sources/Louppe/HistogramPipeline.swift \
    Sources/Louppe/CameraQualityWarnings.swift \
    Sources/Louppe/QualityCueAnalysis.swift \
    Sources/Louppe/QualityCueWorkPolicy.swift \
    Sources/Louppe/HighResolutionImagePipeline.swift \
    Sources/Louppe/ZoomViewport.swift \
    Sources/Louppe/VideoPlaybackController.swift \
    Sources/Louppe/DurableFileIO.swift \
    Sources/Louppe/SourceOrganizationStorageSafety.swift \
    Sources/Louppe/FileOperationJournal.swift \
    Sources/Louppe/DuplicateBurstAnalysis.swift \
    Sources/Louppe/CleanUpWorker.swift \
    Sources/Louppe/ExportWorker.swift \
    Sources/Louppe/ExportDestinationValidator.swift \
    Sources/Louppe/FileRenaming.swift \
    Sources/Louppe/SourceOrganization.swift \
    Sources/Louppe/SourceOrganizationWorker.swift \
    Sources/Louppe/SecurityScopedAccess.swift \
    Sources/Louppe/SessionPersistence.swift \
    Sources/Louppe/SessionRatingRecovery.swift \
    Tests/PerformanceChecks/XMPPublicationStubs.swift \
    Sources/Louppe/XMP/XMPSidecarResolver.swift \
    Sources/Louppe/ReviewPreferences.swift \
    Sources/Louppe/SessionOpeningMetrics.swift \
    Sources/Louppe/OpeningSessionState.swift \
    Sources/Louppe/SessionOpeningFacets.swift \
    Sources/Louppe/SessionOpeningRestoration.swift \
    Sources/Louppe/PhotosReviewDecisions.swift \
    Sources/Louppe/PhotosLibrary.swift \
    Sources/Louppe/PhotosMedia.swift \
    Sources/Louppe/PhotosNetworkPreferences.swift \
    Sources/Louppe/PhotosLibraryBrowser.swift \
    Sources/Louppe/PhotosLibraryOrganization.swift \
    Sources/Louppe/PhotosOrganizationPresentation.swift \
    Sources/Louppe/SessionOpeningWorker.swift \
    Sources/Louppe/SessionStore.swift \
    Sources/Louppe/SessionStore+ArchiveNavigation.swift \
    Sources/Louppe/SessionStore+ArchiveFolderCommands.swift \
    Sources/Louppe/ArchiveNavigationMemory.swift \
    Tests/PerformanceChecks/main.swift \
    -o .build/performance-checks/LouppePerformanceChecks

if (( snapshot_only )); then
    lock="$HOME/.louppe-perf/measure.lock"
    mkdir -p "$(dirname "$lock")"
    if [[ -e "$lock" ]]; then echo "Waiting for snapshot measurement lock: $lock"; fi
    until mkdir "$lock" 2>/dev/null; do sleep 1; done
    trap 'rmdir "$lock"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    export LOUPPE_SNAPSHOT_REPETITIONS="${LOUPPE_SNAPSHOT_REPETITIONS:-7}"
    [[ "$LOUPPE_SNAPSHOT_REPETITIONS" == <-> ]] \
        && (( LOUPPE_SNAPSHOT_REPETITIONS >= 1 && LOUPPE_SNAPSHOT_REPETITIONS <= 30 )) \
        || { echo 'Snapshot repetitions must be 1–30.' >&2; exit 2; }
fi
.build/performance-checks/LouppePerformanceChecks

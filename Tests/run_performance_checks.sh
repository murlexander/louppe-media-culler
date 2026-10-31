#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

mkdir -p .build/performance-checks/module-cache

swiftc \
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

.build/performance-checks/LouppePerformanceChecks

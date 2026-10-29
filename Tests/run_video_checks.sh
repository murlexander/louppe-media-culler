#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p .build/video-checks/module-cache

swiftc \
    -sdk "$SDK" \
    -module-cache-path .build/video-checks/module-cache \
    -D LOUPPE_TESTING \
    -parse-as-library \
    Sources/Louppe/XMP/XMPExactFileSystemPath.swift \
    Sources/Louppe/DurableFileIO.swift \
    Sources/Louppe/SourceOrganizationStorageSafety.swift \
    Sources/Louppe/FileOperationJournal.swift \
    Sources/Louppe/Localization.swift \
    Sources/Louppe/Models.swift \
    Tests/VideoChecks/PhotosMediaStub.swift \
    Sources/Louppe/AppDateFormat.swift \
    Sources/Louppe/SessionOpeningMetrics.swift \
    Sources/Louppe/SessionPersistence.swift \
    Sources/Louppe/ForegroundWorkCoordinator.swift \
    Sources/Louppe/ArchiveMetadataIndex.swift \
    Sources/Louppe/SessionOpeningMetadata.swift \
    Sources/Louppe/FolderScanner.swift \
    Sources/Louppe/MetadataExtractor.swift \
    Sources/Louppe/FujiFilmSimulation.swift \
    Sources/Louppe/VideoSupport.swift \
    Sources/Louppe/RawDisplay.swift \
    Sources/Louppe/SecurityScopedAccess.swift \
    Sources/Louppe/MediaReadAccess.swift \
    Sources/Louppe/ImagePipeline.swift \
    Sources/Louppe/VideoPlaybackController.swift \
    Tests/VideoChecks/main.swift \
    -o .build/video-checks/LouppeVideoChecks

.build/video-checks/LouppeVideoChecks

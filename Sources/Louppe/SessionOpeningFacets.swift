import Foundation

/// Immutable counts, filter facets and ranges, prepared before UI publication.
/// The ordinary structural rebuild uses the same calculation on the main actor.
struct SessionOpeningFacets: Sendable {
    let ratingTally: (yes: Int, no: Int, undecided: Int)
    let mixedRatingCount: Int
    let starTally: [StarRating: Int]
    let unratedStarCountStorage: Int
    let mixedStarCountStorage: Int
    let colorTally: [PhotoColorLabel: Int]
    let noColorCountStorage: Int
    let mixedColorCountStorage: Int
    let typeCounts: [String: Int]
    let mediaKindCounts: [MediaKind: Int]
    let cameraCounts: [String: Int]
    let lensCounts: [String: Int]
    let filmSimulationCounts: [FujiFilmSimulation: Int]
    let availableFilmSimulations: [FujiFilmSimulation]
    let videoResolutionCounts: [String: Int]
    let videoCodecCounts: [String: Int]
    let subfolderCounts: [String: Int]
    let availableTypes: [String]
    let availableMediaKinds: [MediaKind]
    let availableCameras: [String]
    let availableLenses: [String]
    let availableSubfolders: [String]
    let availableCaptureDates: [Date]
    let captureDateCounts: [Date: Int]
    let unknownDateCount: Int
    let captureDateRange: ClosedRange<Date>?
    let apertureRange: ClosedRange<Double>?
    let shutterRange: ClosedRange<Double>?
    let isoRange: ClosedRange<Double>?
    let durationRange: ClosedRange<Double>?
    let videoFrameRateRange: ClosedRange<Double>?

    init(items: [PhotoItem], isCancelled: @Sendable () -> Bool = { false }) {
        var tally = (yes: 0, no: 0, undecided: 0)
        var mixed = 0
        var stars: [StarRating: Int] = [:]
        var unratedStars = 0
        var mixedStars = 0
        var colors: [PhotoColorLabel: Int] = [:]
        var noColor = 0
        var mixedColors = 0
        var types: [String: Int] = [:]
        var mediaKinds: [MediaKind: Int] = [:]
        var cameras: [String: Int] = [:]
        var lenses: [String: Int] = [:]
        var filmSimulations: [FujiFilmSimulation: Int] = [:]
        var hasFujiMetadata = false
        var videoResolutions: [String: Int] = [:]
        var videoCodecs: [String: Int] = [:]
        var subfolders: [String: Int] = [:]
        var dates: [Date: Int] = [:]
        var unknownDates = 0
        var minimumAperture: Double?
        var maximumAperture: Double?
        var minimumShutter: Double?
        var maximumShutter: Double?
        var minimumISO: Double?
        var maximumISO: Double?
        var minimumDuration: Double?
        var maximumDuration: Double?
        var minimumVideoFrameRate: Double?
        var maximumVideoFrameRate: Double?
        for item in items {
            if isCancelled() { break }
            let metadata = item.metadataState
            // Keep the three public counts exhaustive: mixed pairs are
            // unresolved and therefore included in `undecidedCount`.
            switch metadata.decision {
            case .yes:
                tally.yes += 1
            case .no:
                tally.no += 1
            case .undecided:
                tally.undecided += 1
            case .mixed:
                tally.undecided += 1
                mixed += 1
            }
            switch metadata.stars {
            case .unrated: unratedStars += 1
            case .stars(let rating): stars[rating, default: 0] += 1
            case .mixed: mixedStars += 1
            }
            switch metadata.color {
            case .none: noColor += 1
            case .label(let label): colors[label, default: 0] += 1
            case .mixed: mixedColors += 1
            }
            types[item.fileTypeLabel, default: 0] += 1
            mediaKinds[item.mediaKind, default: 0] += 1
            cameras[item.cameraLabel, default: 0] += 1
            lenses[item.lensLabel, default: 0] += 1
            filmSimulations[item.filmSimulationFacet, default: 0] += 1
            hasFujiMetadata = hasFujiMetadata || item.filmSimulation != nil
            subfolders[item.subfolderLabel, default: 0] += 1
            if let day = item.captureDay {
                dates[day, default: 0] += 1
            } else {
                unknownDates += 1
            }
            if let aperture = item.aperture {
                minimumAperture = minimumAperture.map { min($0, aperture) } ?? aperture
                maximumAperture = maximumAperture.map { max($0, aperture) } ?? aperture
            }
            if let shutter = item.shutterSpeed {
                minimumShutter = minimumShutter.map { min($0, shutter) } ?? shutter
                maximumShutter = maximumShutter.map { max($0, shutter) } ?? shutter
            }
            if let iso = item.iso {
                minimumISO = minimumISO.map { min($0, iso) } ?? iso
                maximumISO = maximumISO.map { max($0, iso) } ?? iso
            }
            if let duration = item.duration, duration.isFinite, duration >= 0 {
                minimumDuration = minimumDuration.map { min($0, duration) } ?? duration
                maximumDuration = maximumDuration.map { max($0, duration) } ?? duration
            }
            if item.isVideo {
                videoResolutions[
                    item.videoResolutionLabel ?? "Unknown resolution",
                    default: 0
                ] += 1
                videoCodecs[item.videoCodec ?? "Unknown video codec", default: 0] += 1
                if let frameRate = item.videoFrameRate,
                   frameRate.isFinite,
                   frameRate > 0 {
                    minimumVideoFrameRate = minimumVideoFrameRate.map {
                        min($0, frameRate)
                    } ?? frameRate
                    maximumVideoFrameRate = maximumVideoFrameRate.map {
                        max($0, frameRate)
                    } ?? frameRate
                }
            }
        }
        ratingTally = tally
        mixedRatingCount = mixed
        starTally = stars
        unratedStarCountStorage = unratedStars
        mixedStarCountStorage = mixedStars
        colorTally = colors
        noColorCountStorage = noColor
        mixedColorCountStorage = mixedColors
        typeCounts = types
        mediaKindCounts = mediaKinds
        cameraCounts = cameras
        lensCounts = lenses
        filmSimulationCounts = filmSimulations
        availableFilmSimulations = hasFujiMetadata ? filmSimulations.keys.sorted {
            if $0 == .notRecorded { return false }
            if $1 == .notRecorded { return true }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        } : []
        videoResolutionCounts = videoResolutions
        videoCodecCounts = videoCodecs
        subfolderCounts = subfolders
        availableTypes = types.keys.sorted()
        availableMediaKinds = [.photo, .video, .audio, .text].filter {
            mediaKinds[$0] != nil
        }
        availableCameras = cameras.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        availableLenses = lenses.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // "None" (the folder root) always lists last, like the date list's
        // "Unknown date" entry.
        var subfolderLabels = subfolders.keys
            .filter { $0 != "None" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if subfolders["None"] != nil { subfolderLabels.append("None") }
        availableSubfolders = subfolderLabels
        let sortedDates = dates.keys.sorted()
        availableCaptureDates = sortedDates
        captureDateCounts = dates
        unknownDateCount = unknownDates
        captureDateRange = sortedDates.first.flatMap { first in
            sortedDates.last.map { first...$0 }
        }
        apertureRange = Self.closedRange(minimum: minimumAperture, maximum: maximumAperture)
        shutterRange = Self.closedRange(minimum: minimumShutter, maximum: maximumShutter)
        isoRange = Self.closedRange(minimum: minimumISO, maximum: maximumISO)
        durationRange = Self.closedRange(minimum: minimumDuration, maximum: maximumDuration)
        videoFrameRateRange = Self.closedRange(
            minimum: minimumVideoFrameRate,
            maximum: maximumVideoFrameRate
        )
    }

    private static func closedRange(minimum: Double?, maximum: Double?) -> ClosedRange<Double>? {
        guard let minimum, let maximum else { return nil }
        return minimum...maximum
    }
}

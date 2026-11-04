import Foundation
final class FilterStoreStub {
    var apertureRange: ClosedRange<Double>? = nil
    var shutterRange: ClosedRange<Double>? = nil
    var isoRange: ClosedRange<Double>? = nil
    var durationRange: ClosedRange<Double>? = 5...30
    var videoFrameRateRange: ClosedRange<Double>? = nil
    var filter = PhotoFilter()
}
final class FilterAudit {
    private let store = FilterStoreStub()
    private var apertureFromText = ""
    private var apertureToText = ""
    private var shutterFromText = ""
    private var shutterToText = ""
    private var isoFromText = ""
    private var isoToText = ""
    private var durationFromText = ""
    private var durationToText = ""
    private var videoFrameRateFromText = ""
    private var videoFrameRateToText = ""
    func probe() {
        store.filter.durationEnabled = true
        store.filter.durationFrom = 10.2
        store.filter.durationTo = 20.8
        print("BEFORE_POPUP: \(store.filter.durationFrom)...\(store.filter.durationTo)")
        syncAllSettingDrafts()
        print("SYNCED_DRAFTS: \(durationFromText)...\(durationToText)")
        commitAllSettingDrafts()
        print("AFTER_NO_EDIT_CLOSE: \(store.filter.durationFrom)...\(store.filter.durationTo)")
    }
    private var apertureDraftIsValid: Bool {
        guard let from = Self.parseAperture(apertureFromText),
              let to = Self.parseAperture(apertureToText) else { return false }
        return from <= to
    }

    private var shutterDraftIsValid: Bool {
        guard let from = Self.parseShutter(shutterFromText),
              let to = Self.parseShutter(shutterToText) else { return false }
        return from <= to
    }

    private var isoDraftIsValid: Bool {
        guard let from = Self.parseISO(isoFromText),
              let to = Self.parseISO(isoToText) else { return false }
        return from <= to
    }

    private var durationDraftIsValid: Bool {
        guard let from = Self.parseDuration(durationFromText),
              let to = Self.parseDuration(durationToText) else { return false }
        return from <= to
    }

    private var videoFrameRateDraftIsValid: Bool {
        guard let from = Self.parseVideoFrameRate(videoFrameRateFromText),
              let to = Self.parseVideoFrameRate(videoFrameRateToText)
        else { return false }
        return from <= to
    }

    private func commitApertureDrafts(to filter: inout PhotoFilter) {
        guard let available = store.apertureRange,
              let parsedFrom = Self.parseAperture(apertureFromText),
              let parsedTo = Self.parseAperture(apertureToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapAperture(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapAperture(parsedTo, toDisplayedBound: available.upperBound)
        filter.apertureFrom = from
        filter.apertureTo = to
        filter.apertureEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func commitShutterDrafts(to filter: inout PhotoFilter) {
        guard let available = store.shutterRange,
              let parsedFrom = Self.parseShutter(shutterFromText),
              let parsedTo = Self.parseShutter(shutterToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapShutter(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapShutter(parsedTo, toDisplayedBound: available.upperBound)
        filter.shutterFrom = from
        filter.shutterTo = to
        filter.shutterEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func commitISODrafts(to filter: inout PhotoFilter) {
        guard let available = store.isoRange,
              let parsedFrom = Self.parseISO(isoFromText),
              let parsedTo = Self.parseISO(isoToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapISO(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapISO(parsedTo, toDisplayedBound: available.upperBound)
        filter.isoFrom = from
        filter.isoTo = to
        filter.isoEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func commitDurationDrafts(to filter: inout PhotoFilter) {
        guard let available = store.durationRange,
              let parsedFrom = Self.parseDuration(durationFromText),
              let parsedTo = Self.parseDuration(durationToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapDuration(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapDuration(parsedTo, toDisplayedBound: available.upperBound)
        filter.durationFrom = from
        filter.durationTo = to
        filter.durationEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func commitVideoFrameRateDrafts(to filter: inout PhotoFilter) {
        guard let available = store.videoFrameRateRange,
              let parsedFrom = Self.parseVideoFrameRate(videoFrameRateFromText),
              let parsedTo = Self.parseVideoFrameRate(videoFrameRateToText),
              parsedFrom <= parsedTo
        else { return }
        let from = Self.snapVideoFrameRate(
            parsedFrom,
            toDisplayedBound: available.lowerBound
        )
        let to = Self.snapVideoFrameRate(
            parsedTo,
            toDisplayedBound: available.upperBound
        )
        filter.videoFrameRateFrom = from
        filter.videoFrameRateTo = to
        filter.videoFrameRateEnabled = from != available.lowerBound
            || to != available.upperBound
    }

    private func syncAllSettingDrafts() {
        if let range = store.apertureRange {
            let from = store.filter.apertureFrom > 0 ? store.filter.apertureFrom : range.lowerBound
            let to = store.filter.apertureTo > 0 ? store.filter.apertureTo : range.upperBound
            apertureFromText = Self.formatDecimal(from)
            apertureToText = Self.formatDecimal(to)
        }
        if let range = store.shutterRange {
            let from = store.filter.shutterFrom > 0 ? store.filter.shutterFrom : range.lowerBound
            let to = store.filter.shutterTo > 0 ? store.filter.shutterTo : range.upperBound
            shutterFromText = Self.formatShutter(from)
            shutterToText = Self.formatShutter(to)
        }
        if let range = store.isoRange {
            let from = store.filter.isoFrom > 0 ? store.filter.isoFrom : range.lowerBound
            let to = store.filter.isoTo > 0 ? store.filter.isoTo : range.upperBound
            isoFromText = Self.formatISO(from)
            isoToText = Self.formatISO(to)
        }
        if let range = store.durationRange {
            let from = store.filter.durationEnabled ? store.filter.durationFrom : range.lowerBound
            let to = store.filter.durationEnabled ? store.filter.durationTo : range.upperBound
            durationFromText = Self.formatDuration(from)
            durationToText = Self.formatDuration(to)
        }
        if let range = store.videoFrameRateRange {
            let from = store.filter.videoFrameRateEnabled
                ? store.filter.videoFrameRateFrom : range.lowerBound
            let to = store.filter.videoFrameRateEnabled
                ? store.filter.videoFrameRateTo : range.upperBound
            videoFrameRateFromText = Self.formatVideoFrameRate(from)
            videoFrameRateToText = Self.formatVideoFrameRate(to)
        }
    }

    private func commitAllSettingDrafts() {
        var updated = store.filter
        commitApertureDrafts(to: &updated)
        commitShutterDrafts(to: &updated)
        commitISODrafts(to: &updated)
        commitDurationDrafts(to: &updated)
        commitVideoFrameRateDrafts(to: &updated)
        if updated != store.filter {
            // One assignment means one pass across the photo list even if
            // several camera-setting fields changed before the debounce fired.
            store.filter = updated
        }
    }

    private static func parseAperture(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasPrefix("f/") { value.removeFirst(2) }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func parseShutter(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasSuffix("s") { value.removeLast() }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        let seconds: Double?
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            seconds = numerator / denominator
        } else if components.count == 1 {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func parseISO(_ text: String) -> Double? {
        guard let number = Double(normalizedNumberText(text)),
              number.isFinite,
              number > 0,
              number.rounded() == number else { return nil }
        return number
    }

    private static func parseDuration(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasSuffix("s") { value.removeLast() }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        let seconds: Double?
        switch fields.count {
        case 1:
            seconds = Double(fields[0])
        case 2:
            if let minutes = Double(fields[0]), minutes >= 0,
               let remainder = Double(fields[1]), remainder >= 0, remainder < 60 {
                seconds = minutes * 60 + remainder
            } else {
                seconds = nil
            }
        case 3:
            if let hours = Double(fields[0]), hours >= 0,
               let minutes = Double(fields[1]), minutes >= 0, minutes < 60,
               let remainder = Double(fields[2]), remainder >= 0, remainder < 60 {
                seconds = hours * 3600 + minutes * 60 + remainder
            } else {
                seconds = nil
            }
        default:
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func parseVideoFrameRate(_ text: String) -> Double? {
        guard let value = Double(normalizedNumberText(text)),
              MediaNumeric.frameRate(value) != nil
        else { return nil }
        return value
    }

    private static func normalizedNumberText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
    }

    private static func formatDecimal(_ value: Double) -> String {
        MetadataFormat.decimal(value)
    }

    private static func formatShutter(_ seconds: Double) -> String {
        MetadataFormat.shutter(seconds)
    }

    private static func formatISO(_ value: Double) -> String {
        MetadataFormat.iso(value)
    }

    private static func formatDuration(_ value: Double) -> String {
        MediaDurationFormat.display(value)
    }

    private static func formatVideoFrameRate(_ value: Double) -> String {
        VideoMetadataFormat.frameRate(value)
            .replacingOccurrences(of: " fps", with: "")
    }

    /// Display formatting rounds some legal EXIF values. If the user-entered
    /// value equals what a folder bound displays, retain the exact bound so a
    /// neutral full range cannot accidentally exclude its edge photo.
    private static func snapAperture(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseAperture(formatDecimal(bound)) == value ? bound : value
    }

    private static func snapShutter(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseShutter(formatShutter(bound)) == value ? bound : value
    }

    private static func snapISO(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseISO(formatISO(bound)) == value ? bound : value
    }

    private static func snapDuration(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseDuration(formatDuration(bound)) == value ? bound : value
    }

    private static func snapVideoFrameRate(
        _ value: Double,
        toDisplayedBound bound: Double
    ) -> Double {
        parseVideoFrameRate(formatVideoFrameRate(bound)) == value ? bound : value
    }

}
@main struct AuditFilter { static func main() { FilterAudit().probe() } }

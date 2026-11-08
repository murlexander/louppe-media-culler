import Foundation

/// Single source of truth for how dates and times are displayed anywhere in
/// the app: the info panel, selection summaries, filter day lists, and group
/// headers.
///
/// Formatting follows the Mac's settings (System Settings > General >
/// Language & Region / Date & Time), including the user's custom "Date
/// format" picker. That picker stores a per-style override
/// (`AppleICUDateFormatStrings`) which only style-based formatters honor —
/// `setLocalizedDateFormatFromTemplate` silently ignores it and falls back
/// to the region default — so the formatters below must be configured via
/// `dateStyle`/`timeStyle`, never via templates or explicit patterns. If an
/// in-app date format setting ever lands, only this file needs to change:
/// no call site should ever build its own display DateFormatter.
enum AppDateFormat {
    /// e.g. "2026.07.11"
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// e.g. "2026.07.11, 2:32 PM" (12/24-hour clock per system setting)
    static func dayAndTime(_ date: Date) -> String {
        dayAndTimeFormatter.string(from: date)
    }

    /// e.g. "2023.03.28 – 2026.07.11". Composed from two `day` strings so
    /// both ends always render the full, identical pattern.
    static func dayRange(from start: Date, to end: Date) -> String {
        "\(day(start)) – \(day(end))"
    }

    /// Folder date labels for Source Organization. The full-date value uses
    /// `day(_:)` directly. These shorter granularities derive their order,
    /// field widths, and separator from that style formatter's effective
    /// pattern instead of imposing an app-specific yyyy-MM convention.
    static func yearAndMonth(_ date: Date) -> String {
        yearAndMonthFormatter.string(from: date)
    }

    static func year(_ date: Date) -> String {
        yearFormatter.string(from: date)
    }

    /// A whole year for the filter's year list, e.g. "2024", in the calendar
    /// that produced `CaptureYear`. Unlike `year(Date)`, this never inherits a
    /// short style's two-digit year.
    static func year(_ year: CaptureYear) -> String {
        format(year, with: fullYearFormatter)
    }

    static func year(_ year: CaptureYear, calendar: Calendar, locale: Locale) -> String {
        format(year, with: makeFullYearFormatter(calendar: calendar, locale: locale))
    }

    private static func format(_ year: CaptureYear, with formatter: DateFormatter) -> String {
        guard let calendar = formatter.calendar,
              let date = year.representativeDate(in: calendar) else { return String(year.year) }
        return formatter.string(from: date)
    }

    /// Built once per launch; a mid-session change to the Mac's region
    /// settings needs a relaunch. Deliberately NOT the POSIX locale used for
    /// EXIF parsing: display formatting should follow the user's system,
    /// fixed-format parsing must not. The short styles are what the System
    /// Settings pickers customize.
    private static func makeFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    private static let dayFormatter = makeFormatter(dateStyle: .short, timeStyle: .none)
    private static let dayAndTimeFormatter = makeFormatter(dateStyle: .short, timeStyle: .short)

    private static let yearAndMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = dayFormatter.calendar
        formatter.timeZone = dayFormatter.timeZone
        formatter.dateFormat = yearAndMonthPattern(
            from: dayFormatter.dateFormat
                ?? DateFormatter.dateFormat(
                    fromTemplate: "yMd",
                    options: 0,
                    locale: .current
                )
                ?? "y-MM-dd"
        )
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = dayFormatter.calendar
        formatter.timeZone = dayFormatter.timeZone
        formatter.dateFormat = yearField(
            in: dayFormatter.dateFormat ?? "y"
        ) ?? "y"
        return formatter
    }()

    /// Matches `PhotoFile.captureYear`, which uses `Calendar.current`.
    private static let fullYearFormatter = makeFullYearFormatter(calendar: .current, locale: .current)

    /// "y" is the unpadded full year in the calendar's digits. Japanese era
    /// years repeat (Heisei 6, Reiwa 6), so that calendar also shows the era.
    private static func makeFullYearFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch calendar.identifier {
        case .japanese:
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "Gy", options: 0, locale: locale) ?? "G y"
        case let id where isCyclic(id):
            // Cyclic years repeat every 60 years; "r" (related Gregorian
            // year) keeps them distinct, e.g. "1964(jia-chen)".
            var components = Locale.Components(locale: locale)
            components.calendar = calendar.identifier
            let pattern = DateFormatter.dateFormat(
                fromTemplate: "rU", options: 0, locale: Locale(components: components)) ?? "r(U)"
            formatter.dateFormat = pattern.contains("r") ? pattern : "r " + pattern
        default:
            formatter.dateFormat = "y"
        }
        return formatter
    }

    private static func isCyclic(_ identifier: Calendar.Identifier) -> Bool {
        if identifier == .chinese { return true }
        if #available(macOS 26.0, *) { return identifier == .dangi }
        return false
    }

    /// Only style-based DateFormatters honor macOS's custom Date format
    /// picker. Read that resolved pattern, then keep its year/month spelling
    /// and punctuation for the shorter folder label.
    private static func yearAndMonthPattern(from pattern: String) -> String {
        let fields = dateFields(in: pattern)
        guard let year = fields.first(where: { "yYuUr".contains($0.symbol) }),
              let month = fields.first(where: { "ML".contains($0.symbol) }) else {
            return "y-MM"
        }
        let ordered = [year, month].sorted {
            $0.range.lowerBound < $1.range.lowerBound
        }
        let separator = preferredDateSeparator(
            in: pattern,
            fields: fields,
            between: ordered[0],
            and: ordered[1]
        )
        return String(pattern[ordered[0].range])
            + separator
            + String(pattern[ordered[1].range])
    }

    private static func yearField(in pattern: String) -> String? {
        dateFields(in: pattern)
            .first(where: { "yYuUr".contains($0.symbol) })
            .map { String(pattern[$0.range]) }
    }

    private struct PatternField {
        let symbol: Character
        let range: Range<String.Index>
    }

    private static func dateFields(in pattern: String) -> [PatternField] {
        var result: [PatternField] = []
        var index = pattern.startIndex
        var quoted = false
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "'" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "'" {
                    index = pattern.index(after: next)
                    continue
                }
                quoted.toggle()
                index = next
                continue
            }
            guard !quoted, character.isLetter else {
                index = pattern.index(after: index)
                continue
            }
            let start = index
            index = pattern.index(after: index)
            while index < pattern.endIndex, pattern[index] == character {
                index = pattern.index(after: index)
            }
            result.append(PatternField(
                symbol: character,
                range: start..<index
            ))
        }
        return result
    }

    private static func preferredDateSeparator(
        in pattern: String,
        fields: [PatternField],
        between first: PatternField,
        and second: PatternField
    ) -> String {
        let ordered = fields.sorted {
            $0.range.lowerBound < $1.range.lowerBound
        }
        guard let firstIndex = ordered.firstIndex(where: {
                  $0.range == first.range
              }),
              let secondIndex = ordered.firstIndex(where: {
                  $0.range == second.range
              }) else { return "." }
        let lower = min(firstIndex, secondIndex)
        let upper = max(firstIndex, secondIndex)
        for index in lower..<upper {
            let left = ordered[index]
            let right = ordered[index + 1]
            let literal = String(
                pattern[left.range.upperBound..<right.range.lowerBound]
            )
            if !literal.isEmpty { return literal }
        }
        return "."
    }
}

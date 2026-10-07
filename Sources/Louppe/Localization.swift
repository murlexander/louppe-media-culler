import Foundation

/// Presentation only. English keys never replace stored identifiers, XMP values,
/// filename recipes, or keyboard equivalents. Each message is translated as a
/// whole; numbered interpolation slots let translators reorder its arguments.
enum L10n {
    static let supportedLanguages = ["en", "es", "zh-Hans", "hi", "pt", "ar"]
    static let language = language(for: Locale.preferredLanguages)
    static let locale = Locale(identifier: language)
    static var isRightToLeft: Bool { language == "ar" }

    static func language(for preferences: [String]) -> String {
        for preference in preferences {
            let tag = preference.replacingOccurrences(of: "_", with: "-").lowercased()
            let base = tag.split(separator: "-").first.map(String.init) ?? tag
            if base == "zh" {
                // Do not present Simplified Chinese as a Traditional translation.
                if tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo") { continue }
                return "zh-Hans"
            }
            if ["en", "es", "hi", "pt", "ar"].contains(base) { return base }
        }
        return "en"
    }

    #if LOUPPE_TESTING
    // The standalone regression harnesses intentionally have no SwiftPM bundle.
    static let resourceBundle = Bundle.main
    #else
    static let resourceBundle: Bundle = {
        // SwiftPM's native accessor searches beside the executable and embeds
        // a development-path fallback. A packaged app owns resources here.
        if let resources = Bundle.main.resourceURL,
           let bundled = Bundle(url: resources.appendingPathComponent("Louppe_Louppe.bundle")) {
            return bundled
        }
        return Bundle.module
    }()
    #endif

    private static let languageBundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: supportedLanguages.compactMap { language in
            guard let root = resourceBundle.resourceURL,
                  let bundle = Bundle(url: root.appendingPathComponent(language.lowercased() + ".lproj")) else { return nil }
            return (language, bundle)
        })
    }()

    static func text(_ message: Message) -> String {
        render(message, language: language)
    }

    /// For explicitly identified display labels whose English spelling also
    /// belongs to a persisted enum or metadata field. Never pass filenames here.
    static func label(_ english: String) -> String {
        render(Message(stringLiteral: english), language: language)
    }

    static func render(_ message: Message, language: String) -> String {
        let translated = languageBundles[language]?.localizedString(
            forKey: message.key, value: message.key, table: "Localizable"
        ) ?? message.key
        let slots = placeholders(in: translated)
        let expected = placeholders(in: message.key)
        // A damaged/incomplete translation cannot drop safety details or values.
        let template = slots == expected ? translated : message.key
        // Scan the template once. Never interpret braces inside inserted filenames
        // or error descriptions as another slot; these values remain byte-for-byte.
        var output = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{",
               let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]),
               message.arguments.indices.contains(index) {
                output += message.arguments[index]
                cursor = template.index(after: end)
            } else {
                output.append(template[cursor])
                cursor = template.index(after: cursor)
            }
        }
        return output
    }

    private static let placeholderExpression = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    static func placeholders(in value: String) -> [Int: Int] {
        let expression = placeholderExpression
        var result: [Int: Int] = [:]
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            if let range = Range(match.range(at: 1), in: value), let slot = Int(value[range]) {
                result[slot, default: 0] += 1
            }
        }
        return result
    }

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []

            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            mutating func appendLiteral(_ literal: String) { key += literal }

            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }
}

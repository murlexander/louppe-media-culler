import Foundation

/// App preferences never enter folder-bound session snapshots. UserDefaults
/// uses the current bundle's domain, keeping a separate review app isolated.
struct ReviewPreferences: Equatable, Sendable {
    enum Keys {
        static let advancesAfterDecision = "review.advancesAfterDecision"
        static let defaultSortKey = "review.defaultSortKey"
        static let defaultSortAscending = "review.defaultSortAscending"
        static let isGroupingEnabled = "review.defaultGroupingEnabled"
        static let defaultView = "review.defaultView"
    }

    var advancesAfterDecision = true
    var defaultSort = PhotoSort()
    var isGroupingEnabled = true
    var defaultView: ViewMode = .gallery

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            advancesAfterDecision: defaults.object(forKey: Keys.advancesAfterDecision) as? Bool ?? true,
            defaultSort: PhotoSort(
                key: defaults.string(forKey: Keys.defaultSortKey)
                    .flatMap(PhotoSort.Key.init(rawValue:)) ?? .captureDate,
                ascending: defaults.object(forKey: Keys.defaultSortAscending) as? Bool ?? true
            ),
            isGroupingEnabled: defaults.object(forKey: Keys.isGroupingEnabled) as? Bool ?? true,
            defaultView: defaults.string(forKey: Keys.defaultView)
                .flatMap(ViewMode.init(rawValue:)) ?? .gallery
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(advancesAfterDecision, forKey: Keys.advancesAfterDecision)
        defaults.set(defaultSort.key.rawValue, forKey: Keys.defaultSortKey)
        defaults.set(defaultSort.ascending, forKey: Keys.defaultSortAscending)
        defaults.set(isGroupingEnabled, forKey: Keys.isGroupingEnabled)
        defaults.set(defaultView.rawValue, forKey: Keys.defaultView)
    }
}

extension PhotoSort.Key {
    var preferenceTitle: String {
        switch self {
        case .captureDate: return L10n.text("Date taken")
        case .name: return L10n.text("Name")
        case .subfolder: return L10n.text("Subfolder")
        case .folderHierarchy: return L10n.text("Folder hierarchy")
        case .fileType: return L10n.text("File type")
        case .mediaKind: return L10n.text("Media type")
        case .camera: return L10n.text("Camera")
        case .lens: return L10n.text("Lens")
        case .aperture: return L10n.text("Aperture")
        case .shutterSpeed: return L10n.text("Shutter speed")
        case .iso: return "ISO"
        case .duration: return L10n.text("Media duration")
        case .videoResolution: return L10n.text("Video resolution")
        case .videoFrameRate: return L10n.text("Video frame rate")
        case .videoCodec: return L10n.text("Video codec")
        case .decision: return L10n.text("Decision")
        case .starRating: return L10n.text("Star rating")
        case .colorLabel: return L10n.text("Color label")
        }
    }
}

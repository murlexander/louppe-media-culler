import Foundation

/// App-wide consent, independent of Photos queries, batches and saved decisions.
struct PhotosNetworkPreferences: Equatable, Sendable {
    enum Keys {
        static let reviewImages = "photosReview.allowNetworkImages"
        static let originals = "photosReview.allowNetworkOriginals"
    }

    var reviewImages = false
    var originals = false

    static func load(from defaults: UserDefaults) -> Self {
        Self(reviewImages: defaults.object(forKey: Keys.reviewImages) as? Bool ?? false,
             originals: defaults.object(forKey: Keys.originals) as? Bool ?? false)
    }
}

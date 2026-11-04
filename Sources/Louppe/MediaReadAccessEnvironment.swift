import SwiftUI

private struct MediaReadAccessEnvironmentKey: EnvironmentKey {
    static let defaultValue: MediaReadAccess? = nil
}

extension EnvironmentValues {
    var mediaReadAccess: MediaReadAccess? {
        get { self[MediaReadAccessEnvironmentKey.self] }
        set { self[MediaReadAccessEnvironmentKey.self] = newValue }
    }
}

import Foundation

/// A capability derived from the exact picker/bookmark URL, never a normalized
/// identity URL. Each executing reader starts and owns an independent scope.
struct MediaReadAccess: Sendable {
    let authorizedURL: URL
    let resourceAccess: SecurityScopedResourceAccess

    func begin() -> Token {
        Token(url: authorizedURL, access: resourceAccess)
    }

    final class Token: Sendable {
        private let url: URL
        private let access: SecurityScopedResourceAccess
        private let started: Bool

        fileprivate init(url: URL, access: SecurityScopedResourceAccess) {
            self.url = url
            self.access = access
            started = access.start(url)
        }

        deinit { if started { access.stop(url) } }
    }
}

import Foundation
import XCTest
@testable import Louppe

final class BackgroundLaunchRecentsTests: XCTestCase {
    private struct Entry: Codable, Equatable {
        let path: String
        let bookmark: Data?
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "LouppeBackgroundLaunchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private var operations: SecurityScopedFolderBookmarks.Operations {
        .init(
            resolve: { _ in .init(url: URL(fileURLWithPath: "/disposable/refreshed"), isStale: true) },
            create: { _ in Data("new-bookmark".utf8) },
            exists: { _ in true },
            access: .init(start: { _ in false }, stop: { _ in })
        )
    }

    func testOnlyExactBackgroundFlagEnablesSuppression() {
        XCTAssertTrue(LouppeLaunchEnvironment.isBackgroundLaunch(in: ["LOUPPE_BACKGROUND_LAUNCH": "1"]))
        for environment in [[:], ["LOUPPE_BACKGROUND_LAUNCH": "0"], ["LOUPPE_BACKGROUND_LAUNCH": "true"]] {
            XCTAssertFalse(LouppeLaunchEnvironment.isBackgroundLaunch(in: environment))
        }
    }

    func testBackgroundSavePreservesExistingRecentsAndBookmarks() throws {
        let defaults = isolatedDefaults()
        let original = try JSONEncoder().encode([Entry(path: "/user/photos", bookmark: Data("original".utf8))])
        defaults.set(original, forKey: "recentFolderBookmarks")
        defaults.set(["/user/photos"], forKey: "recentFolders")
        SecurityScopedFolderBookmarks.save(
            [URL(fileURLWithPath: "/private/tmp/smoke")], to: defaults,
            operations: operations, environment: ["LOUPPE_BACKGROUND_LAUNCH": "1"]
        )
        XCTAssertEqual(defaults.data(forKey: "recentFolderBookmarks"), original)
        XCTAssertEqual(defaults.stringArray(forKey: "recentFolders"), ["/user/photos"])
    }

    func testBackgroundSaveDoesNotCreateRecents() {
        let defaults = isolatedDefaults()
        SecurityScopedFolderBookmarks.save(
            [URL(fileURLWithPath: "/private/tmp/smoke")], to: defaults,
            operations: operations, environment: ["LOUPPE_BACKGROUND_LAUNCH": "1"]
        )
        XCTAssertNil(defaults.object(forKey: "recentFolderBookmarks"))
        XCTAssertNil(defaults.object(forKey: "recentFolders"))
    }

    func testBackgroundLoadDoesNotPersistRefreshedBookmarksOrPaths() throws {
        let defaults = isolatedDefaults()
        let original = try JSONEncoder().encode([Entry(path: "/user/photos", bookmark: Data("original".utf8))])
        defaults.set(original, forKey: "recentFolderBookmarks")
        defaults.set(["/user/photos"], forKey: "recentFolders")
        let folders = SecurityScopedFolderBookmarks.load(
            from: defaults, operations: operations,
            environment: ["LOUPPE_BACKGROUND_LAUNCH": "1"]
        )
        XCTAssertEqual(folders.map(\.path), ["/disposable/refreshed"])
        XCTAssertEqual(defaults.data(forKey: "recentFolderBookmarks"), original)
        XCTAssertEqual(defaults.stringArray(forKey: "recentFolders"), ["/user/photos"])
    }

    func testNormalLaunchStillPersistsRecents() throws {
        let defaults = isolatedDefaults()
        SecurityScopedFolderBookmarks.save(
            [URL(fileURLWithPath: "/user/photos")], to: defaults,
            operations: operations, environment: [:]
        )
        let entries = try JSONDecoder().decode([Entry].self, from: XCTUnwrap(defaults.data(forKey: "recentFolderBookmarks")))
        XCTAssertEqual(entries, [Entry(path: "/user/photos", bookmark: Data("new-bookmark".utf8))])
        XCTAssertEqual(defaults.stringArray(forKey: "recentFolders"), ["/user/photos"])
    }
}

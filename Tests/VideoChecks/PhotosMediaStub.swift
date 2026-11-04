/// The standalone video runner constructs folder-backed items only. Keep its
/// source list independent of PhotoKit/session orchestration while satisfying
/// PhotoFile's optional Photos reference. Full app/XCTest builds use PhotosMedia.
struct PhotosMediaReference: Sendable {}

import Observation
@testable import ChunkseeTestHost

/// An explicit world publication for isolated map tests.
@Observable @MainActor
final class TestGameResources {
    var value = MapGameResources.unavailable
}

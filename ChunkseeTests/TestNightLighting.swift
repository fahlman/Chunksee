import ChunkseeKit
import Observation

@Observable @MainActor final class TestNightLighting {
    var value: MonsterSpawnLight?
    init(_ value: MonsterSpawnLight? = nil) { self.value = value }
}

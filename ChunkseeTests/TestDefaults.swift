import Foundation
import Synchronization
import Testing

/// Each test owns its suites until its async body and teardown have returned.
enum TestDefaults {
    @TaskLocal static var scope: Scope?

    static func make() -> UserDefaults {
        guard let scope else { preconditionFailure("Use the isolatedStores suite trait") }
        return scope.make()
    }

    final class Scope {
        private var suites: [(name: String, defaults: UserDefaults)] = []

        func make() -> UserDefaults {
            let name = "ChunkseeTests-\(UUID())"
            let defaults = UserDefaults(suiteName: name)!
            suites.append((name, defaults))
            return defaults
        }

        func cleanUp() throws {
            for suite in suites {
                suite.defaults.removePersistentDomain(forName: suite.name)
                suite.defaults.synchronize()
                let file = Self.file(for: suite.name)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                #expect(suite.defaults.persistentDomain(forName: suite.name)?.isEmpty != false)
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }
            suites.removeAll()
        }

        static func file(for name: String) -> URL {
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appending(path: "Preferences/\(name).plist")
        }
    }
}

/// Also watches the host's standard domain around every test, including tests with no suites.
nonisolated struct IsolatedStores: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing body: @concurrent @Sendable () async throws -> Void) async throws {
        let scope = await TestDefaults.Scope()
        let monitor = StandardDomainMonitor()
        do {
            try await TestDefaults.$scope.withValue(scope) { try await body() }
        } catch {
            try await scope.cleanUp()
            monitor.checkUnchanged()
            throw error
        }
        try await scope.cleanUp()
        monitor.checkUnchanged()
    }
}

extension Trait where Self == IsolatedStores {
    nonisolated static var isolatedStores: Self { Self() }
}

private nonisolated struct StandardDomainMonitor {
    private final class State: Sendable {
        private struct Values {
            let before: NSDictionary
            var changed = false
        }
        private let name = Bundle.main.bundleIdentifier!
        private let values: Mutex<Values>

        init() {
            #expect(name == "com.fahlsing.Chunksee.Tests")
            values = Mutex(Values(before: UserDefaults.standard.persistentDomain(forName: name) as NSDictionary? ?? [:]))
        }

        func check() -> Bool {
            return values.withLock {
                let after = UserDefaults.standard.persistentDomain(forName: name) as NSDictionary? ?? [:]
                $0.changed = $0.changed || $0.before != after
                return $0.changed
            }
        }
    }

    private let state: State
    private let observation: any NSObjectProtocol

    init() {
        let state = State()
        self.state = state
        // Record a write even when the test restores the previous value before returning.
        observation = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: nil, queue: nil) { _ in
            _ = state.check()
        }
    }

    func checkUnchanged() {
        NotificationCenter.default.removeObserver(observation)
        #expect(!state.check(), "A test changed the standard defaults domain; pass TestDefaults.make() instead")
    }
}

@Suite(.isolatedStores) struct TestStoreIsolationTests {
    @Test func cleanupRemovesTheDomainAndItsPlist() throws {
        let scope = TestDefaults.Scope()
        let defaults = scope.make()
        defaults.set("temporary", forKey: "isolationProbe")
        defaults.synchronize()
        #expect(defaults.string(forKey: "isolationProbe") == "temporary")
        try scope.cleanUp()
        #expect(defaults.object(forKey: "isolationProbe") == nil)
    }
}

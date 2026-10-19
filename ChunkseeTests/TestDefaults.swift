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
        private let directory: URL
        private var suites: [(domain: String, defaults: UserDefaults)] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChunkseeTestPreferences-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func make() -> UserDefaults {
            // Absolute preference domains keep even cfprefsd's delayed empty writes in a
            // disposable directory. It cannot recreate a deleted parent after the test exits.
            let domain = directory.appendingPathComponent("suite-\(UUID())").path
            let defaults = UserDefaults(suiteName: domain)!
            suites.append((domain, defaults))
            return defaults
        }

        func cleanUp() throws {
            for suite in suites {
                suite.defaults.removePersistentDomain(forName: suite.domain)
                suite.defaults.synchronize()
            }
            suites.removeAll()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}

/// Also watches the host's standard domain around every test, including tests with no suites.
nonisolated struct IsolatedStores: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing body: @concurrent @Sendable () async throws -> Void) async throws {
        let scope = try await TestDefaults.Scope()
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
        let scope = try TestDefaults.Scope()
        let defaults = scope.make()
        defaults.set("temporary", forKey: "isolationProbe")
        defaults.synchronize()
        #expect(defaults.string(forKey: "isolationProbe") == "temporary")
        try scope.cleanUp()
    }
}

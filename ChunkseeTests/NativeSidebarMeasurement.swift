import AppKit
import CryptoKit
import Darwin
import Foundation
import IOKit
import Testing
@testable import ChunkseeTestHost

/// Evidence-only entry points; ordinary test runs neither prepare inputs nor measure latency.
@Suite(.isolatedStores, .serialized)
struct NativeSidebarMeasurement {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_SIDEBAR_PREPARE"] != nil),
          .timeLimit(.minutes(2)))
    func prepareFixture() throws {
        let config = try SidebarMeasurementConfiguration.read(key: "CHUNKSEE_SIDEBAR_PREPARE")
        let output = try config.createOutput()
        let generated = try SidebarProbeWorld.make(spawners: SidebarMeasurementInput.spawners)
        defer { try? FileManager.default.removeItem(at: generated) }
        let world = output.appendingPathComponent("world", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: generated, to: world)
        let manifest = try SidebarMeasurementInput.manifest(world)
        try JSONEncoder().encode(manifest).write(to: output.appendingPathComponent("fixture.json"), options: .withoutOverwriting)
        // The external preparation step freezes this one input for both measured hosts.
        print("Sidebar fixture prepared: \(output.path), spawners=\(manifest.spawners), files=\(manifest.files.count)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHUNKSEE_SIDEBAR_MEASURE"] != nil),
          .timeLimit(.minutes(15)))
    func measureActions() async throws {
        let config = try SidebarMeasurementConfiguration.read(key: "CHUNKSEE_SIDEBAR_MEASURE")
        let world = SidebarMeasurementInput.world
        let expected = try JSONDecoder().decode(SidebarMeasurementInput.Manifest.self,
            from: Data(contentsOf: world.deletingLastPathComponent().appendingPathComponent("fixture.json")))
        try #require(expected.spawners == SidebarMeasurementInput.spawners)
        try #require(try SidebarMeasurementInput.manifest(world) == expected)
        let recorder = try SidebarMeasurementRecorder(output: config.createOutput())
        defer { recorder.close() }
        do {
            try await SidebarProbeScenario.run(root: world, count: expected.spawners, measurement: recorder)
            try #require(try SidebarMeasurementInput.manifest(world) == expected)
            try recorder.complete()
        } catch {
            do { try recorder.failed(error) }
            catch { print("Sidebar evidence write failed: \(error)") }
            throw error
        }
    }
}

private nonisolated struct SidebarMeasurementConfiguration: Decodable {
    let output: String

    static func read(key: String) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["CHUNKSEE_SIDEBAR_PREPARE", "CHUNKSEE_SIDEBAR_MEASURE"]
        guard Bundle.main.bundleIdentifier == "com.fahlsing.Chunksee.Tests",
              keys.contains(key), keys.filter({ environment[$0] != nil }).count == 1,
              let path = environment[key] else { throw SidebarMeasurementFailure.configuration }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(filePath: path)))
    }

    func createOutput() throws -> URL {
        let url = URL(filePath: output, directoryHint: .isDirectory).standardizedFileURL
        let prefix = "SidebarMeasurement-"
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              url.deletingLastPathComponent().resolvingSymlinksInPath() == caches.resolvingSymlinksInPath(),
              url.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil,
              !FileManager.default.fileExists(atPath: url.path) else { throw SidebarMeasurementFailure.configuration }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
}

nonisolated enum SidebarMeasurementInput {
    static let spawners = 11_000
    // This path is populated once by the reviewed preparation step, never by either measured host.
    static let world = URL(filePath: "/Users/ryan/Developer/Chunksee-runs/large-sidebar-group-evidence/measurement-input-1/world",
                           directoryHint: .isDirectory)

    nonisolated struct Manifest: Codable, Equatable, Sendable {
        let spawners: Int
        let files: [String: String]
    }

    static func manifest(_ root: URL) throws -> Manifest {
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else { throw SidebarMeasurementFailure.configuration }
        var enumerationFailure: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            errorHandler: { _, error in enumerationFailure = error; return false }) else {
            throw SidebarMeasurementFailure.configuration
        }
        var files: [String: String] = [:], entries = 0
        for case let file as URL in enumerator {
            entries += 1
            let properties = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard entries <= 128, properties.isSymbolicLink == false else { throw SidebarMeasurementFailure.configuration }
            if properties.isDirectory == true { continue }
            guard properties.isRegularFile == true, let size = properties.fileSize, size <= 16 * 1024 * 1024 else {
                throw SidebarMeasurementFailure.configuration
            }
            let name = String(file.path.dropFirst(root.path.count + 1))
            files[name] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        if let enumerationFailure { throw enumerationFailure }
        guard !files.isEmpty, files["level.dat"] != nil else { throw SidebarMeasurementFailure.configuration }
        return Manifest(spawners: spawners, files: files)
    }
}

nonisolated enum SidebarMeasurementFailure: Error { case configuration, invalidClock, foreground, input, sequence }

nonisolated struct SidebarActionStamp: Sendable {
    let uptimeNanoseconds: UInt64
    let mainThreadCPUSeconds: Double

    @MainActor init(clock: SidebarMainThreadClock) throws {
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        mainThreadCPUSeconds = try clock.read()
    }
}

nonisolated struct SidebarActionSample: Codable, Sendable {
    let wallSeconds: Double
    let mainThreadCPUSeconds: Double

    init(start: SidebarActionStamp, end: SidebarActionStamp) throws {
        guard end.uptimeNanoseconds >= start.uptimeNanoseconds,
              start.mainThreadCPUSeconds.isFinite, end.mainThreadCPUSeconds.isFinite,
              end.mainThreadCPUSeconds >= start.mainThreadCPUSeconds else { throw SidebarMeasurementFailure.invalidClock }
        wallSeconds = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        mainThreadCPUSeconds = end.mainThreadCPUSeconds - start.mainThreadCPUSeconds
    }
}

/// Progress is durable before dispatch, so an external supervisor can stop a blocked main thread.
final class SidebarMeasurementRecorder {
    let clock: SidebarMainThreadClock
    private let handle: FileHandle
    private let actions = ["Grid while collapsed", "expand", "select", "Grid while expanded", "collapse before reveal", "reveal through map"]
    private var completedActions = 0
    private var runningAction: String?
    private var revealSequenceOpen = false
    private var scenarioFinished = false
    private var inputReference: (idle: Double, uptime: UInt64)?
    private var foregroundObservers: [NSObjectProtocol] = []
    private var foregroundWasLost = false

    init(output: URL) throws {
        clock = try SidebarMainThreadClock()
        let progress = output.appendingPathComponent("progress.jsonl")
        try Data().write(to: progress, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: progress)
        try record(["phase": "setup", "host": Bundle.main.bundleIdentifier ?? "", "pid": getpid()])
    }

    func close() {
        clearForegroundObservers()
        try? handle.close()
    }

    static func isForeground(_ window: NSWindow) -> Bool {
        NSApp.isActive && window.isKeyWindow && window.isMainWindow && window.isVisible
            && window.occlusionState.contains(.visible)
    }

    func ready(window: NSWindow, spawners: Int, rows: Int) throws {
        guard Self.isForeground(window), spawners == SidebarMeasurementInput.spawners, rows > 0 && rows <= 128 else {
            throw SidebarMeasurementFailure.foreground
        }
        try record(["phase": "ready", "spawners": spawners, "nativeRows": rows,
                    "locale": Locale.current.identifier, "languages": Locale.preferredLanguages,
                    "backingScale": window.backingScaleFactor, "contentWidth": window.contentLayoutRect.width,
                    "contentHeight": window.contentLayoutRect.height, "appearance": window.effectiveAppearance.name.rawValue])
    }

    func beginAction(_ name: String, window: NSWindow) throws {
        guard runningAction == nil, completedActions < actions.count, actions[completedActions] == name else {
            throw SidebarMeasurementFailure.sequence
        }
        guard Self.isForeground(window) else { throw SidebarMeasurementFailure.foreground }
        let idle = try Self.inputIdleSeconds()
        guard idle >= 30 else { throw SidebarMeasurementFailure.input }
        inputReference = (idle, DispatchTime.now().uptimeNanoseconds)
        foregroundWasLost = false
        let changes: [(Notification.Name, AnyObject)] = [
            (NSApplication.didResignActiveNotification, NSApp),
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.didResignMainNotification, window),
            (NSWindow.didChangeOcclusionStateNotification, window),
        ]
        foregroundObservers = changes.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self, weak window] _ in
                // AppKit notifications delivered on the main operation queue have main-actor isolation.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let window, Self.isForeground(window) else {
                        self.foregroundWasLost = true
                        return
                    }
                }
            }
        }
        runningAction = name
        try record(["phase": "action-start", "action": name, "inputIdleSeconds": idle])
    }

    func endAction(_ name: String, window: NSWindow, sample: SidebarActionSample,
                   rows: Int, expanded: Bool, selectedRow: Int) throws {
        defer { clearForegroundObservers() }
        guard runningAction == name, let reference = inputReference else { throw SidebarMeasurementFailure.sequence }
        guard !foregroundWasLost, Self.isForeground(window) else { throw SidebarMeasurementFailure.foreground }
        let idle = try Self.inputIdleSeconds()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - reference.uptime) / 1e9
        // Match the shared Mac guard's allowance for counter reads, not for user activity.
        guard idle >= reference.idle + elapsed - 2 else { throw SidebarMeasurementFailure.input }
        try record(["phase": "action-end", "action": name, "wallSeconds": sample.wallSeconds,
                    "mainThreadCPUSeconds": sample.mainThreadCPUSeconds, "nativeRows": rows,
                    "expanded": expanded, "selectedRow": selectedRow,
                    "inputIdleSeconds": idle, "foregroundMaintained": true,
                    "contentWidth": window.contentLayoutRect.width, "contentHeight": window.contentLayoutRect.height])
        runningAction = nil
        inputReference = nil
        completedActions += 1
    }

    func beginRevealSequence() throws {
        guard completedActions == 4, !revealSequenceOpen else { throw SidebarMeasurementFailure.sequence }
        revealSequenceOpen = true
        try record(["phase": "reveal-sequence-start", "maximumSeconds": 180])
    }

    func endRevealSequence() throws {
        guard completedActions == 6, revealSequenceOpen else { throw SidebarMeasurementFailure.sequence }
        revealSequenceOpen = false
        try record(["phase": "reveal-sequence-end"])
    }

    func scenarioComplete() throws {
        guard completedActions == 6, runningAction == nil, !revealSequenceOpen else { throw SidebarMeasurementFailure.sequence }
        scenarioFinished = true
        try record(["phase": "scenario-complete", "actions": completedActions])
    }

    func complete() throws {
        guard scenarioFinished else { throw SidebarMeasurementFailure.sequence }
        try record(["phase": "complete", "actions": completedActions, "fixtureUnchanged": true])
    }

    func failed(_ error: any Error) throws {
        try record(["phase": "failed", "error": String(describing: error), "completedActions": completedActions,
                    "runningAction": runningAction ?? "none"])
    }

    private func record(_ values: [String: Any]) throws {
        var values = values
        values["uptimeNanoseconds"] = DispatchTime.now().uptimeNanoseconds
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) + Data([0x0a])
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func clearForegroundObservers() {
        for observer in foregroundObservers { NotificationCenter.default.removeObserver(observer) }
        foregroundObservers.removeAll()
    }

    private static func inputIdleSeconds() throws -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { throw SidebarMeasurementFailure.input }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { throw SidebarMeasurementFailure.input }
        let seconds = value.doubleValue / 1e9
        guard seconds.isFinite && seconds >= 0 else { throw SidebarMeasurementFailure.input }
        return seconds
    }
}

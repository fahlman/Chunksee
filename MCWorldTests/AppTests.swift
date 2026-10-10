import Foundation
import Testing
@testable import MCWorld

@Suite struct AppModelTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MCWorldTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "MCWorldTests-\(UUID().uuidString)")!
    }

    @Test func worldsOpenAtQuitReopenAndClosedOnesDont() throws {
        let (a, b) = (try folder(), try folder())
        defer { for url in [a, b] { try? FileManager.default.removeItem(at: url) } }
        let defaults = defaults()
        let model = AppModel(defaults: defaults, reopensWorlds: true)
        let idA = try #require(model.add(a)), idB = try #require(model.add(b))
        #expect(model.recentWorlds.map(\.id) == [idB, idA])
        #expect(model.recentWorlds.first?.name == b.lastPathComponent)
        #expect(model.url(for: idA)?.standardizedFileURL.path == a.standardizedFileURL.path)
        model.windowOpened(idA)
        model.windowOpened(idB)
        model.windowOpened(idA)
        #expect(model.openWorldIDs == [idA, idB])

        // Closing a window forgets it; quitting doesn't.
        model.windowClosed(idB)
        model.appWillTerminate()
        model.windowClosed(idA)
        let relaunched = AppModel(defaults: defaults, reopensWorlds: true)
        #expect(relaunched.worldsToReopenAtLaunch() == [idA])
        #expect(relaunched.worldsToReopenAtLaunch().isEmpty)   // only once per launch
        #expect(relaunched.recentWorlds.map(\.id) == [idB, idA])
        #expect(AppModel(defaults: defaults, reopensWorlds: false).worldsToReopenAtLaunch().isEmpty)
    }

    @Test func openRecentKeepsTheNewestTenAndClearsAllButOpenWorlds() throws {
        let folders = try (0..<12).map { _ in try folder() }
        defer { for url in folders { try? FileManager.default.removeItem(at: url) } }
        let model = AppModel(defaults: defaults(), reopensWorlds: false)
        let ids = folders.compactMap(model.add)
        #expect(model.recentWorlds.map(\.id) == ids.reversed().prefix(AppModel.recentLimit).map { $0 })
        // Opening one moves it to the top under its in-game name.
        model.opened(ids[5], url: folders[5], name: "Ryan’s Realm")
        #expect(model.recentWorlds.first?.id == ids[5] && model.recentWorlds.first?.name == "Ryan’s Realm")
        #expect(model.add(folders[5]) == ids[5] && model.recentWorlds.first?.name == "Ryan’s Realm")
        model.windowOpened(ids[5])
        model.clearRecentWorlds()
        #expect(model.recentWorlds.map(\.id) == [ids[5]])
    }

    @Test func theLastWorldFromBeforeWindowsPerWorldReopens() throws {
        let world = try folder()
        defer { try? FileManager.default.removeItem(at: world) }
        let defaults = defaults()
        let bookmark = try world.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "lastWorldBookmark")
        let model = AppModel(defaults: defaults, reopensWorlds: true)
        let id = world.standardizedFileURL.path
        #expect(model.recentWorlds.map(\.id) == [id])
        #expect(model.worldsToReopenAtLaunch() == [id])
        #expect(defaults.data(forKey: "lastWorldBookmark") == nil)
    }

    @Test func aWorldThatCantBeFoundLeavesOpenRecent() throws {
        let world = try folder()
        let model = AppModel(defaults: defaults(), reopensWorlds: false)
        let id = try #require(model.add(world))
        try FileManager.default.removeItem(at: world)
        #expect(model.url(for: id) == nil)
        #expect(model.recentWorlds.isEmpty)
    }
}

import AppKit
import ApplicationServices
import ChunkseeKit
import ChunkseeKitTestSupport
import Darwin
import Observation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Probe-only source: validate native actions on a small fixture before freezing a large run.
@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(2)))
struct NativeSidebarProbe {
    @Test func validatesDisclosureSelectionGridAndMapReveal() async throws {
        let count = 31
        let root = try SidebarProbeWorld.make(spawners: count)
        defer { try? FileManager.default.removeItem(at: root) }
        let dimension = try #require(try World(contentsOf: root).dimension("minecraft:overworld"))
            .documentURL(inWorldAt: root).resolvingSymlinksInPath()
        let model = AppModel(defaults: TestDefaults.make(), cacheRoot: nil)
        model.names.minecraft.usesGameArtwork = false
        try model.worldFolders.remember(root)
        let (documents, created) = AsyncStream.makeStream(of: WorldDocument.self)
        var iterator = documents.makeAsyncIterator()
        try #require(TestDocumentWindows.makeDocument == nil)
        TestDocumentWindows.makeDocument = { configuration in
            let document = WorldDocument(configuration: configuration, model: model)
            created.yield(document)
            return document
        }
        defer {
            TestDocumentWindows.makeDocument = nil
            created.finish()
        }
        let (native, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
        try #require(!reused)
        let document = try #require(await iterator.next(isolation: #isolation))
        func close() async {
            native.close()
            document.session?.close()
            await document.session?.waitUntilClosed()
            await model.names.minecraft.waitUntilIdle()
        }
        do {
            for await _ in Observations<Void, Never>.untilFinished({
                document.session == nil && document.openingFailure == nil ? .next(()) : .finish
            }) {}
            try #require(document.openingFailure == nil)
            let session = try #require(document.session)
            await session.search.waitForIndex()
            await session.resources.waitForRefresh()
            let markers = session.presentation.selectedIndex.places.filter { $0.group == .spawner }
            try #require(markers.count == count && Set(markers.map(\.id)).count == count)
            try #require(session.presentation.spawnPoint == .zero)
            let nearest = try #require(markers.first {
                $0.blockPosition == BlockPosition(blockX: 0, blockY: 12, blockZ: 0)
            })
            let map = try #require(session.map)
            map.setLightingMode(.daylight)
            map.setCastsShadows(false)
            map.viewport = MapViewport(center: CGPoint(x: 8, y: 8), scale: 8)
            session.visibility.places.remove(.spawner)
            session.visibility.showsGrid = false
            let window = try #require(native.windowControllers.first?.window)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(CGSize(width: 900, height: 650))
            window.orderFront(nil)
            try await SidebarNativeDriver.afterUpdate(window) {
                window.isVisible && session.routing.openDocument != nil
            }
            await map.waitUntilIdle()
            // Existing native accessibility tests use this request to materialize SwiftUI's tree.
            let activation = await Task.detached {
                var windows: CFTypeRef?
                return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                    kAXWindowsAttribute as CFString, &windows).rawValue
            }.value
            try #require(activation == AXError.success.rawValue)
            let driver = try SidebarNativeDriver(window: window, groupTitle: PlaceGroup.spawner.name(in: session.resources.gameNames))
            let collapsedRows = driver.outline.numberOfRows
            try #require(!driver.isExpanded)
            // Reading one actual main-thread counter verifies the source, not action speed.
            let clock = try SidebarMainThreadClock()
            let counter = try clock.read()
            try #require(counter.isFinite && counter >= 0)
            print("Sidebar probe setup: spawners=\(count), nativeRows=\(collapsedRows), mainThreadCPUCounter=\(counter)")

            try await driver.perform("Grid while collapsed", action: {
                try driver.performVisibilityAction(label: "Grid", show: true)
            }, ready: { session.visibility.showsGrid && driver.outline.numberOfRows == collapsedRows })
            try await driver.perform("expand", action: { try driver.pressDisclosure() }, ready: {
                driver.isExpanded && driver.outline.numberOfRows == collapsedRows + count
            })
            try driver.verifyChildren(count: count)
            let firstRow = driver.groupRow + 1
            // Selection uses AppKit's native selection path; it must update the SwiftUI binding.
            try await driver.perform("select", action: {
                driver.outline.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
            }, ready: {
                driver.outline.selectedRow == firstRow && session.selection.sidebarSelection == .place(nearest.id)
                    && session.selection.isInspectorShown && driver.hasVisibleInspector
                    && session.visibility.places.contains(.spawner)
            })
            let selected = try #require(session.selection.sidebarSelection)
            guard case .place(let selectedID) = selected else { throw SidebarProbeError.wrongSelection }
            try #require(markers.contains { $0.id == selectedID })
            await map.waitUntilIdle()
            try await driver.perform("Grid while expanded", action: {
                try driver.performVisibilityAction(label: "Grid", show: false)
            }, ready: {
                !session.visibility.showsGrid && driver.isExpanded
                    && driver.outline.numberOfRows == collapsedRows + count
            })
            try await driver.perform("collapse before reveal", action: { try driver.pressDisclosure() }, ready: {
                !driver.isExpanded && driver.outline.numberOfRows == collapsedRows
            })
            let mapNode = try driver.mapNode()
            let mapSize = try #require(mapNode.accessibilityFrame?()).size
            let location = try #require(MapContent(session: session).accessibleLocations(viewport: map.viewport, size: mapSize)
                .first { location in
                    guard case .row(.place(let id))? = location.target else { return false }
                    return id != selectedID
                })
            guard case .row(.place(let revealedID))? = location.target else { throw SidebarProbeError.wrongSelection }
            let button = try driver.mapButton(location, in: mapNode)
            try await driver.perform("reveal through map", action: {
                try #require(button.accessibilityPerformPress?() == true)
            }, ready: {
                driver.isExpanded && driver.outline.numberOfRows == collapsedRows + count
                    && session.selection.sidebarSelection == .place(revealedID)
                    && session.selection.isInspectorShown && driver.hasVisibleInspector
                    && driver.isSelectedRowVisible
            })
            try driver.verifyChildren(count: count)
            try #require(driver.outline.selectedRow > driver.groupRow
                && driver.outline.selectedRow <= driver.groupRow + count)
            print("Sidebar probe complete: native disclosure, selection, Grid and map reveal verified; no performance verdict")
        } catch {
            await close()
            throw error
        }
        await close()
    }
}

private enum SidebarProbeError: Error { case wrongSelection, invalidCPURead }

private enum SidebarProbeWorld {
    static func make(spawners count: Int) throws -> URL {
        precondition(count > 0 && count <= 11_000)
        let chunks = (0..<((count + 255) / 256)).map { chunkIndex in
            let occupants = min(256, count - chunkIndex * 256)
            var chunk = TestWorld.chunk(x: chunkIndex, z: 0,
                palette: ["minecraft:air", "minecraft:stone", "minecraft:spawner"]) { x, y, z in
                    if y < 12 { return 1 }
                    return y == 12 && z * 16 + x < occupants ? 2 : 0
                }
            var fields = chunk.nbt.compound!
            fields["block_entities"] = .list((0..<occupants).map { index in .compound([
                "id": .string("minecraft:mob_spawner"),
                "x": .int(Int32(chunkIndex * 16 + index % 16)), "y": .int(12), "z": .int(Int32(index / 16)),
                "SpawnData": .compound(["entity": .compound(["id": .string("minecraft:zombie")])]),
            ]) })
            chunk.nbt = .compound(fields)
            return chunk
        }
        return try TestWorld.make(chunks: chunks)
    }
}

private final class SidebarNativeDriver {
    let window: NSWindow
    let outline: NSOutlineView
    let groupRow: Int
    private let disclosure: AnyObject

    init(window: NSWindow, groupTitle: String) throws {
        self.window = window
        let content = try #require(window.contentView)
        let outlines = Self.views(in: content).compactMap { $0 as? NSOutlineView }
        outline = try #require(outlines.first)
        try #require(outlines.count == 1)
        let rows = try #require(outline.accessibilityRows())
        let matches = try rows.filter { row in
            try Self.nodes(in: row as AnyObject, budget: 64).contains {
                ($0.accessibilityLabel?() ?? "").contains(groupTitle)
            }
        }
        try #require(matches.count == 1)
        let row = try #require(matches.first) as AnyObject
        groupRow = try #require(row.accessibilityIndex?())
        try #require(groupRow >= 0 && groupRow < outline.numberOfRows)
        disclosure = try #require(try Self.nodes(in: row, budget: 64).first {
            $0.accessibilityRole?() == NSAccessibility.Role.disclosureTriangle
        })
    }

    var isExpanded: Bool { outline.isItemExpanded(outline.item(atRow: groupRow)) }

    var isSelectedRowVisible: Bool {
        let row = outline.selectedRow
        return row >= 0 && outline.visibleRect.intersects(outline.rect(ofRow: row))
    }

    var hasVisibleInspector: Bool {
        guard let content = window.contentView else { return false }
        return Self.views(in: content).compactMap { $0 as? NSSplitView }
            .flatMap { ($0.delegate as? NSSplitViewController)?.splitViewItems ?? [] }
            .contains { $0.behavior == .inspector && !$0.isCollapsed && !$0.viewController.view.isHiddenOrHasHiddenAncestor }
    }

    func verifyChildren(count: Int) throws {
        try #require(isExpanded)
        let parentLevel = outline.level(forRow: groupRow)
        for row in (groupRow + 1)...(groupRow + count) {
            try #require(outline.level(forRow: row) == parentLevel + 1)
        }
        if groupRow + count + 1 < outline.numberOfRows {
            try #require(outline.level(forRow: groupRow + count + 1) <= parentLevel)
        }
    }

    func pressDisclosure() throws { try #require(disclosure.accessibilityPerformPress?() == true) }

    func performVisibilityAction(label: String, show: Bool) throws {
        // This small proof may traverse the tree. A timed driver must prepare controls before its clock starts.
        let node = try #require(try Self.nodes(in: outline, budget: 512).first {
            ($0.accessibilityLabel?() ?? "") == label && !($0.accessibilityCustomActions?() ?? []).isEmpty
        })
        let action = try #require((node.accessibilityCustomActions?() ?? []).first { $0.name == (show ? "Show on Map" : "Hide on Map") })
        let handler = try #require(action.handler)
        try #require(handler())
    }

    func mapNode() throws -> AnyObject {
        let content = try #require(window.contentView)
        return try #require(try Self.nodes(in: content, budget: 2_000).first {
            $0.accessibilityIdentifier?() == "world-map"
        })
    }

    func mapButton(_ location: AccessibleMapLocation, in map: AnyObject) throws -> AnyObject {
        let value = Coordinates.text(location.position, y: location.y)
        let matches = try Self.nodes(in: map, budget: 2_000).filter {
            $0.accessibilityRole?() == NSAccessibility.Role.button
                && $0.accessibilityLabel?() == location.name && Self.textValue($0) == value
        }
        try #require(matches.count == 1)
        return try #require(matches.first)
    }

    func perform(_ name: String, action: () throws -> Void, ready: () -> Bool) async throws {
        print("Sidebar probe action: \(name)")
        try await Self.afterUpdate(window, action: action, ready: ready)
        print("Sidebar probe observed: \(name), nativeRows=\(outline.numberOfRows), expanded=\(isExpanded), selectedRow=\(outline.selectedRow)")
    }

    static func afterUpdate(_ window: NSWindow, action: () throws -> Void = {}, ready: () -> Bool) async throws {
        let (updates, updated) = AsyncStream.makeStream(of: Void.self)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: window, queue: .main) { _ in updated.yield(()) }
        defer { NotificationCenter.default.removeObserver(observer); updated.finish() }
        try action()
        window.viewsNeedDisplay = true
        for await _ in updates {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if ready() { return }
        }
        throw CancellationError()
    }

    private static func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }

    private static func nodes(in root: AnyObject, budget: Int) throws -> [AnyObject] {
        var found: [AnyObject] = [], pending = [root], seen: Set<ObjectIdentifier> = []
        while let node = pending.popLast(), found.count < budget {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            found.append(node)
            pending += (node.accessibilityChildren?() ?? []).reversed().map { $0 as AnyObject }
        }
        try #require(pending.isEmpty, "The native tree exceeded this proof's declared traversal budget")
        return found
    }

    private static func textValue(_ node: AnyObject) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard let object = node as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}

/// A retained send right identifies the actual main thread, not an arbitrary task thread.
private final class SidebarMainThreadClock {
    private let thread: mach_port_t

    init() throws {
        try #require(Thread.isMainThread)
        thread = mach_thread_self()
    }

    isolated deinit { _ = mach_port_deallocate(mach_task_self_, thread) }

    func read() throws -> Double {
        try #require(Thread.isMainThread)
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let expectedCount = count
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expectedCount)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expectedCount else { throw SidebarProbeError.invalidCPURead }
        return Double(info.user_time.seconds) + Double(info.system_time.seconds)
            + (Double(info.user_time.microseconds) + Double(info.system_time.microseconds)) / 1_000_000
    }
}

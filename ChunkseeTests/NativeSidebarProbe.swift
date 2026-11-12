import AppKit
import ApplicationServices
import ChunkseeKit
import ChunkseeKitTestSupport
import Darwin
import Observation
import OSLog
import SwiftUI
import Testing
@testable import ChunkseeTestHost

/// Probe-only source: validate native actions on a small fixture before freezing a large run.
@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(2)))
struct NativeSidebarProbe {
    @Test func validatesDisclosureSelectionGridAndMapReveal() async throws {
        let count = 31
        let root = try SidebarProbeWorld.make(spawners: count)
        SidebarProbeTrace.event("fixture created")
        defer { try? FileManager.default.removeItem(at: root) }
        try await SidebarProbeScenario.run(root: root, count: count, measurement: nil)
    }
}

/// Both fixture sizes exercise the same native document, actions and completion predicates.
enum SidebarProbeScenario {
    static func run(root: URL, count: Int, measurement: SidebarMeasurementRecorder?) async throws {
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
        SidebarProbeTrace.event("opening native document")
        let (native, reused) = try await NSDocumentController.shared.openDocument(withContentsOf: dimension, display: true)
        SidebarProbeTrace.event("native opener returned; awaiting SwiftUI document")
        try #require(!reused)
        let document = try #require(await iterator.next(isolation: #isolation))
        SidebarProbeTrace.event("SwiftUI document received")
        func close() async {
            SidebarProbeTrace.event("closing document and draining session")
            native.close()
            document.session?.close()
            await document.session?.waitUntilClosed()
            SidebarProbeTrace.event("session drained; draining game resources")
            await model.names.minecraft.waitUntilIdle()
            SidebarProbeTrace.event("cleanup complete")
        }
        do {
            SidebarProbeTrace.event("awaiting session publication")
            for await _ in Observations<Void, Never>.untilFinished({
                document.session == nil && document.openingFailure == nil ? .next(()) : .finish
            }) {}
            try #require(document.openingFailure == nil)
            let session = try #require(document.session)
            SidebarProbeTrace.event("session published; awaiting index")
            await session.search.waitForIndex()
            SidebarProbeTrace.event("index finished; awaiting resources")
            await session.resources.waitForRefresh()
            SidebarProbeTrace.event("resources finished; checking fixture")
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
            if measurement != nil {
                window.title = "Chunksee Sidebar Comparison"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } else {
                window.orderFront(nil)
            }
            SidebarProbeTrace.event("window readiness entered: visible=\(window.isVisible), routingInstalled=\(session.routing.openDocument != nil)")
            try await SidebarNativeDriver.afterUpdate(window) {
                window.isVisible && session.routing.openDocument != nil
                    && (measurement == nil || SidebarMeasurementRecorder.isForeground(window))
            }
            SidebarProbeTrace.event("window ready; awaiting initial map work")
            await map.waitUntilIdle()
            SidebarProbeTrace.event("initial map work finished; laying out before accessibility reads")
            window.contentView?.layoutSubtreeIfNeeded()
            // Existing native accessibility tests use this request to materialize SwiftUI's tree.
            let activation = await Task.detached {
                var windows: CFTypeRef?
                return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                    kAXWindowsAttribute as CFString, &windows).rawValue
            }.value
            SidebarProbeTrace.event("accessibility request returned: status=\(activation)")
            try #require(activation == AXError.success.rawValue)
            SidebarProbeTrace.event("locating native sidebar controls")
            let driver = try SidebarNativeDriver(window: window,
                groupTitle: PlaceGroup.spawner.name(in: session.resources.gameNames), measurement: measurement)
            SidebarProbeTrace.event("native sidebar controls located")
            let collapsedRows = driver.outline.numberOfRows
            try #require(!driver.isExpanded)
            // Reading one actual main-thread counter verifies the source, not action speed.
            let clock = try SidebarMainThreadClock()
            let counter = try clock.read()
            try #require(counter.isFinite && counter >= 0)
            print("Sidebar probe setup: spawners=\(count), nativeRows=\(collapsedRows), mainThreadCPUCounter=\(counter)")

            try measurement?.ready(window: window, spawners: count, rows: collapsedRows)
            try await driver.perform("Grid while collapsed", prepareAction: {
                try driver.visibilityAction(label: "Grid", show: true)
            }, ready: { session.visibility.showsGrid && driver.outline.numberOfRows == collapsedRows })
            try await driver.perform("expand", prepareAction: { try driver.disclosureAction() }, ready: {
                driver.isExpanded && driver.outline.numberOfRows == collapsedRows + count
            })
            try driver.verifyChildren(count: count)
            let firstRow = driver.groupRow + 1
            func recordSelection(_ stage: String) {
                guard measurement == nil else { return }
                let selected = session.selection.sidebarSelection
                let nativeRow = driver.outline.selectedRow
                print("Sidebar selection evidence: stage=\(stage), expectedRow=\(firstRow), nativeRow=\(nativeRow), "
                    + "nativeMatches=\(nativeRow == firstRow), modelMatches=\(selected == .place(nearest.id)), "
                    + "selection=\(String(describing: selected)), expectedPlace=\(nearest.id), "
                    + "inspectorShown=\(session.selection.isInspectorShown), inspectorVisible=\(driver.hasVisibleInspector), "
                    + "spawnersShown=\(session.visibility.places.contains(.spawner)), nativeRows=\(driver.outline.numberOfRows), "
                    + "windowVisible=\(window.isVisible), windowKey=\(window.isKeyWindow), "
                    + "windowMain=\(window.isMainWindow), appActive=\(NSApp.isActive)")
            }
            do {
                recordSelection("before action")
                // Preserve the actual state at completion or cancellation, before closing the document.
                defer { recordSelection("after wait") }
                // Selection uses AppKit's native selection path; it must update the SwiftUI binding.
                try await driver.perform("select", prepareAction: {
                    return {
                        driver.outline.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
                        recordSelection("after action")
                    }
                }, ready: {
                    driver.outline.selectedRow == firstRow && session.selection.sidebarSelection == .place(nearest.id)
                        && session.selection.isInspectorShown && driver.hasVisibleInspector
                        && session.visibility.places.contains(.spawner)
                })
            }
            let selected = try #require(session.selection.sidebarSelection)
            guard case .place(let selectedID) = selected else { throw SidebarProbeError.wrongSelection }
            try #require(markers.contains { $0.id == selectedID })
            SidebarProbeTrace.event("selection verified; awaiting map work")
            await map.waitUntilIdle()
            SidebarProbeTrace.event("selection map work finished")
            try await driver.perform("Grid while expanded", prepareAction: {
                try driver.visibilityAction(label: "Grid", show: false)
            }, ready: {
                !session.visibility.showsGrid && driver.isExpanded
                    && driver.outline.numberOfRows == collapsedRows + count
            })
            // Collapse, map-control lookup and reveal share the original 180-second reveal allowance.
            try measurement?.beginRevealSequence()
            try await driver.perform("collapse before reveal", prepareAction: { try driver.disclosureAction() }, ready: {
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
            try await driver.perform("reveal through map", prepareAction: {
                let button = try driver.mapButton(location, in: driver.mapNode())
                return { try #require(button.accessibilityPerformPress?() == true) }
            }, ready: {
                driver.isExpanded && driver.outline.numberOfRows == collapsedRows + count
                    && session.selection.sidebarSelection == .place(revealedID)
                    && session.selection.isInspectorShown && driver.hasVisibleInspector
                    && driver.isSelectedRowVisible
            })
            try measurement?.endRevealSequence()
            try driver.verifyChildren(count: count)
            try #require(driver.outline.selectedRow > driver.groupRow
                && driver.outline.selectedRow <= driver.groupRow + count)
            try measurement?.scenarioComplete()
            print("Sidebar probe complete: native disclosure, selection, Grid and map reveal verified")
        } catch {
            await close()
            throw error
        }
        await close()
    }
}

private enum SidebarProbeError: Error { case wrongSelection, invalidCPURead }

/// Temporary checkpoints locate a stalled setup wait without changing its conditions.
private enum SidebarProbeTrace {
    static let logger = Logger(subsystem: "com.fahlsing.Chunksee.Tests", category: "SidebarProbe")

    static func event(_ message: String) {
        logger.notice("Sidebar probe phase: \(message, privacy: .public)")
    }
}

enum SidebarProbeWorld {
    static func make(spawners count: Int) throws -> URL {
        precondition(count > 0 && count <= SidebarMeasurementInput.spawners)
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

final class SidebarNativeDriver {
    let window: NSWindow
    let outline: NSOutlineView
    let groupRow: Int
    private let groupTitle: String
    private let measurement: SidebarMeasurementRecorder?

    init(window: NSWindow, groupTitle: String, measurement: SidebarMeasurementRecorder?) throws {
        self.window = window
        self.groupTitle = groupTitle
        self.measurement = measurement
        let content = try #require(window.contentView)
        let outlines = Self.views(in: content).compactMap { $0 as? NSOutlineView }
        outline = try #require(outlines.first)
        try #require(outlines.count == 1)
        groupRow = try Self.groupControls(in: outline, title: groupTitle, window: window,
            visibleOnly: measurement != nil).row
    }

    private static func groupControls(in outline: NSOutlineView, title: String, window: NSWindow,
                                      visibleOnly: Bool) throws
        -> (row: Int, cell: NSButtonCell, view: NSView) {
        let matches = try existingRows(in: outline, visibleOnly: visibleOnly).filter { row in
            row.nodes.contains { ($0.accessibilityLabel?() ?? "").contains(title) }
        }
        try #require(matches.count == 1)
        let match = try #require(matches.first)
        let disclosures = match.nodes.filter {
            $0.accessibilityRole?() == NSAccessibility.Role.disclosureTriangle
        }
        try #require(disclosures.count == 1)
        let cell = try #require(disclosures.first as? NSButtonCell)
        let view = try #require(cell.controlView)
        try #require(view.window === window)
        try #require(outline.row(for: view) == match.index)
        return (match.index, cell, view)
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

    func disclosureAction() throws -> () throws -> Void {
        // Native layout can reuse cells after selection or expansion; resolve the current group again.
        let current = try Self.groupControls(in: outline, title: groupTitle, window: window,
            visibleOnly: measurement != nil)
        try #require(current.row == groupRow)
        try #require(current.cell.isEnabled)
        try #require(current.cell.action != nil)
        return { current.cell.performClick(current.view) }
    }

    func visibilityAction(label: String, show: Bool) throws -> () throws -> Void {
        // Resolve the current action before the clock starts, without constructing offscreen rows.
        let matches = try Self.existingRows(in: outline, visibleOnly: measurement != nil).flatMap(\.nodes).filter {
            ($0.accessibilityLabel?() ?? "") == label && !($0.accessibilityCustomActions?() ?? []).isEmpty
        }
        try #require(matches.count == 1)
        let node = try #require(matches.first)
        let action = try #require((node.accessibilityCustomActions?() ?? []).first { $0.name == (show ? "Show on Map" : "Hide on Map") })
        let handler = try #require(action.handler)
        return { try #require(handler()) }
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

    func perform(_ name: String, prepareAction: () throws -> () throws -> Void,
                 ready: @escaping @MainActor () -> Bool) async throws {
        print("Sidebar probe action: \(name)")
        try measurement?.beginAction(name, window: window)
        let sample = try await Self.afterUpdate(window, label: name, prepareAction: prepareAction,
            timing: measurement?.clock, ready: {
                ready() && (self.measurement == nil
                    || (!self.outline.needsLayout && self.window.contentView?.needsLayout == false))
            })
        if let measurement {
            try measurement.endAction(name, window: window, sample: #require(sample),
                rows: outline.numberOfRows, expanded: isExpanded, selectedRow: outline.selectedRow)
        }
        print("Sidebar probe observed: \(name), nativeRows=\(outline.numberOfRows), expanded=\(isExpanded), selectedRow=\(outline.selectedRow)")
    }

    @discardableResult
    static func afterUpdate(_ window: NSWindow, label: String = "window readiness",
                            prepareAction: () throws -> () throws -> Void = { {} },
                            timing: SidebarMainThreadClock? = nil,
                            ready: @escaping @MainActor () -> Bool) async throws -> SidebarActionSample? {
        let (updates, updated) = AsyncStream.makeStream(
            of: (ContinuousClock.Instant, Result<SidebarActionStamp?, any Error>).self,
            bufferingPolicy: .bufferingNewest(1))
        let dispatch = SidebarActionDispatch()
        // An inactive host can lay out its inspector without a window-update notification.
        // Observe after other before-waiting observers so deferred UI work can finish first.
        let observer = try #require(CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
                // Installed only on the main run loop; its synchronous callback has main-actor isolation.
                MainActor.assumeIsolated {
                    // A false predicate queues no work and cannot keep the run loop awake itself.
                    // A native action can enter a nested run loop before returning.
                    if dispatch.hasReturned && ready() {
                        let stamp = Result { try timing.map { try SidebarActionStamp(clock: $0) } }
                        updated.yield((.now, stamp))
                        if case .failure = stamp { updated.finish() }
                    }
                }
            })
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        var updateCount = 0
        var satisfied = false
        defer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
            updated.finish()
            SidebarProbeTrace.event("\(label) wait ended: updates=\(updateCount), ready=\(satisfied), visible=\(window.isVisible)")
        }
        // Resolving and validating a native control cannot suspend before its dispatch.
        // Its tree lookup is deliberately outside the measured interval.
        let action = try prepareAction()
        let actionStart = ContinuousClock.now
        let sampleStart = try timing.map { try SidebarActionStamp(clock: $0) }
        try action()
        dispatch.hasReturned = true
        satisfied = ready()
        // A correctness-only action may already be ready. A measured action must include deferred UI work.
        if satisfied && timing == nil {
            SidebarProbeTrace.event("\(label) already ready after action")
            SidebarProbeTrace.event("\(label) readiness elapsed: \(actionStart.duration(to: .now))")
            return nil
        }
        if timing == nil { SidebarProbeTrace.event("\(label) awaiting UI readiness") }
        for await (observedAt, result) in updates {
            let sampleEnd = try result.get()
            updateCount += 1
            satisfied = ready()
            if satisfied {
                SidebarProbeTrace.event("\(label) readiness elapsed: \(actionStart.duration(to: observedAt))")
                if let sampleStart, let sampleEnd {
                    return try SidebarActionSample(start: sampleStart, end: sampleEnd)
                }
                return nil
            }
        }
        throw CancellationError()
    }

    private static func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }

    private static func existingRows(in outline: NSOutlineView, visibleOnly: Bool) throws -> [(index: Int, nodes: [AnyObject])] {
        let rowCount = outline.numberOfRows
        let range: Range<Int>
        if visibleOnly {
            try #require(rowCount > 0 && rowCount <= SidebarMeasurementInput.spawners + 128)
            let visible = outline.rows(in: outline.visibleRect)
            try #require(visible.location != NSNotFound && visible.location >= 0 && visible.location < rowCount)
            try #require(visible.length > 0 && visible.length <= 128 && visible.length <= rowCount - visible.location)
            range = visible.location..<(visible.location + visible.length)
        } else {
            try #require(rowCount > 0 && rowCount <= 128,
                "The small proof permits at most 128 native sidebar rows")
            range = 0..<rowCount
        }
        // SwiftUI has no API for locating its backing outline controls. Its accessibility-row
        // proxies can omit label children, so inspect only row views that already exist.
        var rows: [(index: Int, nodes: [AnyObject])] = []
        for index in range {
            guard let row = outline.rowView(atRow: index, makeIfNecessary: false) else { continue }
            rows.append((index, try nodes(in: row, budget: 64)))
        }
        return rows
    }

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

private final class SidebarActionDispatch {
    var hasReturned = false
}

/// A retained send right identifies the actual main thread, not an arbitrary task thread.
final class SidebarMainThreadClock {
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

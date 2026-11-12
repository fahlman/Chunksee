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

/// Diagnostic-only source: inspect the group lookup before any native action or timing.
@Suite(.isolatedStores, .serialized, .timeLimit(.minutes(2)))
struct NativeSidebarProbe {
    @Test func diagnosesNativeSidebarGroupLookup() async throws {
        let count = 31
        let root = try SidebarProbeWorld.make(spawners: count)
        SidebarProbeTrace.event("fixture created")
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
            _ = try #require(markers.first {
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
            SidebarProbeTrace.event("window readiness entered: visible=\(window.isVisible), routingInstalled=\(session.routing.openDocument != nil)")
            try await SidebarNativeDriver.afterUpdate(window) {
                window.isVisible && session.routing.openDocument != nil
            }
            SidebarProbeTrace.event("window ready; awaiting initial map work")
            await map.waitUntilIdle()
            SidebarProbeTrace.event("initial map work finished; laying out before accessibility reads")
            window.contentView?.layoutSubtreeIfNeeded()
            let groupTitle = PlaceGroup.spawner.name(in: session.resources.gameNames)
            let windowTitle = window.title
            // Keep AX messaging off the main actor, whose accessibility server answers the reads.
            // Only value records cross back; the AX objects remain in this detached client.
            let capture = await Task.detached {
                SidebarAXLookup.capture(windowTitle: windowTitle, groupTitle: groupTitle)
            }.value
            for line in capture.records { SidebarProbeTrace.event("lookup diagnostic " + line) }
            SidebarProbeTrace.event("locating native sidebar controls")
            _ = try SidebarNativeDriver(window: window, groupTitle: groupTitle)
            try #require(capture.complete, "The AX lookup capture must finish within its declared bounds")
            SidebarProbeTrace.event("native sidebar lookup finished; no actions or counters read")
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
        try Self.record([
            "kind": "outline", "groupTitle": groupTitle,
            "accessibleRows": rows.count, "nativeRows": outline.numberOfRows,
            "visibleRect": NSStringFromRect(outline.visibleRect),
            "windowFrame": NSStringFromRect(window.frame), "windowVisible": window.isVisible,
            "windowKey": window.isKeyWindow, "appActive": NSApp.isActive
        ])
        try #require(rows.count <= 128, "The diagnostic permits at most 128 accessible rows")
        SidebarDirectLookup.capture(rows: rows, outline: outline, groupTitle: groupTitle)
        var matches: [AnyObject] = []
        for (position, value) in rows.enumerated() {
            let row = value as AnyObject, index = row.accessibilityIndex?() ?? -1
            let validIndex = index >= 0 && index < outline.numberOfRows
            try Self.record([
                "kind": "row", "position": position, "index": index,
                "rect": validIndex ? NSStringFromRect(outline.rect(ofRow: index)) : "unavailable",
                "intersectsVisibleRect": validIndex && outline.visibleRect.intersects(outline.rect(ofRow: index))
            ])
            var matched = false
            for (nodeIndex, node) in try Self.nodes(in: row, budget: 64).enumerated() {
                let label = node.accessibilityLabel?() ?? ""
                let matchesTitle = label.contains(groupTitle)
                matched = matched || matchesTitle
                let value = Self.diagnosticValue(node, named: "accessibilityValue")
                let title = Self.diagnosticValue(node, named: "accessibilityTitle")
                let identifier = Self.diagnosticValue(node, named: "accessibilityIdentifier")
                let frame = node.accessibilityFrame?()
                try Self.record([
                    "kind": "node", "row": position, "node": nodeIndex,
                    "objectClass": String(reflecting: Swift.type(of: node)),
                    "selectorSupport": Self.selectorSupport(node),
                    "role": String(describing: node.accessibilityRole?()),
                    "label": String(label.prefix(256)), "labelLength": label.count,
                    "value": String(value.text.prefix(256)), "valueLength": value.text.count,
                    "valueType": value.type, "matchesTitle": matchesTitle,
                    "title": String(title.text.prefix(256)), "titleLength": title.text.count,
                    "titleType": title.type,
                    "identifier": String(identifier.text.prefix(256)), "identifierLength": identifier.text.count,
                    "identifierType": identifier.type,
                    "frame": frame.map(NSStringFromRect) ?? "unavailable"
                ])
            }
            if matched { matches.append(row) }
        }
        try Self.record(["kind": "lookup", "matches": matches.count])
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
        try await Self.afterUpdate(window, label: name, action: action, ready: ready)
        print("Sidebar probe observed: \(name), nativeRows=\(outline.numberOfRows), expanded=\(isExpanded), selectedRow=\(outline.selectedRow)")
    }

    static func afterUpdate(_ window: NSWindow, label: String = "window readiness",
                            action: () throws -> Void = {}, ready: () -> Bool) async throws {
        let (updates, updated) = AsyncStream.makeStream(of: Void.self)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: window, queue: .main) { _ in updated.yield(()) }
        var updateCount = 0
        var satisfied = false
        defer {
            NotificationCenter.default.removeObserver(observer)
            updated.finish()
            SidebarProbeTrace.event("\(label) wait ended: updates=\(updateCount), ready=\(satisfied), visible=\(window.isVisible)")
        }
        try action()
        // An already-visible, appeared document need not emit another window update.
        satisfied = ready()
        if satisfied {
            SidebarProbeTrace.event("\(label) already ready after action")
            return
        }
        window.viewsNeedDisplay = true
        SidebarProbeTrace.event("\(label) awaiting native update")
        for await _ in updates {
            updateCount += 1
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            satisfied = ready()
            if updateCount == 1 || satisfied {
                SidebarProbeTrace.event("\(label) update: count=\(updateCount), ready=\(satisfied), visible=\(window.isVisible)")
            }
            if satisfied { return }
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

    private static func diagnosticValue(_ node: AnyObject, named name: String) -> (type: String, text: String) {
        let selector = NSSelectorFromString(name)
        guard let object = node as? NSObject, object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue() else { return ("absent", "") }
        let text: String
        switch value {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        case let value as NSNumber: text = value.stringValue
        default: text = ""
        }
        return (String(reflecting: Swift.type(of: value)), text)
    }

    private static func selectorSupport(_ node: AnyObject) -> [String: Bool] {
        let names = ["accessibilityRole", "accessibilityLabel", "accessibilityChildren", "accessibilityFrame",
                     "accessibilityIndex", "accessibilityTitle", "accessibilityValue", "accessibilityIdentifier",
                     "accessibilityAttributeNames", "accessibilityAttributeValue:"]
        return Dictionary(uniqueKeysWithValues: names.map { name in
            (name, (node as? NSObject)?.responds(to: NSSelectorFromString(name)) == true)
        })
    }

    private static func record(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        SidebarProbeTrace.event("lookup diagnostic " + String(decoding: data, as: UTF8.self))
    }
}

/// Compare the two native read interfaces without changing the driver's original matcher.
/// SwiftUI exposes no API for inspecting the backing outline's accessibility rows or cell views.
private enum SidebarDirectLookup {
    private enum Failure: Error { case budget(String), shape(String) }

    private final class Reader {
        let route: String
        let clock = ContinuousClock()
        let deadline: ContinuousClock.Instant
        var reads = 0

        init(route: String) {
            self.route = route
            deadline = clock.now.advanced(by: .seconds(30))
        }

        func record(_ values: [String: Any]) throws {
            var fields = values
            fields["route"] = route
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            SidebarProbeTrace.event("lookup diagnostic " + String(decoding: data, as: UTF8.self))
        }

        func read(_ node: AnyObject, selector name: String, argument: String? = nil) throws -> AnyObject? {
            guard reads < 2_048, clock.now < deadline else { throw Failure.budget(route) }
            reads += 1
            let selector = NSSelectorFromString(name)
            guard let object = node as? NSObject, object.responds(to: selector) else { return nil }
            // These selectors all return Objective-C objects. Scalar and struct getters must
            // use their typed APIs instead of perform(_:), which assumes an object return.
            if let argument { return object.perform(selector, with: argument)?.takeUnretainedValue() }
            return object.perform(selector)?.takeUnretainedValue()
        }

        func capture(_ root: AnyObject, row: Int, view: String, groupTitle: String) throws {
            var pending = [(root, 0)], seen: Set<ObjectIdentifier> = [], matched = false
            while let (node, depth) = pending.popLast() {
                guard !seen.contains(ObjectIdentifier(node)) else { continue }
                guard seen.count < 64, depth <= 8 else { throw Failure.budget("\(route) row \(row)") }
                let position = seen.count
                seen.insert(ObjectIdentifier(node))
                let legacy = route == "legacy"
                var names: [String] = []
                if legacy, let raw = try read(node, selector: "accessibilityAttributeNames") {
                    guard let advertised = raw as? [String] else { throw Failure.shape("attribute names") }
                    guard advertised.count <= 64 else { throw Failure.budget("attribute names") }
                    names = advertised
                }
                let fields = legacy
                    ? ["role": kAXRoleAttribute, "title": kAXTitleAttribute,
                       "description": kAXDescriptionAttribute, "value": kAXValueAttribute, "index": kAXIndexAttribute]
                    : ["role": "accessibilityRole", "label": "accessibilityLabel",
                       "title": "accessibilityTitle", "value": "accessibilityValue"]
                var values: [String: Any] = [:]
                var matches: [String: Bool] = [:]
                for (field, name) in fields.sorted(by: { $0.key < $1.key }) {
                    let raw: AnyObject?
                    if legacy {
                        raw = names.contains(name) ? try read(node, selector: "accessibilityAttributeValue:", argument: name) : nil
                    } else {
                        raw = try read(node, selector: name)
                    }
                    let text: String
                    switch raw {
                    case let value as String: text = value
                    case let value as NSAttributedString: text = value.string
                    case let value as NSNumber: text = value.stringValue
                    default: text = ""
                    }
                    values[field] = ["text": String(text.prefix(256)), "length": text.count,
                                     "type": raw.map { String(reflecting: Swift.type(of: $0)) } ?? "absent"]
                    matches[field] = text.contains(groupTitle)
                }
                let matchesGroup = matches.values.contains(true)
                matched = matched || matchesGroup
                let selectors = legacy ? ["accessibilityAttributeNames", "accessibilityAttributeValue:"]
                    : Array(fields.values) + ["accessibilityChildren"]
                let support = Dictionary(uniqueKeysWithValues: selectors.map { name in
                    (name, (node as? NSObject)?.responds(to: NSSelectorFromString(name)) == true)
                })
                try record(["kind": "direct-node", "row": row, "view": view, "node": position, "depth": depth,
                            "objectClass": String(reflecting: Swift.type(of: node)), "attributeNames": names,
                            "selectorSupport": support, "values": values, "matches": matches, "matchesGroup": matchesGroup])
                let rawChildren: AnyObject?
                if legacy {
                    rawChildren = names.contains(kAXChildrenAttribute)
                        ? try read(node, selector: "accessibilityAttributeValue:", argument: kAXChildrenAttribute) : nil
                } else {
                    rawChildren = try read(node, selector: "accessibilityChildren")
                }
                if let rawChildren {
                    guard let children = rawChildren as? [Any] else { throw Failure.shape("children") }
                    guard children.count <= 64 else { throw Failure.budget("children") }
                    pending += children.reversed().map { ($0 as AnyObject, depth + 1) }
                }
            }
            try record(["kind": "direct-row", "row": row, "view": view,
                        "nodes": seen.count, "matchesGroup": matched])
        }
    }

    static func capture(rows: [Any], outline: NSOutlineView, groupTitle: String) {
        for route in ["legacy", "views"] {
            let reader = Reader(route: route)
            var complete = false
            do {
                try reader.record(["kind": "direct-start", "accessibleRows": rows.count,
                                   "nativeRows": outline.numberOfRows, "attributeBudget": 2_048,
                                   "deadlineSeconds": 30, "rowBudget": 128, "nodeBudgetPerRoot": 64, "depthLimit": 8])
                guard rows.count <= 128, outline.numberOfRows <= 128 else { throw Failure.budget("rows") }
                if route == "legacy" {
                    for (row, node) in rows.enumerated() {
                        try reader.capture(node as AnyObject, row: row, view: "accessibility", groupTitle: groupTitle)
                    }
                } else {
                    for row in 0..<outline.numberOfRows {
                        // Observe only views already made by the normal layout. A missing view
                        // is a recorded fact, never permission to materialize another row.
                        let views = [("row", outline.rowView(atRow: row, makeIfNecessary: false) as NSView?),
                                     ("cell", outline.view(atColumn: 0, row: row, makeIfNecessary: false))]
                        for (kind, view) in views {
                            try reader.record(["kind": "direct-view", "row": row, "view": kind, "available": view != nil])
                            if let view { try reader.capture(view, row: row, view: kind, groupTitle: groupTitle) }
                        }
                    }
                }
                complete = true
            } catch {
                try? reader.record(["kind": "direct-error", "error": String(describing: error)])
            }
            try? reader.record(["kind": "direct-complete", "complete": complete, "attributeReads": reader.reads])
        }
    }
}

/// Read-only diagnostic client. It never selects a row, expands a group or activates a window.
private nonisolated enum SidebarAXLookup {
    nonisolated struct Capture: Sendable {
        let records: [String]
        let complete: Bool
    }
    private nonisolated enum Failure: Error {
        case budget(String), deadline, attribute(String, Int32), shape(String), windowIdentity
    }

    private nonisolated final class Reader {
        let clock = ContinuousClock()
        let deadline: ContinuousClock.Instant
        var reads = 0
        var records: [String] = []

        init() { deadline = clock.now.advanced(by: .seconds(30)) }

        func record(_ values: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            records.append(String(decoding: data, as: UTF8.self))
        }

        func attribute(_ element: AXUIElement, _ name: String) throws -> (status: Int32, value: CFTypeRef?) {
            guard reads < 2_048 else { throw Failure.budget("attribute reads: limit=2048, next=\(name)") }
            guard clock.now < deadline else { throw Failure.deadline }
            reads += 1
            // Apple's timeout is per AX object; setting it on the application does not
            // bound messages to the window, rows or their children.
            let timeoutStatus = AXUIElementSetMessagingTimeout(element, 0.25)
            guard timeoutStatus == .success else { throw Failure.attribute("messagingTimeout", timeoutStatus.rawValue) }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (status.rawValue, value)
        }

        func elements(_ element: AXUIElement, _ name: String, limit: Int, context: String) throws -> [AXUIElement] {
            let result = try attribute(element, name)
            // Leaves need not expose children. Required window/row collections keep their errors.
            if name == kAXChildrenAttribute,
               result.status == AXError.noValue.rawValue || result.status == AXError.attributeUnsupported.rawValue { return [] }
            guard result.status == AXError.success.rawValue else { throw Failure.attribute(name, result.status) }
            guard let values = result.value as? [AXUIElement] else { throw Failure.shape(name) }
            guard values.count <= limit else {
                throw Failure.budget("\(context), \(name): count=\(values.count), limit=\(limit)")
            }
            return values
        }

        func text(_ element: AXUIElement, _ name: String) throws -> (status: Int32, text: String, type: String) {
            let result = try attribute(element, name)
            return (result.status, result.value as? String ?? "",
                    result.value.map { String(reflecting: Swift.type(of: $0)) } ?? "absent")
        }

        func outlines(in window: AXUIElement) throws -> [AXUIElement] {
            var pending = [(window, 0)], seen: [AXUIElement] = [], outlines: [AXUIElement] = []
            while let (element, depth) = pending.popLast() {
                guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                guard seen.count < 512 else { throw Failure.budget("outline search nodes: limit=512") }
                guard depth <= 12 else { throw Failure.budget("outline search depth: actual=\(depth), limit=12") }
                seen.append(element)
                let role = try text(element, kAXRoleAttribute)
                guard role.status == AXError.success.rawValue else { throw Failure.attribute(kAXRoleAttribute, role.status) }
                if role.text == kAXOutlineRole {
                    outlines.append(element)
                } else {
                    pending += try elements(element, kAXChildrenAttribute, limit: 128,
                        context: "outline search role=\(role.text)").reversed().map { ($0, depth + 1) }
                }
            }
            try record(["kind": "ax-outline-search", "visited": seen.count, "outlines": outlines.count])
            return outlines
        }

        func captureRow(_ row: AXUIElement, outline: Int, position: Int, groupTitle: String) throws -> Bool {
            var pending = [(row, 0)], seen: [AXUIElement] = [], matched = false
            while let (element, depth) = pending.popLast() {
                guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                guard seen.count < 64 else { throw Failure.budget("row nodes: row=\(position), limit=64") }
                guard depth <= 8 else { throw Failure.budget("row depth: row=\(position), actual=\(depth), limit=8") }
                let node = seen.count
                seen.append(element)
                let role = try text(element, kAXRoleAttribute)
                let title = try text(element, kAXTitleAttribute)
                let description = try text(element, kAXDescriptionAttribute)
                let value = try text(element, kAXValueAttribute)
                let matchesTitle = title.text.contains(groupTitle)
                let matchesDescription = description.text.contains(groupTitle)
                let matchesValue = value.text.contains(groupTitle)
                let matchesGroup = matchesTitle || matchesDescription || matchesValue
                matched = matched || matchesGroup
                try record([
                    "kind": "ax-node", "outline": outline, "row": position, "node": node,
                    "role": role.text, "roleStatus": role.status,
                    "title": String(title.text.prefix(256)), "titleLength": title.text.count, "titleStatus": title.status,
                    "description": String(description.text.prefix(256)), "descriptionLength": description.text.count,
                    "descriptionStatus": description.status,
                    "value": String(value.text.prefix(256)), "valueLength": value.text.count,
                    "valueStatus": value.status, "valueType": value.type,
                    "matchesTitle": matchesTitle, "matchesDescription": matchesDescription,
                    "matchesValue": matchesValue, "matchesGroup": matchesGroup
                ])
                pending += try elements(element, kAXChildrenAttribute, limit: 64,
                    context: "row=\(position), node=\(node), role=\(role.text)").reversed().map { ($0, depth + 1) }
            }
            try record(["kind": "ax-row", "outline": outline, "row": position, "nodes": seen.count, "matchesGroup": matched])
            return matched
        }
    }

    static func capture(windowTitle: String, groupTitle: String) -> Capture {
        let reader = Reader()
        var complete = false
        do {
            let app = AXUIElementCreateApplication(getpid())
            try reader.record(["kind": "ax-start", "windowTitle": windowTitle, "groupTitle": groupTitle,
                               "processTrusted": AXIsProcessTrusted(),
                               "messagingTimeoutSeconds": 0.25, "deadlineSeconds": 30, "attributeBudget": 2_048])
            for name in [kAXChildrenAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                let result = try reader.attribute(app, name)
                var fields: [String: Any] = ["kind": "ax-application", "attribute": name, "status": result.status,
                    "valueType": result.value.map { String(reflecting: Swift.type(of: $0)) } ?? "absent"]
                if let elements = result.value as? [AXUIElement] {
                    fields["elementCount"] = elements.count
                } else if let value = result.value {
                    fields["isAXElement"] = CFGetTypeID(value) == AXUIElementGetTypeID()
                }
                try reader.record(fields)
            }
            let windows = try reader.elements(app, kAXWindowsAttribute, limit: 16, context: "application windows")
            var matching: [AXUIElement] = []
            for (position, window) in windows.enumerated() {
                let title = try reader.text(window, kAXTitleAttribute)
                let matches = title.status == AXError.success.rawValue && title.text == windowTitle
                try reader.record(["kind": "ax-window", "position": position,
                                   "title": String(title.text.prefix(256)), "titleLength": title.text.count,
                                   "titleStatus": title.status, "matchesTarget": matches])
                if matches { matching.append(window) }
            }
            try reader.record(["kind": "ax-window-lookup", "windows": windows.count, "matches": matching.count])
            // This test opens one synthetic document. Ambiguous titles are a setup failure,
            // never permission to inspect a different window or to relax the lookup.
            guard matching.count == 1, let window = matching.first else { throw Failure.windowIdentity }
            let outlines = try reader.outlines(in: window)
            for (outlineIndex, outline) in outlines.enumerated() {
                let rows = try reader.elements(outline, kAXRowsAttribute, limit: 128,
                    context: "outline=\(outlineIndex), role=\(kAXOutlineRole)")
                try reader.record(["kind": "ax-outline", "outline": outlineIndex, "rows": rows.count])
                var matchingRows: [Int] = []
                for (position, row) in rows.enumerated() {
                    if try reader.captureRow(row, outline: outlineIndex, position: position, groupTitle: groupTitle) {
                        matchingRows.append(position)
                    }
                }
                try reader.record(["kind": "ax-lookup", "outline": outlineIndex, "matchingRows": matchingRows])
            }
            complete = true
        } catch {
            try? reader.record(["kind": "ax-error", "error": String(describing: error)])
        }
        try? reader.record(["kind": "ax-complete", "complete": complete, "attributeReads": reader.reads])
        return Capture(records: reader.records, complete: complete)
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

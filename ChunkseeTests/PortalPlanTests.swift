import ChunkseeKit
import CoreGraphics
import Foundation
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores, .timeLimit(.minutes(1))) struct PortalPlanTests {
    @Test func matchingCoordinatesAndHeightUseTheSharedPortalRules() throws {
        let entrance = NetherPortal.Block(x: -9, y: 64, z: -1)
        let near = NetherPortal(dimension: NetherPortal.nether, blocks: [.init(x: -2, y: 60, z: -1)])
        let high = NetherPortal(dimension: NetherPortal.nether, blocks: [.init(x: -2, y: 100, z: -1)])
        let plan = try #require(PortalPlan(entrance: entrance, dimension: NetherPortal.overworld,
                                          portals: [NetherPortal.nether: [high, near]]))
        #expect(plan.targetDimension == NetherPortal.nether)
        #expect(plan.destination == .init(x: -2, y: 64, z: -1))
        #expect(plan.link == .portal(near, block: near.entry))
        let higher = try #require(PortalPlan(entrance: .init(x: -9, y: 99, z: -1), dimension: NetherPortal.overworld,
                                            portals: [NetherPortal.nether: [high, near]]))
        #expect(higher.link == .portal(high, block: high.entry))
        let reverse = try #require(PortalPlan(entrance: .init(x: -2, y: -13, z: 3), dimension: NetherPortal.nether, portals: [:]))
        #expect(reverse.targetDimension == NetherPortal.overworld)
        #expect(reverse.destination == .init(x: -16, y: -13, z: 24))
        for dimension in ["minecraft:the_end", "custom:caves"] {
            #expect(PortalPlan(entrance: entrance, dimension: dimension, portals: [:]) == nil)
        }
    }

    @Test func unreadPortalDataIsNotAnEmptyDestination() throws {
        let entrance = NetherPortal.Block(x: 80, y: 64, z: 160)
        let destination = NetherPortal.Block(x: 10, y: 64, z: 20)
        let unread = try #require(PortalPlan(entrance: entrance, dimension: NetherPortal.overworld, portals: [:]))
        #expect(unread.destination == destination && unread.link == nil)
        let empty = try #require(PortalPlan(entrance: entrance, dimension: NetherPortal.overworld, portals: [NetherPortal.nether: []]))
        #expect(empty.link == .wouldCreateNewPortal(destination: destination))
        let far = NetherPortal(dimension: NetherPortal.nether, blocks: [.init(x: 100, y: 64, z: 20)])
        let outside = try #require(PortalPlan(entrance: entrance, dimension: NetherPortal.overworld,
                                             portals: [NetherPortal.nether: [far]]))
        #expect(outside.link == .wouldCreateNewPortal(destination: destination))
    }

    @Test func aDraftRequiresXYZAndDoesNotReplaceAnInterveningEdit() throws {
        let column = try #require(MapCoordinates(point: CGPoint(x: -8.7, y: -5.2)))
        let draft = PortalPlanDraft(dimension: NetherPortal.overworld, column: column, height: nil)
        #expect(draft.coordinates == "-9 -6" && draft.entrance == nil)
        draft.fillHeight(nil)
        #expect(draft.entrance == nil)
        // A native text field can write its initial value back without an edit.
        let initial = draft.coordinates
        draft.coordinates = initial
        draft.fillHeight(-13)
        #expect(draft.coordinates == "-9 -13 -6")
        #expect(draft.entrance == .init(x: -9, y: -13, z: -6))
        for text in ["", "1 2", "1 NaN 2", "1.5 64 2", "2147483648 64 0", "0 \(Int.max) 0"] {
            draft.coordinates = text
            #expect(draft.entrance == nil)
        }
        draft.coordinates = "−9 0 +3"
        #expect(draft.entrance == .init(x: -9, y: 0, z: 3))

        let edited = PortalPlanDraft(dimension: NetherPortal.overworld, column: column, height: nil)
        let original = edited.coordinates
        edited.coordinates = "100 70 100"
        edited.coordinates = original
        edited.fillHeight(2)
        #expect(edited.coordinates == original && edited.entrance == nil)
    }

    @Test func mapPlanningUsesTheDisplayedHeightWithoutChangingSelectionAndDropsOldReads() async throws {
        let url = try TestWorld.make(chunks: [TestWorld.chunk(x: -1, z: 0,
            palette: ["minecraft:air", "minecraft:stone"]) { _, y, _ in y <= 2 ? 1 : 0 }])
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make()
        let session = try await WorldSession.open(url, names: PlayerNames(defaults: defaults), defaults: defaults, cacheRoot: nil)
        do {
            let map = try #require(session.map)
            map.viewport = MapViewport(center: CGPoint(x: -8.7, y: 0.3), scale: 4)
            let viewport = map.viewport
            session.selection.inspector = .world
            session.annotations.planPortal()
            let plan = try #require(session.annotations.portalDraft)
            await map.waitForCoordinateReads()
            #expect(plan.entrance == .init(x: -9, y: 2, z: 0))
            #expect(session.selection.sidebarSelection == .worldInfo && session.selection.inspector == .world)
            #expect(map.viewport == viewport && session.savedPlaces.all.isEmpty)

            session.annotations.planPortal()
            let replaced = try #require(session.annotations.portalDraft)
            session.annotations.planPortal(at: CGPoint(x: 12.8, y: -4.1), y: 48.9)
            let replacement = try #require(session.annotations.portalDraft)
            await map.waitForCoordinateReads()
            #expect(replaced.entrance == nil)
            #expect(session.annotations.portalDraft === replacement && replacement.entrance == .init(x: 12, y: 48, z: -5))

            session.annotations.planPortal()
            let dismissed = try #require(session.annotations.portalDraft)
            session.annotations.portalDraft = nil
            await map.waitForCoordinateReads()
            #expect(dismissed.entrance == nil && session.annotations.portalDraft == nil)

            session.annotations.planPortal()
            let closing = try #require(session.annotations.portalDraft)
            session.close()
            await session.waitUntilClosed()
            #expect(closing.entrance == nil && map.unfinishedCoordinateReads == 0)
            #expect(!session.annotations.canPlanPortal(at: .zero, in: NetherPortal.overworld))
            session.annotations.portalDraft = nil
            session.annotations.planPortal(at: .zero, in: NetherPortal.overworld, y: 64)
            #expect(session.annotations.portalDraft == nil)
        } catch {
            session.close()
            await session.waitUntilClosed()
            throw error
        }
    }
}

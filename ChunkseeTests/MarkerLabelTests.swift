import ChunkseeKit
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MarkerLabelTests {
    private typealias Candidate = MarkerLabelLayout.Candidate
    private let frame = CGRect(x: 100, y: 100, width: 90, height: 20)

    @Test func priorityKeepsTheSelectedItemThenPlayersThenNamedPets() {
        let priorities: [MarkerLabelLayout.Priority] = [.other, .namedPet, .player, .selected]
        var labels = priorities.enumerated().map { Candidate(id: "\($0)", priority: $1, frame: frame) }
        while !labels.isEmpty {
            #expect(MarkerLabelLayout.visibleIndices(labels) == [labels.count - 1])
            labels.removeLast()
        }
    }

    @Test func equalPriorityUsesIdentityRatherThanScanOrder() {
        let a = Candidate(id: "a", priority: .other, frame: frame)
        let b = Candidate(id: "b", priority: .other, frame: frame)
        for labels in [[a, b], [b, a]] {
            #expect(MarkerLabelLayout.visibleIndices(labels).map { labels[$0].id } == ["a"])
        }
    }

    @Test func pillsKeepClearSpaceAcrossPositiveAndNegativeBucketEdges() {
        for boundary: CGFloat in [-256, 0, 256] {
            let a = Candidate(id: "a", priority: .other, frame: CGRect(x: boundary - 21, y: -10, width: 20, height: 20))
            let b = Candidate(id: "b", priority: .other, frame: CGRect(x: boundary + 1, y: -10, width: 20, height: 20))
            let c = Candidate(id: "c", priority: .other, frame: CGRect(x: boundary + 40, y: -10, width: 20, height: 20))
            #expect(MarkerLabelLayout.visibleIndices([a, b, c]) == [0, 2])
        }
    }

    @Test func unusuallyLargeFramesStillParticipateAndNonfiniteFramesAreIgnored() {
        let wide = Candidate(id: "a", priority: .other, frame: CGRect(x: -2_000, y: 100, width: 4_000, height: 20))
        let normal = Candidate(id: "b", priority: .other, frame: frame)
        #expect(MarkerLabelLayout.visibleIndices([wide, normal]) == [0])
        let selected = Candidate(id: "b", priority: .selected, frame: frame)
        #expect(MarkerLabelLayout.visibleIndices([wide, selected]) == [1])
        let invalid = Candidate(id: "invalid", priority: .selected, frame: .infinite)
        #expect(MarkerLabelLayout.visibleIndices([invalid, normal]) == [1])
    }

    @Test func crowdedMarkersKeepOneLabelPerPositionAndNoOverlaps() {
        let labels = (0..<11_000).map { i in
            Candidate(id: "marker-\(i)", priority: .other,
                      frame: CGRect(x: (i % 100) * 40, y: 0, width: 30, height: 16))
        }
        let visible = MarkerLabelLayout.visibleIndices(labels).map { labels[$0].frame }
        #expect(visible.count == 100)
        for i in visible.indices {
            for j in visible.indices where j > i {
                #expect(!visible[i].intersects(visible[j]))
            }
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func realCaptionMeasurementsAndDrawingUseTheSameWinner(_ scheme: ColorScheme) throws {
        func render(includeOther: Bool) throws -> Data {
            let renderer = ImageRenderer(content: Canvas { context, _ in
                let point = CGPoint(x: 140, y: 20)
                let player = MarkerStyle.player(.player, outdated: false, selected: false)
                    .label("Nearby player", id: "player", priority: .player, at: point, scale: 2, in: context)!
                let pet = MarkerStyle.creature(.pet, selected: true)
                    .label("Selected pet", id: "pet", priority: .selected, at: point, scale: 2, in: context)!
                #expect(player.placement.frame.intersects(pet.placement.frame))
                let labels = includeOther ? [player, pet] : [pet]
                #expect(MarkerLabelLayout.visibleIndices(labels.map(\.placement)).map { labels[$0].placement.id } == ["pet"])
                MarkerLabel.draw(labels, in: context)
            }.frame(width: 280, height: 100).background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            if includeOther { Attachment.record(image, named: "selected-label-\(scheme).png", as: .png) }
            return try #require(image.dataProvider?.data) as Data
        }
        #expect(try render(includeOther: true) == render(includeOther: false))
    }

    @Test func mapExportKeepsLabelsStableWithoutRemovingMarkersOrVoiceOverNames() throws {
        let url = try TestWorld.make(chunks: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let dimension = try #require(World(contentsOf: url).dimension("overworld"))
        let map = MapModel(work: BackgroundWork(), dimension: dimension, center: .zero)
        defer { map.close() }
        map.viewport.scale = 0.0625
        let markers = ["a", "b"].map {
            MapMarker(id: $0, playerID: UUID(), kind: .player, position: .zero,
                      y: 64, label: "Player " + $0, isOutdated: false)
        }
        var content = MapContent(); content.players = markers
        let size = CGSize(width: 400, height: 200)
        let before = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
        content.players.reverse()
        let after = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
        #expect(before.data == after.data)
        // Closing the inspector removes its body highlight but leaves the sidebar row selected.
        // That selected row must still win the label collision.
        content.selectedItem = .player(markers[1].playerID)
        let selected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
        #expect(selected.data != before.data)
        content.selectedItem = nil
        content.players[0].id = "0"
        let expected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
        #expect(selected.data == expected.data)
        let names = content.accessibleLocations(viewport: map.viewport, size: size).map(\.name)
        #expect(Set(names) == ["Player a", "Player b"])
        #expect(content.target(at: CGPoint(x: 200, y: 100), viewport: map.viewport, size: size) != nil)
    }
}

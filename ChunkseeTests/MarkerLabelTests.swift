import ChunkseeKit
import ImageIO
import SwiftUI
import Testing
@testable import ChunkseeTestHost

@Suite(.isolatedStores) struct MarkerLabelTests {
    private typealias Candidate = MarkerLabelLayout.Candidate
    private let frame = CGRect(x: 100, y: 100, width: 90, height: 20)

    /// Compare displayed 8-bit pixels, allowing the one-unit RGB variation observed in
    /// independent ImageRenderer runs. Alpha, dimensions and every larger change stay exact.
    private func matchingPixels(_ a: CGImage, _ b: CGImage) throws -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        func rgba(_ image: CGImage) throws -> Data {
            let row = image.width * 4
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: row, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try #require(context.data), count: row * image.height)
        }
        let left = try rgba(a), right = try rgba(b)
        return zip(left, right).enumerated().allSatisfy { index, bytes in
            index % 4 == 3 ? bytes.0 == bytes.1 : abs(Int(bytes.0) - Int(bytes.1)) <= 1
        }
    }

    private func matchingPixels(_ a: MapImage, _ b: MapImage) throws -> Bool {
        func decode(_ image: MapImage) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        return try matchingPixels(decode(a), decode(b))
    }

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
        func render(includeOther: Bool, includeSelected: Bool = true) throws -> CGImage {
            let renderer = ImageRenderer(content: Canvas { context, _ in
                let point = CGPoint(x: 140, y: 20)
                let player = MarkerStyle.player(.player)
                    .label("Nearby player", id: "player", priority: .player, at: point, scale: 2, in: context)!
                let pet = MarkerStyle.creature(.pet)
                    .label("Selected pet", id: "pet", priority: .selected, at: point, scale: 2, in: context)!
                #expect(player.placement.frame.intersects(pet.placement.frame))
                let labels = (includeOther ? [player] : []) + (includeSelected ? [pet] : [])
                if includeSelected {
                    #expect(MarkerLabelLayout.visibleIndices(labels.map(\.placement)).map { labels[$0].placement.id } == ["pet"])
                }
                MarkerLabel.draw(labels, in: context)
            }.frame(width: 280, height: 100).background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            if includeOther { Attachment.record(image, named: "selected-label-\(scheme).png", as: .png) }
            return image
        }
        let actual = try render(includeOther: true), expected = try render(includeOther: false)
        #expect(try matchingPixels(actual, expected))
        // Removing the winning label or drawing the wrong winner must still fail the comparison.
        #expect(try !matchingPixels(actual, render(includeOther: true, includeSelected: false)))
        #expect(try !matchingPixels(actual, render(includeOther: false, includeSelected: false)))
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
        #expect(try matchingPixels(before, after))
        // Closing the inspector removes its body highlight but leaves the sidebar row selected.
        // That selected row must still win the label collision.
        content.selectedItem = .player(markers[1].playerID)
        let selected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
        #expect(try !matchingPixels(selected, before))
        content.selectedItem = nil
        content.players[0].id = "0"
        let expected = try #require(MapImage.render(map, content: content, portalStatus: { _ in nil }, size: size, scale: 2))
        #expect(try matchingPixels(selected, expected))
        let names = content.accessibleLocations(viewport: map.viewport, size: size).map(\.name)
        #expect(Set(names) == ["Player a", "Player b"])
        #expect(content.target(at: CGPoint(x: 200, y: 100), viewport: map.viewport, size: size) != nil)
    }
}

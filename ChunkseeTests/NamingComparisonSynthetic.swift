import ChunkseeKit
import Foundation
import SwiftUI
import Testing
@testable import ChunkseeTestHost

extension NamingComparison {
    /// Proposed coverage supplement: the copied world has no custom-named creature.
    /// This synthetic drawing correctness check is separate from all copied-world performance.
    static func syntheticNames(_ gameNames: GameNames, to folder: URL) throws {
        let literals = ["\"Snow\"", "{\"text\":\"Literal\"}"]
        let identities = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"]
        let markers = try literals.enumerated().map { index, literal in
            try #require(CreatureMarker(Creature(id: "minecraft:wolf", x: Double(index * 80), y: 64, z: 0,
                customName: literal, uuid: try #require(UUID(uuidString: identities[index]))),
                dimension: "minecraft:overworld"))
        }
        for (scale, selected) in [(1.0, false), (1.0, true), (2.0, false), (8.0, false)] {
            let viewport = MapViewport(center: CGPoint(x: 40, y: 0), scale: scale)
            var content = MapContent(gameNames: gameNames)
            content.creatures = markers
            if selected { content.selection = .creature(markers[0]) }
            let drawingContent = content
            let recorder = NamingComparisonTrace.Recorder()
            try #require(NamingComparisonTrace.recorder == nil)
            NamingComparisonTrace.recorder = recorder
            defer { NamingComparisonTrace.recorder = nil }
            let canvas = Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                MapView.drawOverlays(viewport: viewport, regions: [], content: drawingContent,
                    portalStatus: { _ in nil }, in: context, size: size)
            }
            .frame(width: NamingComparisonCapture.size.width, height: NamingComparisonCapture.size.height)
            .environment(\.locale, NamingComparisonCapture.locale)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            let image = renderer.cgImage
            let png = image.flatMap(MapImage.png)
            let key = "scale-\(Int(scale))-selected-\(selected)"
            var artifacts = [
                "caption-passes.json": try NamingComparisonCapture.encoded(recorder.passes),
                "caption-state.json": try NamingComparisonCapture.json([
                    "unfinishedPass": recorder.hasUnfinishedPass, "imageProduced": png != nil,
                ]),
                "synthetic-facts.json": try NamingComparisonCapture.json([
                           "literalNames": literals, "markerIDs": markers.map(\.id),
                           "scale": scale, "selected": selected,
                           "scope": "Synthetic correctness only; not copied-world performance",
                ]),
            ]
            artifacts["render.png"] = png?.data
            try write(artifacts, to: folder.appendingPathComponent(key))
            try #require(png != nil)
            try #require(!recorder.hasUnfinishedPass && !recorder.passes.isEmpty)
            for pass in recorder.passes {
                if scale == 1 && !selected {
                    try #require(pass.formatted.isEmpty && pass.drawnIDs.isEmpty)
                } else {
                    let wanted = selected ? [0] : [0, 1]
                    for index in wanted {
                        let id = "creature-" + markers[index].id
                        try #require(pass.formatted.contains { $0.id == id && $0.text == literals[index] })
                        try #require(pass.drawnIDs.contains(id))
                    }
                }
            }
        }
    }
}

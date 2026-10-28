import ChunkseeKit
import ChunkseeIndex
import CoreGraphics
import Foundation

/// A presentation key keeps every independently readable appearance field. Two fish with the
/// same pattern but different colors, for example, remain separate inspector/filter rows.
nonisolated struct MobAppearance: Hashable, Sendable {
    struct Trait: Hashable, Sendable {
        let name: String
        let value: String
    }

    let variant: String?
    let markings: String?
    let traits: [Trait]

    init(_ appearance: CreatureAppearance?) {
        variant = appearance?.variant
        markings = appearance?.markings
        traits = (appearance?.traits ?? [:]).sorted { $0.key < $1.key }.map { Trait(name: $0.key, value: $0.value) }
    }

    var isRecorded: Bool { variant != nil || markings != nil || !traits.isEmpty }

    var saved: CreatureAppearance {
        CreatureAppearance(variant: variant, markings: markings,
            traits: traits.isEmpty ? nil : Dictionary(uniqueKeysWithValues: traits.map { ($0.name, $0.value) }))
    }

    func name(for species: String) -> String {
        isRecorded ? PetDetailText.appearance(saved) : String(localized: "Not recorded")
    }

    fileprivate var ordering: [String] { [variant ?? "", markings ?? ""] + traits.flatMap { [$0.name, $0.value] } }
}

/// The sidebar's type/appearance projection is prepared once with each immutable creature
/// snapshot. Member offsets share the marker array instead of copying every mob into each view.
nonisolated struct MobTypes: Sendable {
    struct Variant: Identifiable, Sendable {
        let appearance: MobAppearance
        let count: Int
        var id: MobAppearance { appearance }
    }

    struct Kind: Identifiable, Sendable {
        let id: String
        let name: String
        let variants: [Variant]
        fileprivate let members: [Int]
        var count: Int { members.count }

        func contains(_ appearance: MobAppearance) -> Bool { variants.contains { $0.appearance == appearance } }
    }

    let revision = UUID()
    let kinds: [Kind]
    let points: PointMarkers<CreatureMarker>
    private var markers: [CreatureMarker] { points.all }
    private let markerOffsets: [String: Int]
    private let kindOffsets: [String: Int]
    private let specialOffsets: [Int]

    init(_ markers: [CreatureMarker] = []) {
        points = PointMarkers(markers)
        var members: [String: [Int]] = [:], offsets: [String: Int] = [:], special: [Int] = []
        for (offset, marker) in markers.enumerated() {
            offsets[marker.id] = offsets[marker.id] ?? offset
            members[marker.creature.id, default: []].append(offset)
            if marker.group != .mob { special.append(offset) }
        }
        markerOffsets = offsets
        specialOffsets = special
        let names = members.keys.map { (id: $0, name: ReadableName.from($0)) }
        let collisions = Dictionary(grouping: names, by: \.name)
        kinds = names.sorted { ($0.name, $0.id) < ($1.name, $1.id) }.map { kind in
            let indices = members[kind.id]!
            var counts: [MobAppearance: Int] = [:]
            for offset in indices { counts[MobAppearance(markers[offset].creature.appearance), default: 0] += 1 }
            let variants = counts.map { Variant(appearance: $0.key, count: $0.value) }.sorted {
                $0.appearance.ordering.lexicographicallyPrecedes($1.appearance.ordering)
            }
            let name = collisions[kind.name]?.count == 1 ? kind.name : String(localized: "\(kind.name) (\(kind.id))")
            return Kind(id: kind.id, name: name, variants: variants, members: indices)
        }
        kindOffsets = Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($0.element.id, $0.offset) })
    }

    var specialCreatures: [CreatureMarker] { specialOffsets.map { markers[$0] } }
    var hasSpecialCreatures: Bool { !specialOffsets.isEmpty }
    func marker(_ id: String) -> CreatureMarker? { markerOffsets[id].map { markers[$0] } }
    func kind(_ id: String) -> Kind? { kindOffsets[id].map { kinds[$0] } }

    /// Native disclosure rows request this only when expanded. Sorting stays off the UI actor
    /// and ties keep their saved identity, so selection does not jump between equal positions.
    @concurrent
    func nearest(_ id: String, to origin: CGPoint) async throws -> [CreatureMarker] {
        try Task.checkCancellation()
        guard let kind = kind(id) else { return [] }
        let markers = points.all
        let ordered = kind.members.sorted {
            let a = markers[$0], b = markers[$1]
            let da = hypot(a.position.x - origin.x, a.position.y - origin.y)
            let db = hypot(b.position.x - origin.x, b.position.y - origin.y)
            return da == db ? a.id < b.id : da < db
        }
        try Task.checkCancellation()
        return ordered.map { markers[$0] }
    }
}

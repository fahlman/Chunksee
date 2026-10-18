import CoreGraphics
import Foundation

/// Where a world's map was left in each dimension, and which dimension was showing, kept in
/// `defaults` under the world's path as `["dimension": id, "views": [id: [x, z, scale]]]`.
struct RememberedViews {
    private let defaults: UserDefaults
    private let key: String

    init(world: URL, defaults: UserDefaults) {
        self.defaults = defaults
        key = "mapView." + world.standardizedFileURL.path
    }

    /// The dimension that was showing when the world was last left.
    var lastDimension: String? { defaults.dictionary(forKey: key)?["dimension"] as? String }

    func relocate(to world: URL) {
        let destination = RememberedViews(world: world, defaults: defaults)
        guard destination.key != key, let saved = defaults.dictionary(forKey: key) else { return }
        var merged = defaults.dictionary(forKey: destination.key) ?? [:]
        let views = (merged["views"] as? [String: [Double]] ?? [:]).merging(saved["views"] as? [String: [Double]] ?? [:]) { _, current in current }
        let depths = (merged["depths"] as? [String: [String: Int]] ?? [:]).merging(saved["depths"] as? [String: [String: Int]] ?? [:]) { _, current in current }
        merged.merge(saved) { _, current in current }
        merged["views"] = views
        merged["depths"] = depths
        defaults.set(merged, forKey: destination.key)
        defaults.removeObject(forKey: key)
    }

    func viewport(for dimension: String) -> MapViewport? {
        guard let view = (defaults.dictionary(forKey: key)?["views"] as? [String: [Double]])?[dimension], view.count == 3 else { return nil }
        return MapViewport(center: CGPoint(x: view[0], y: view[1]), scale: view[2])
    }

    func depth(for dimension: String) -> MapDepth {
        guard let value = (defaults.dictionary(forKey: key)?["depths"] as? [String: [String: Int]])?[dimension],
              let y = value["y"], let surface = value["surface"], surface == 0 || surface == 1 else { return MapDepth() }
        return MapDepth(y: y, isSurface: surface == 1)
    }

    /// Remembers `viewport` for `dimension`, and `selected` as the dimension showing.
    func save(_ viewport: MapViewport, for dimension: String, selected: String?, depth: MapDepth? = nil) {
        var saved = defaults.dictionary(forKey: key) ?? [:]
        var views = saved["views"] as? [String: [Double]] ?? [:]
        views[dimension] = [viewport.center.x, viewport.center.y, viewport.scale]
        saved["views"] = views
        if let depth {
            var depths = saved["depths"] as? [String: [String: Int]] ?? [:]
            depths[dimension] = ["y": depth.y, "surface": depth.isSurface ? 1 : 0]
            saved["depths"] = depths
        }
        saved["dimension"] = selected
        defaults.set(saved, forKey: key)
    }
}

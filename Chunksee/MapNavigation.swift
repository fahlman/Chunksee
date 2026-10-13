import CoreGraphics

/// A past view belongs to one dimension of one document.
nonisolated struct MapViewLocation: Equatable {
    var dimension: String
    var viewport: MapViewport
}

nonisolated struct MapNavigationHistory {
    private var previous: [MapViewLocation] = []
    private var following: [MapViewLocation] = []

    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !following.isEmpty }

    mutating func retainDimensions(_ dimensions: Set<String>) {
        previous.removeAll { !dimensions.contains($0.dimension) }
        following.removeAll { !dimensions.contains($0.dimension) }
    }

    mutating func record(_ location: MapViewLocation) {
        if previous.last != location { previous.append(location) }
        following.removeAll()
    }

    mutating func goBack(from current: MapViewLocation) -> MapViewLocation? {
        guard let destination = previous.popLast() else { return nil }
        following.append(current)
        return destination
    }

    mutating func goForward(from current: MapViewLocation) -> MapViewLocation? {
        guard let destination = following.popLast() else { return nil }
        previous.append(current)
        return destination
    }
}

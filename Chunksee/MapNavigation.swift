/// Past viewports of one dimension document; changing dimensions opens another document.
nonisolated struct MapNavigationHistory {
    private var previous: [MapViewport] = []
    private var following: [MapViewport] = []

    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !following.isEmpty }

    mutating func record(_ location: MapViewport) {
        if previous.last != location { previous.append(location) }
        following.removeAll()
    }

    mutating func goBack(from current: MapViewport) -> MapViewport? {
        guard let destination = previous.popLast() else { return nil }
        following.append(current)
        return destination
    }

    mutating func goForward(from current: MapViewport) -> MapViewport? {
        guard let destination = following.popLast() else { return nil }
        previous.append(current)
        return destination
    }
}

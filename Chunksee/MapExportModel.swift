import ChunkseeKit
import ImageIO
import Observation
import SwiftUI

/// One dimension's export request. The shared background-work owner drains it when the world closes.
@Observable
final class MapExportModel {
    nonisolated enum Area: CaseIterable, Hashable, Sendable {
        case visible, dimension, measured

        var title: LocalizedStringResource {
            switch self {
            case .visible: "Visible Area"
            case .dimension: "Whole Dimension"
            case .measured: "Measured Area"
            }
        }
    }

    nonisolated struct Options: Equatable, Sendable {
        var area = Area.visible
        var blocksPerPixel = 1
        var includesMarkers = true
        var includesGrid = false
    }

    var options: Options {
        didSet { if options != oldValue { cancel() } }
    }
    private var activeRuns = 0
    var isRunning: Bool { activeRuns > 0 }
    var isCancelling: Bool { isRunning && request == nil }
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var result: MapImage?
    private(set) var preview: CGImage?
    private(set) var error: String?
    private(set) var preparedPlan: MapExportPlan?
    private(set) var renderedDepth: MapDepth?
    private weak var source: WorldSession?
    private let work: BackgroundWork.Scope
    private var request: UUID?

    init(source: WorldSession) {
        self.source = source
        work = source.resources.backgroundWork.makeScope()
        options = Options(includesGrid: source.visibility.showsGrid)
    }

    func bounds(for area: Area) -> CGRect? {
        guard let source, let map = source.map else { return nil }
        switch area {
        case .visible:
            return map.shownSize.flatMap { MapExportPlan.visibleBounds(viewport: map.viewport, size: $0.size) }
        case .dimension:
            return MapViewport.bounds(of: map.availableRegions)
        case .measured:
            return MapExportPlan.measuredBounds(source.annotations.ruler)
        }
    }

    var plan: Result<MapExportPlan, any Error> {
        Result {
            guard let bounds = bounds(for: options.area) else { throw MapExportPlan.Failure.invalidArea }
            return try MapExportPlan(bounds: bounds, blocksPerPixel: options.blocksPerPixel)
        }
    }

    var isReadingContent: Bool {
        guard let source else { return false }
        return source.search.isIndexing || source.heatMap.isLoading || source.slimeChunks.isLoading
    }

    var canCreate: Bool {
        guard !isRunning, !work.isClosed, source?.isClosed == false, !isReadingContent,
              case .success(let plan) = plan, let map = source?.map else { return false }
        return !plan.viewport.visibleRegions(in: plan.size, among: map.availableRegions).isEmpty
    }

    func fitImage() {
        guard let bounds = bounds(for: options.area), let scale = MapExportPlan.blocksPerPixelChoices.first(where: {
            (try? MapExportPlan(bounds: bounds, blocksPerPixel: $0)) != nil
        }) else { return }
        options.blocksPerPixel = scale
    }

    func create(colorScheme: ColorScheme, locale: Locale) {
        guard canCreate, let source, let map = source.map, case .success(let plan) = plan else { return }
        cancel()
        let id = UUID()
        request = id
        activeRuns += 1
        preparedPlan = plan
        renderedDepth = map.depth
        var content = MapContent(session: source)
        content.showsGrid = options.includesGrid
        if !options.includesMarkers { content.removeMarkers() }
        let contentSnapshot = content, renderer = map.currentRenderer, regions = map.availableRegions, readTile = map.renderTile
        let portals = source.presentation.portalsByDimension
        let task = work.start(priority: .userInitiated) { [weak self] in
            defer { self?.activeRuns -= 1 }
            do {
                let image = try await MapImage.export(plan: plan, regions: regions, renderer: renderer, content: contentSnapshot,
                    portalStatus: { PortalLinkStatus.status(of: $0, portals: portals) }, colorScheme: colorScheme, locale: locale,
                    progress: { [weak self] finished, count in
                        guard self?.request == id else { return }
                        self?.completed = finished
                        self?.total = count
                    }, readTile: readTile)
                let preview = await Self.preview(image.data)
                guard !Task.isCancelled, self?.request == id, self?.source?.isClosed == false else { return }
                self?.result = image
                self?.preview = preview
            } catch is CancellationError {
                // A closed or replaced request cannot publish a partial image or an error.
            } catch {
                guard !Task.isCancelled, self?.request == id else { return }
                self?.error = error.localizedDescription
            }
        }
        if task == nil { activeRuns -= 1; cancel() }
    }

    func cancel() {
        request = nil
        work.cancel()
        result = nil
        preview = nil
        error = nil
        completed = 0
        total = 0
        preparedPlan = nil
        renderedDepth = nil
    }

    func close() { cancel(); work.close() }
    func waitUntilIdle() async { await work.waitUntilFinished() }

    @concurrent
    nonisolated private static func preview(_ data: Data) async -> sending CGImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 600,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension MapContent {
    /// Export options filter a value snapshot, never the live sidebar or selection.
    mutating func removeMarkers() {
        structures = []
        placePoints = .init()
        creaturePoints = .init()
        hits = []
        players = []
        savedPlaces = []
        selection = nil
        selectedItem = nil
        selectedHitID = nil
        selectedPlayerID = nil
        ruler = MapRuler()
    }
}

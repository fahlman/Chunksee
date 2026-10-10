import CoreServices
import Foundation

/// Reports files changed under a world folder while the game plays it, using FSEvents. Events
/// arrive on the main queue about a second after the change, already coalesced by the system.
/// FSEvents has no Swift API, so this wraps the C one.
final class WorldWatcher {
    private var stream: FSEventStreamRef?
    private let box: Box

    /// The C callback can't capture context, so the handler travels through `info` in a box.
    private final class Box {
        let handler: ([URL]) -> Void
        init(_ handler: @escaping ([URL]) -> Void) { self.handler = handler }
    }

    /// Starts watching `folder`; `handler` gets the changed files' URLs.
    init?(folder: URL, handler: @escaping ([URL]) -> Void) {
        box = Box(handler)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let urls = paths.prefix(count).map { URL(fileURLWithPath: $0) }
            // The stream's dispatch queue is the main queue.
            MainActor.assumeIsolated {
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler(urls)
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit { stop() }
}

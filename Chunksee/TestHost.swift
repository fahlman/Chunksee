#if CHUNKSEE_TEST_HOST
import SwiftUI

/// No stores or documents are created until a test supplies its isolated document factory.
@main
struct ChunkseeTestHost: App {
    var body: some Scene {
        WorldDocumentScene(isTerminating: { false }) { configuration in
            guard let makeDocument = TestDocumentWindows.makeDocument else { throw CancellationError() }
            return try makeDocument(configuration)
        }
        .restorationBehavior(.disabled)
        Settings { EmptyView() }
    }
}

enum TestDocumentWindows {
    static var makeDocument: ((URLDocumentConfiguration) throws -> WorldDocument)?
}
#endif

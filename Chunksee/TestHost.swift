#if CHUNKSEE_TEST_HOST
import SwiftUI

/// Unit tests load the production types without opening documents or creating the app's stores.
@main
struct ChunkseeTestHost: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
#endif

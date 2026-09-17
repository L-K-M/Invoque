import Foundation

/// Whether the process is running under XCTest.
///
/// Shared infrastructure so model-layer types (e.g. `Preferences`) don't reach
/// up to `AppDelegate` for test detection.
enum TestEnvironment {
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

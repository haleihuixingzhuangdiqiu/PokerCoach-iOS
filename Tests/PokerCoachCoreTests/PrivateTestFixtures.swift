import Foundation

/// Private screenshot/video fixtures are optional and never shipped in the public repository.
/// Environment overrides make the same tests usable without the original workspace layout.
enum PrivateTestFixtures {
    static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var workRoot: URL {
        configured("POKER_PRIVATE_FIXTURE_ROOT")
            ?? projectRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work")
    }
    static var screenshotRoot: URL {
        configured("POKER_PRIVATE_SCREENSHOT_DIR") ?? FileManager.default.temporaryDirectory
    }
    static var artifactRoot: URL {
        configured("POKER_TEST_ARTIFACT_DIR") ?? projectRoot.appendingPathComponent("work/test-artifacts")
    }
    static func file(_ path: String) -> URL { workRoot.appendingPathComponent(path) }
    private static func configured(_ variable: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

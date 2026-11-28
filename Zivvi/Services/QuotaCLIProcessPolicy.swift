import Foundation

enum QuotaCLIProcessPolicy {
    static var shouldSkipUserCLIProbes: Bool {
        shouldSkip(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments,
            diagnosticConfiguration: diagnosticConfiguration,
            isXCTestLoaded: NSClassFromString("XCTestCase") != nil
        )
    }

    static func shouldSkip(environment: [String: String],
                           arguments: [String],
                           diagnosticConfiguration: [String: String],
                           isXCTestLoaded: Bool) -> Bool {
        if environment["ZIVVI_DISABLE_QUOTA_PROBES"] == "1" { return true }
        if arguments.contains("--fake") { return true }
        if diagnosticConfiguration["--fake"] == "true" { return true }
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        return isXCTestLoaded
    }

    private static let diagnosticConfiguration: [String: String] = {
        guard let url = Bundle.main.url(forResource: "DiagnosticsConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return configuration
    }()
}

import Darwin
import Foundation
import XCTest
@testable import Zivvi

final class QuotaCLIProcessPolicyTests: XCTestCase {
    func testProductionLaunchKeepsUserCLIProbesEnabled() {
        XCTAssertFalse(QuotaCLIProcessPolicy.shouldSkip(
            environment: [:], arguments: [], diagnosticConfiguration: [:], isXCTestLoaded: false))
    }

    func testXCTestEnvironmentSkipsUserCLIProbes() {
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
            arguments: [], diagnosticConfiguration: [:], isXCTestLoaded: false))
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: ["XCTestBundlePath": "/tmp/ZivviTests.xctest"],
            arguments: [], diagnosticConfiguration: [:], isXCTestLoaded: false))
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: ["XCTestSessionIdentifier": "session"],
            arguments: [], diagnosticConfiguration: [:], isXCTestLoaded: false))
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: [:], arguments: [], diagnosticConfiguration: [:], isXCTestLoaded: true))
    }

    func testFakeAndExplicitOptOutSkipUserCLIProbes() {
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: [:], arguments: ["--fake"], diagnosticConfiguration: [:], isXCTestLoaded: false))
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: [:], arguments: [], diagnosticConfiguration: ["--fake": "true"], isXCTestLoaded: false))
        XCTAssertFalse(QuotaCLIProcessPolicy.shouldSkip(
            environment: [:], arguments: [], diagnosticConfiguration: ["--fake": "false"], isXCTestLoaded: false))
        XCTAssertTrue(QuotaCLIProcessPolicy.shouldSkip(
            environment: ["ZIVVI_DISABLE_QUOTA_PROBES": "1"],
            arguments: [], diagnosticConfiguration: [:], isXCTestLoaded: false))
    }

    func testTestProcessSkipsUserCLIProbes() async throws {
        guard QuotaCLIProcessPolicy.shouldSkipUserCLIProbes else {
            XCTFail("Quota CLI probes must be skipped in test processes")
            return
        }

        let antigravity = try await AntigravityQuotaClient.fetch(searchPaths: ["/nonexistent"])
        let codex = try await CodexQuotaClient.fetch(searchPaths: ["/nonexistent"])

        XCTAssertTrue(antigravity.isEmpty)
        XCTAssertTrue(codex.isEmpty)
    }

    func testAntigravityDrainsBothPipesBeforeChildExit() async throws {
        let executable = try makeQuotaFixture(#"""
        /bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null | /usr/bin/tr '\000' ' ' >&2
        /bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null | /usr/bin/tr '\000' ' '
        printf '%s\n' '{"groups":[{"label":"Test","buckets":[{"remainingFraction":0.5}]}]}'
        """#)
        let windows = try await AntigravityQuotaClient.query(executable: executable, timeout: .seconds(4))
        XCTAssertEqual(windows.map(\.remaining), [500])
    }

    func testAntigravityTimeoutAndCancellationReapTheCLI() async throws {
        let executable = try makeQuotaFixture(#"""
        trap '' TERM
        /bin/sleep 20 &
        printf '%s' "$!" > "$0.child"
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """#)
        let marker = executable.appendingPathExtension("pid")
        let child = executable.appendingPathExtension("child")
        do {
            _ = try await AntigravityQuotaClient.query(executable: executable, timeout: .seconds(2))
            XCTFail("Expected the quota query to time out")
        } catch AntigravityQuotaClient.Failure.failed { }
        try assertReaped(using: marker)
        try assertReaped(using: child)
        try FileManager.default.removeItem(at: marker)

        let query = Task { try await AntigravityQuotaClient.query(executable: executable, timeout: .seconds(6)) }
        defer { query.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (try? readPID(from: marker)) == nil {
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = ContinuousClock.now
        query.cancel()
        do {
            _ = try await query.value
            XCTFail("Expected the quota query to be cancelled")
        } catch is CancellationError { }
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        try assertReaped(using: marker)
        try assertReaped(using: child)
    }

    func testAntigravityReapsChildHoldingPipesAfterCLIExits() async throws {
        let executable = try makeQuotaFixture(#"""
        /bin/sleep 20 &
        printf '%s' "$!" > "$0.pid"
        printf '%s\n' '{"groups":[]}'
        """#)
        let windows = try await AntigravityQuotaClient.query(executable: executable, timeout: .seconds(4))
        XCTAssertTrue(windows.isEmpty)
        try assertReaped(using: executable.appendingPathExtension("pid"))
    }

    func testAntigravityClassifiesCLIFailureFromSupervisedExitStatus() async throws {
        let executable = try makeQuotaFixture(#"""
        printf '%s\n' 'Please login' >&2
        exit 7
        """#)
        do {
            _ = try await AntigravityQuotaClient.query(executable: executable, timeout: .seconds(4))
            XCTFail("Expected a sign-in failure")
        } catch AntigravityQuotaClient.Failure.notSignedIn { }
    }

    func testAntigravitySkipsUsageForOldOrUnknownVersions() async throws {
        for version in ["agy 1.1.10", "invalid version", "1.1.11-beta.1"] {
            let executable = try makeQuotaFixture(#"""
            printf 'unexpected usage' > "$0.usage"
            """#, version: version)
            do {
                _ = try await AntigravityQuotaClient.query(executable: executable, timeout: .seconds(4))
                XCTFail("Expected unsupported version for \(version)")
            } catch AntigravityQuotaClient.Failure.unsupportedVersion { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: executable.appendingPathExtension("usage").path))
        }
    }

    private func makeQuotaFixture(_ script: String, version: String = "Antigravity CLI 1.1.11") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zivvi-quota-\(UUID())",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agy-fixture")
        let versionCheck = """
        if [ "$1" = --version ]; then
            printf '%s\\n' '\(version)'
            exit 0
        fi
        """
        try Data("#!/bin/sh\n\(versionCheck)\n\(script)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func readPID(from marker: URL) throws -> pid_t {
        let text = try String(contentsOf: marker, encoding: .utf8)
        guard let pid = pid_t(text), pid > 0 else { throw POSIXError(.EINVAL) }
        return pid
    }

    private func assertReaped(using marker: URL) throws {
        let pid = try readPID(from: marker)
        let result = kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(error, ESRCH)
    }
}

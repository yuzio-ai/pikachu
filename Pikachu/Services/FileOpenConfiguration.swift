import AppKit
import Foundation
import SwiftUI
import OrchestrationCore

enum FileOpenPreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case xcode
    case visualStudioCode
    case custom

    var id: Self { self }

    var applicationBundleIdentifier: String? {
        switch self {
        case .xcode: "com.apple.dt.Xcode"
        case .visualStudioCode: "com.microsoft.VSCode"
        case .system, .custom: nil
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .system: "系统默认"
        case .xcode: "Xcode"
        case .visualStudioCode: "Visual Studio Code"
        case .custom: "自定义命令"
        }
    }
}

struct FileOpenConfiguration: Equatable, Sendable {
    var preference: FileOpenPreference = .system
    var customCommand = ""

    private static let preferenceKey = "file-open-preference"
    private static let commandKey = "file-open-command"

    static var saved: Self {
        let defaults = UserDefaults.standard
        return .init(
            preference: defaults.string(forKey: preferenceKey).flatMap(FileOpenPreference.init(rawValue:)) ?? .system,
            customCommand: defaults.string(forKey: commandKey) ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(preference.rawValue, forKey: Self.preferenceKey)
        if customCommand.isEmpty {
            defaults.removeObject(forKey: Self.commandKey)
        } else {
            defaults.set(customCommand, forKey: Self.commandKey)
        }
    }
}

struct FileOpenCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
}

enum FileOpenPlan: Equatable, Sendable {
    /// The system's default application, or Finder when no application matches.
    case system
    case run(FileOpenCommand)
}

extension FileOpenConfiguration {
    /// Resolves the chosen opener for one click. Editors that are not installed
    /// fall back to the system default instead of failing to launch.
    static func plan(
        for fileURL: URL,
        line: Int?,
        configuration: FileOpenConfiguration,
        xcode: URL? = FileOpenConfiguration.installedApplication(bundleIdentifier: "com.apple.dt.Xcode"),
        visualStudioCode: URL? = FileOpenConfiguration.installedApplication(bundleIdentifier: "com.microsoft.VSCode")
    ) -> FileOpenPlan {
        switch configuration.preference {
        case .system:
            return .system
        case .xcode:
            guard let xcode else { return .system }
            let xed = xcode.appendingPathComponent("Contents/Developer/usr/bin/xed")
            guard let line, FileManager.default.isExecutableFile(atPath: xed.path) else {
                return .run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                  arguments: ["-b", "com.apple.dt.Xcode", fileURL.path]))
            }
            return .run(.init(executable: xed, arguments: ["--line", "\(line)", fileURL.path]))
        case .visualStudioCode:
            guard let visualStudioCode else { return .system }
            let cli = visualStudioCode.appendingPathComponent("Contents/Resources/app/bin/code")
            if let line, FileManager.default.isExecutableFile(atPath: cli.path) {
                return .run(.init(executable: cli, arguments: ["-g", "\(fileURL.path):\(line)"]))
            }
            var arguments = ["-b", "com.microsoft.VSCode"]
            if let line {
                arguments += ["--args", "-g", "\(fileURL.path):\(line)"]
            } else {
                arguments.append(fileURL.path)
            }
            return .run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: arguments))
        case .custom:
            let script = Self.customScript(configuration.customCommand, path: fileURL.path, line: line)
            guard !script.isEmpty else { return .system }
            return .run(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]))
        }
    }

    static func customScript(_ command: String, path: String, line: Int?) -> String {
        let template = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return "" }
        let quotedPath = Self.shellQuote(path)
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index...].hasPrefix("{path}") {
                result += quotedPath
                index = template.index(index, offsetBy: 6)
            } else if line == nil, template[index...].hasPrefix(":{line}") {
                index = template.index(index, offsetBy: 7)
            } else if template[index...].hasPrefix("{line}") {
                result += line.map(String.init) ?? ""
                index = template.index(index, offsetBy: 6)
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }

    /// Only the two simple tokens above are substituted, so the quoted value
    /// never re-enters the template and cannot inject shell syntax.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func installedApplication(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

enum TranscriptFileOpener {
    /// How a referenced file can be shown; files without a matching app would
    /// otherwise make Launch Services report “应用程序无法打开”.
    enum Destination: Equatable, Sendable {
        case application(URL)
        case revealInFinder(URL)
        case unsupported
    }

    @MainActor struct Request {
        let url: URL
        private let contextIsCurrent: () -> Bool
        private let validate: () async -> Bool

        init(url: URL, contextIsCurrent: @escaping () -> Bool = { true },
             validate: @escaping () async -> Bool = { true }) {
            self.url = url
            self.contextIsCurrent = contextIsCurrent
            self.validate = validate
        }

        var isCurrent: Bool { !Task.isCancelled && contextIsCurrent() }

        func withAuthorization<Value>(_ dispatch: () -> Value) async -> Value? {
            guard isCurrent, await validate(), isCurrent else { return nil }
            return dispatch()
        }
    }

    @MainActor struct Actions {
        var destination: (URL) async -> Destination = { url in
            await Task.detached { TranscriptFileOpener.destination(for: url) }.value
        }
        var openApplication: (URL) -> Bool = { NSWorkspace.shared.open($0) }
        var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        var launch: (Process, @escaping @MainActor @Sendable () async -> Void) throws -> Void = { process, onFailure in
            // A slow command must not stall the UI while we wait for its result.
            process.terminationHandler = { proc in
                guard proc.terminationStatus != 0 else { return }
                Task { await onFailure() }
            }
            try process.run()
        }
    }

    @MainActor private final class OpenBox {
        let handler: ((URL) -> Void)?
        init(_ handler: ((URL) -> Void)?) { self.handler = handler }
    }

    static func destination(for fileURL: URL) -> Destination {
        let url = withoutFragment(fileURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .unsupported }
        guard !isDirectory.boolValue, NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            // Asset catalogs, image sets and files without a default app reveal their
            // enclosing folder instead of failing to launch.
            return .revealInFinder(url)
        }
        return .application(url)
    }

    @MainActor static func open(_ fileURL: URL, line: Int? = nil, handler: ((URL) -> Void)? = nil,
                                configuration: FileOpenConfiguration = .saved) {
        let url = withoutFragment(fileURL)
        if let handler {
            handler(urlWithLine(url, line: line))
            return
        }
        Task {
            let exists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
            guard exists else { return }
            await open(Request(url: url), line: line, configuration: configuration)
        }
    }

    @MainActor static func open(_ request: Request, line: Int? = nil,
                                configuration: FileOpenConfiguration, actions: Actions = .init()) async {
        guard request.isCurrent else { return }
        let url = request.url
        let plan = await Task.detached {
            FileOpenConfiguration.plan(for: url, line: line, configuration: configuration)
        }.value
        switch plan {
        case .run(let command): await run(command, request: request, actions: actions)
        case .system: await openWithSystemDefault(request, actions: actions)
        }
    }

    @MainActor static func reveal(_ request: Request, actions: Actions = .init()) async {
        _ = await request.withAuthorization { actions.revealInFinder(request.url) }
    }

    @MainActor private static func openWithSystemDefault(_ request: Request, actions: Actions) async {
        guard request.isCurrent else { return }
        switch await actions.destination(request.url) {
        case .application:
            if await request.withAuthorization({ actions.openApplication(request.url) }) == false {
                await reveal(request, actions: actions)
            }
        case .revealInFinder:
            await reveal(request, actions: actions)
        case .unsupported:
            // Publish the current file error when destination lookup could not resolve it.
            _ = await request.withAuthorization {}
        }
    }

    @MainActor private static func run(_ command: FileOpenCommand, request: Request, actions: Actions) async {
        let fallback: @MainActor @Sendable () async -> Void = {
            await openWithSystemDefault(request, actions: actions)
        }
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = processEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let result = await request.withAuthorization {
            Result { try actions.launch(process, fallback) }
        }
        if case .failure? = result { await fallback() }
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = existing + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
        ]
        var seen: Set<String> = []
        environment["PATH"] = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    /// What a click in the transcript should do, decided without launching anything.
    enum ClickedLink: Equatable {
        case file(URL, line: Int?)
        case system
        case ignored
    }

    static func clickedLink(for url: URL, workspaceDirectory: URL?) -> ClickedLink {
        clickedLink(for: url, workspaceDirectory: workspaceDirectory) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    static func clickedLink(
        for url: URL,
        workspaceDirectory: URL?,
        fileExists: (String) -> Bool
    ) -> ClickedLink {
        if let scheme = url.scheme, !url.isFileURL {
            // Web and custom schemes keep the system handler.
            return ["http", "https", "mailto"].contains(scheme.lowercased()) ? .system : .ignored
        }
        // A relative reference that no longer resolves must not reach Launch Services.
        guard let fileURL = TranscriptFileLinks.openableFileURL(for: url, workspaceDirectory: workspaceDirectory,
                                                              fileExists: fileExists) else {
            return .ignored
        }
        return .file(fileURL, line: lineReference(in: url))
    }

    /// Reads `#L12`, `#L12-L20`, `path:12` or `path:12:3` without trusting the path itself.
    static func lineReference(in url: URL) -> Int? {
        if let fragment = url.fragment, let line = firstNumber(in: fragment) { return line }
        return lastNumber(in: url.path)
    }

    @MainActor static func openAction(workspaceDirectory: URL?, openFile: ((URL) -> Void)? = nil) -> OpenURLAction {
        let box = OpenBox(openFile)
        return OpenURLAction { url in
            switch MainActor.assumeIsolated({ clickedLink(for: url, workspaceDirectory: workspaceDirectory) }) {
            case .system:
                return .systemAction
            case .ignored:
                return .handled
            case .file(let fileURL, let line):
                MainActor.assumeIsolated {
                    open(fileURL, line: line, handler: box.handler)
                }
                return .handled
            }
        }
    }

    private static func firstNumber(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber { digits.append(character) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    private static func lastNumber(in text: String) -> Int? {
        let pattern = #":(\d+)(?::\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    static func withoutFragment(_ fileURL: URL) -> URL {
        guard fileURL.fragment != nil, var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        components.fragment = nil
        return components.url ?? fileURL
    }

    private static func urlWithLine(_ url: URL, line: Int?) -> URL {
        guard let line, line > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = "L\(line)"
        return components.url ?? url
    }
}

import AppKit
import Foundation

enum FileOpenPreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case xcode
    case visualStudioCode
    case custom

    var id: Self { self }

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
        let lineText = line.map(String.init) ?? ""
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index...].hasPrefix("{path}") {
                result += quotedPath
                index = template.index(index, offsetBy: 6)
            } else if template[index...].hasPrefix("{line}") {
                result += lineText
                index = template.index(index, offsetBy: 6)
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }

    /// Only the three simple tokens above are substituted, so the quoted value
    /// never re-enters the template and cannot inject shell syntax.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func installedApplication(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

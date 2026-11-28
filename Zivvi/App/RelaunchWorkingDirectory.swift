import Darwin
import Foundation

enum RelaunchWorkingDirectory {
    static func restore() -> Bool {
        let key = "ZIVVI_RELAUNCH_DIRECTORY"
        guard let directory = ProcessInfo.processInfo.environment[key] else { return true }

        unsetenv(key)
        return FileManager.default.changeCurrentDirectoryPath(directory)
    }
}

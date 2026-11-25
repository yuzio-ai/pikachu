import AppKit
import SwiftUI

enum ProjectFilesOpenMethod: Hashable, Identifiable {
    case finder
    case configured(FileOpenPreference)

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .finder: "Finder"
        case .configured(let preference): preference.title
        }
    }

    func openLabel(isAvailable: Bool) -> LocalizedStringKey {
        let name = Text(title)
        return isAvailable ? "使用\(name)打开文件" : "\(name)不可用"
    }

    private var bundleIdentifier: String? {
        switch self {
        case .finder: "com.apple.finder"
        case .configured(let preference): preference.applicationBundleIdentifier
        }
    }

    @MainActor var icon: Image {
        if let bundleIdentifier,
           let app = FileOpenConfiguration.installedApplication(bundleIdentifier: bundleIdentifier) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
        }
        switch self {
        case .finder: return Image(systemName: "folder")
        case .configured(.custom): return Image(systemName: "terminal")
        case .configured: return Image(systemName: "arrow.up.forward.square")
        }
    }

    @MainActor func isAvailable(in configuration: FileOpenConfiguration) -> Bool {
        switch self {
        case .finder, .configured(.system): true
        case .configured(.custom): !configuration.customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .configured:
            bundleIdentifier.flatMap { FileOpenConfiguration.installedApplication(bundleIdentifier: $0) } != nil
        }
    }

    @MainActor func open(_ request: TranscriptFileOpener.Request, configuration: FileOpenConfiguration,
                         actions: TranscriptFileOpener.Actions = .init()) async {
        guard isAvailable(in: configuration) else { return }
        switch self {
        case .finder: await TranscriptFileOpener.reveal(request, actions: actions)
        case .configured(let preference):
            await TranscriptFileOpener.open(request, configuration: .init(preference: preference,
                                                                   customCommand: configuration.customCommand),
                                      actions: actions)
        }
    }
}

struct ProjectFilesBreadcrumbs: View {
    let root: ProjectFilesRoot
    let path: ProjectFilePath?
    var folderMenu: Binding<Bool>? = nil
    let reveal: (ProjectFilePath) -> Void

    private var directories: [ProjectFilePath] {
        guard let path else { return [] }
        return path.components.indices.dropFirst().map { ProjectFilePath(components: Array(path.components.prefix($0))) }
    }

    private var fullPath: String {
        guard let path else { return root.path }
        return URL(fileURLWithPath: root.path, isDirectory: true)
            .appending(path: path.relativePath, directoryHint: .notDirectory).path
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            breadcrumb(collapseFolders: false).fixedSize(horizontal: true, vertical: false)
            breadcrumb(collapseFolders: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Text(verbatim: fullPath))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件路径")
        .accessibilityValue(Text(verbatim: fullPath))
    }

    private func breadcrumb(collapseFolders: Bool) -> some View {
        HStack(spacing: 4) {
            if path != nil {
                folder(root.displayName, target: .root)
                    .layoutPriority(1)
            } else {
                Text(verbatim: root.displayName)
            }
            if !directories.isEmpty {
                if collapseFolders {
                    separator
                    FlatMenu(width: 230, restoresTriggerFocus: true, presentation: folderMenu) {
                        IconButtonLabel(systemName: "folder")
                    } content: { select in
                        FlatMenuItems(items: directories.map { directory in
                            FlatMenuItem(id: directory, title: Text(verbatim: directory.name)) {
                                select { reveal(directory) }
                            }
                        })
                    }
                    .fixedSize()
                    .help("路径中的文件夹")
                    .accessibilityLabel("路径中的文件夹")
                    .onDisappear { folderMenu?.wrappedValue = false }
                } else {
                    ForEach(directories, id: \.self) { directory in
                        separator
                        folder(directory.name, target: directory)
                    }
                }
            }
            if let path {
                separator
                Text(verbatim: path.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(PikachuTheme.primaryText)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .pikachuFont(.caption)
        .foregroundStyle(PikachuTheme.secondaryText)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var separator: some View {
        Image(systemName: "chevron.forward")
            .pikachuFont(.caption2)
            .accessibilityHidden(true)
            .fixedSize()
    }

    private func folder(_ name: String, target: ProjectFilePath) -> some View {
        Button { reveal(target) } label: {
            Text(verbatim: name).frame(minHeight: IconButtonLabel.side)
        }
        .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 4))
        .foregroundStyle(PikachuTheme.secondaryText)
        .help(Text(verbatim: target == .root ? root.path : target.relativePath))
    }
}

struct ProjectFilesOpenControl: View {
    let method: ProjectFilesOpenMethod
    let configuration: FileOpenConfiguration
    let canOpen: Bool
    var methodsMenu: Binding<Bool>? = nil
    let select: @MainActor @Sendable (ProjectFilesOpenMethod) -> Void
    let open: () -> Void

    var body: some View {
        let available = method.isAvailable(in: configuration)
        let help = method.openLabel(isAvailable: available)
        HStack(spacing: 0) {
            Button(action: open) {
                method.icon.resizable().scaledToFit()
                    .frame(width: 15, height: 15)
                    .frame(width: IconButtonLabel.side, height: IconButtonLabel.side)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
            .help(help)
            .accessibilityLabel(help)
            .accessibilityIdentifier("project-files-open")
            .disabled(!canOpen || !available)

            Rectangle().fill(PikachuTheme.border).frame(width: 1, height: 20)
                .accessibilityHidden(true)

            FlatMenu(width: 230, restoresTriggerFocus: true, presentation: methodsMenu) {
                Image(systemName: "chevron.down")
                    .pikachuFont(.caption)
                    .frame(width: 21, height: IconButtonLabel.side)
            } content: { dismiss in
                ProjectFilesOpenOptions(method: method, configuration: configuration) { choice in
                    dismiss { select(choice) }
                }
            }
            .fixedSize()
            .help("选择文件打开方式")
            .accessibilityLabel("选择文件打开方式")
            .accessibilityIdentifier("project-files-open-methods")
        }
        .background(PikachuTheme.surface, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(PikachuTheme.border).allowsHitTesting(false)
        }
        .fixedSize()
    }
}

struct ProjectFilesOpenOptions: View {
    let method: ProjectFilesOpenMethod
    let configuration: FileOpenConfiguration
    let select: (ProjectFilesOpenMethod) -> Void

    private var methods: [ProjectFilesOpenMethod] {
        let all = [ProjectFilesOpenMethod.finder] + FileOpenPreference.allCases.map(ProjectFilesOpenMethod.configured)
        return all.filter { $0 == method || $0.isAvailable(in: configuration) }
    }

    var body: some View {
        let choices = methods.map { choice in
            let available = choice.isAvailable(in: configuration)
            return FlatMenuItem(id: choice,
                                title: available ? Text(choice.title) : Text("\(Text(choice.title))不可用"),
                                icon: choice.icon, enabled: available, selected: method == choice) {
                select(choice)
            }
        }
        FlatMenuItems(items: choices, iconSize: 16)
            .accessibilityLabel("选择文件打开方式")
    }
}

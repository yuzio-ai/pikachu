import SwiftUI

struct ProjectFileIcon: View {
    let path: ProjectFilePath
    let kind: ProjectFileEntry.Kind

    private var symbol: String {
        switch kind {
        case .directory: "folder"
        case .link: "link"
        case .other: "questionmark.square"
        case .file:
            switch (path.name as NSString).pathExtension.lowercased() {
            case "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "js", "jsx", "ts", "tsx",
                 "py", "rb", "sh", "zsh", "java", "kt", "html", "css", "sql":
                "chevron.left.forwardslash.chevron.right"
            case "md", "markdown", "mdown", "mkd": "doc.plaintext"
            case "json", "jsonc", "plist", "xcstrings", "xcconfig", "yml", "yaml", "toml", "ini", "xml":
                "gearshape"
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "svg", "ico": "photo"
            default: "doc"
            }
        }
    }

    var body: some View {
        LightningIconView(systemName: symbol, size: 13)
    }
}

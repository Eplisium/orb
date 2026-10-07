import AppKit
import UniformTypeIdentifiers

/// Save panel for the filtered model list export.
@MainActor
enum ModelExportPanel {
    static func defaultFileName(_ format: ModelExportFormat, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "orb-models-\(f.string(from: date)).\(format.fileExtension)"
    }

    static func present(text: String, format: ModelExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName(format)
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            AppToasts.saved("Model list")
        } catch {
            AppToasts.saveFailed("model list", reason: error.localizedDescription)
        }
    }
}

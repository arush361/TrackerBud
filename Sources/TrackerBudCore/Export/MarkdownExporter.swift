import Foundation
import OSLog

/// Writes structured digests as markdown to a user-configurable folder.
public final class MarkdownExporter: @unchecked Sendable {
    public static let shared = MarkdownExporter()

    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "MarkdownExporter")
    public init() {}

    /// User's preferred export folder. Defaults to ~/Documents/TrackerBud-Digests.
    public static var exportFolderURL: URL {
        if let configured = UserDefaults.standard.string(forKey: "TrackerBud.digestExportFolder"),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        return docs.appendingPathComponent("TrackerBud-Digests", isDirectory: true)
    }

    public func writeDailyMarkdown(prose: String, day: Date) throws -> URL {
        let folder = Self.exportFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let name = "\(f.string(from: day)).md"
        let url = folder.appendingPathComponent(name)

        try prose.data(using: .utf8)?.write(to: url, options: [.atomic])
        log.info("Wrote daily digest to \(url.path, privacy: .public)")
        return url
    }
}

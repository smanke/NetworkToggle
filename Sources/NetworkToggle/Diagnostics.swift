import Foundation

/// Appends to ~/Library/Logs/NetworkToggle.log.
///
/// Always on, because the alternative was not diagnosable: os_log entries from this app
/// never appeared in `log show` at any level, so "why did nothing happen when I plugged
/// the dock in?" could only be answered by reinstalling a debug build and reproducing.
/// A capped file costs nothing and answers it from the build people actually run.
enum Diagnostics {
    /// Development affordances (the simulate item in the menu) still need the env var.
    static let isEnabled = ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG"] == "1"

    private static let maximumBytes = 256 * 1024

    private static let url: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let logs = library.appending(path: "Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appending(path: "NetworkToggle.log")
    }()

    private static let queue = DispatchQueue(label: "NetworkToggle.diagnostics")

    static func note(_ message: String) {
        guard let url else { return }
        let line = "\(Date().formatted(date: .abbreviated, time: .standard)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
            trimIfNeeded(url)
        }
    }

    /// Keeps the newest half when the file grows past the cap, so it can be left on forever.
    private static func trimIfNeeded(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}

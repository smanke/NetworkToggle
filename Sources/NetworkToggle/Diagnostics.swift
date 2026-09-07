import Foundation

/// Appends to /tmp/networktoggle-debug.log when NETWORKTOGGLE_DEBUG=1. The unified log is the
/// right place for shipping diagnostics, but it drops info-level messages from an
/// unsigned-for-logging process, which makes it useless while bringing the app up.
enum Diagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG"] == "1"
    private static let path = "/tmp/networktoggle-debug.log"

    static func note(_ message: String) {
        guard enabled else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

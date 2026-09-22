import Foundation

public enum ProcessRunner {
    /// Runs a tool and returns its standard output, or nil if it could not start or did not
    /// finish in time.
    ///
    /// The timeout is not optional: `smbutil` run against a share path from an app sat
    /// indefinitely behind a privacy prompt. In the helper that would have stalled every
    /// later request on its queue.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Drain concurrently so a large listing cannot fill the pipe and wedge the tool.
        var data = Data()
        let reader = DispatchQueue(label: "ProcessRunner.read")
        let drained = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }
        _ = drained.wait(timeout: .now() + 1)
        return String(data: data, encoding: .utf8)
    }
}

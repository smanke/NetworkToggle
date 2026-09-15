import Foundation
import Observation

struct Throughput: Equatable {
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double

    /// Megabytes per second, decimal (1 MB = 1,000,000 bytes) to match how macOS labels
    /// sizes and speeds in Finder and Activity Monitor.
    static func megabytesLabel(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / 1_000_000
        switch megabytes {
        case ..<1: return String(format: "%.2f MB/s", megabytes)
        case ..<100: return String(format: "%.1f MB/s", megabytes)
        default: return String(format: "%.0f MB/s", megabytes)
        }
    }
}

/// Live throughput for one interface, sampled once a second.
///
/// Deliberately does nothing on its own: the menu starts it when it opens on an active
/// connection and stops it when it closes, so the app does no sampling at all while the
/// menu is shut. Each sample is a single sysctl for one interface's byte counters.
@Observable
@MainActor
final class ThroughputMeter {
    /// The interface being measured, or nil while stopped.
    private(set) var interface: String?
    /// Nil until two samples have been taken, since a rate needs a before and after.
    private(set) var reading: Throughput?

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts measuring `bsdName`, switches to it if something else was being measured, or
    /// stops when passed nil.
    func measure(_ bsdName: String?) {
        if bsdName == interface, (bsdName == nil) == (task == nil) { return }

        task?.cancel()
        task = nil
        reading = nil
        interface = bsdName

        guard let bsdName else { return }
        Diagnostics.note("throughput: sampling \(bsdName)")

        task = Task { @MainActor [weak self] in
            var previous = InterfaceCounters.read(bsdName)
            var previousTime = ContinuousClock.now
            var samples = 0
            defer { Diagnostics.note("throughput: stopped \(bsdName) after \(samples) samples") }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }

                let now = ContinuousClock.now
                let current = InterfaceCounters.read(bsdName)
                defer { previous = current; previousTime = now }

                // Counters restart when an interface bounces; a sample spanning that would
                // read as an enormous negative rate, so skip it and start over.
                guard let current, let before = previous,
                      current.received >= before.received, current.sent >= before.sent
                else { continue }

                let elapsed = now - previousTime
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                guard seconds > 0 else { continue }

                let sample = Throughput(
                    downloadBytesPerSecond: Double(current.received - before.received) / seconds,
                    uploadBytesPerSecond: Double(current.sent - before.sent) / seconds
                )
                samples += 1

                // Light smoothing so a bursty transfer reads as a steady number rather than
                // flickering between extremes, while still settling within a couple of seconds.
                if let last = self.reading {
                    self.reading = Throughput(
                        downloadBytesPerSecond: last.downloadBytesPerSecond * 0.4 + sample.downloadBytesPerSecond * 0.6,
                        uploadBytesPerSecond: last.uploadBytesPerSecond * 0.4 + sample.uploadBytesPerSecond * 0.6
                    )
                } else {
                    self.reading = sample
                }
            }
        }
    }
}

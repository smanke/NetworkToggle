import Foundation
import Darwin

/// Pings a gateway to confirm the link actually carries traffic.
///
/// A dock can present a perfectly configured interface — link up, DHCP lease, default
/// router — whose uplink is dead, and promoting that leaves the Mac believing it is
/// online while nothing resolves. macOS grants unprivileged processes `SOCK_DGRAM`
/// ICMP sockets, so this needs no help from the daemon.
enum GatewayProbe {

    /// - Returns: `true` only on a reply. A timeout returns `false`, which callers treat
    ///   as "ask the user" rather than "switch anyway".
    static func reachable(_ address: String, timeout: Duration = .seconds(2)) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ping(address, timeout: timeout))
            }
        }
    }

    private static func ping(_ address: String, timeout: Duration) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard address.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return false
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let identifier = UInt16.random(in: 0...UInt16.max)
        var packet = ICMPEcho(identifier: identifier, sequence: 1)
        let sent = withUnsafeBytes(of: &packet) { buffer -> Int in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return false }

        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000)
        guard poll(&pollFD, 1, milliseconds) > 0 else { return false }

        var response = [UInt8](repeating: 0, count: 128)
        let received = recv(fd, &response, response.count, 0)
        // The kernel hands back the echo reply with the identifier it assigned, so the
        // only thing worth asserting is that something came back on this socket at all.
        return received > 0
    }
}

/// An 8-byte ICMP echo header. The kernel fills in the identifier and checksum for
/// datagram ICMP sockets, so the payload can stay empty.
private struct ICMPEcho {
    var type: UInt8 = 8      // echo request
    var code: UInt8 = 0
    var checksum: UInt16 = 0
    var identifier: UInt16
    var sequence: UInt16

    init(identifier: UInt16, sequence: UInt16) {
        self.identifier = identifier.bigEndian
        self.sequence = sequence.bigEndian
    }
}

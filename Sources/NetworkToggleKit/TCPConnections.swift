import Foundation

/// One established TCP connection.
public struct TCPConnection: Hashable, Sendable {
    public let localAddress: String
    public let localPort: Int
    public let remoteAddress: String
    public let remotePort: Int
}

public enum TCPConnectionList {
    /// netstat's listing of IPv4 TCP connections.
    ///
    /// Only meaningful when run by the privileged helper. For an ordinary app process the
    /// kernel returns an empty connection list — measured: it reported ~82 KB of
    /// connections and handed over only the 48-byte header — which hides every other
    /// program's connections and all of the kernel's own, including network file shares.
    public static func netstatOutput() -> String {
        ProcessRunner.run("/usr/sbin/netstat", ["-n", "-p", "tcp", "-f", "inet"], timeout: 3) ?? ""
    }

    /// Established connections from netstat output lines like
    /// `tcp4  0  0  10.0.1.140.56778  10.0.1.40.445  ESTABLISHED`.
    public static func parse(_ text: String) -> [TCPConnection] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6, fields[0].hasPrefix("tcp4"), fields[5] == "ESTABLISHED",
                  let local = endpoint(fields[3]), let remote = endpoint(fields[4])
            else { return nil }
            return TCPConnection(localAddress: local.address, localPort: local.port,
                                 remoteAddress: remote.address, remotePort: remote.port)
        }
    }

    private static func endpoint(_ text: Substring) -> (address: String, port: Int)? {
        guard let dot = text.lastIndex(of: "."), let port = Int(text[text.index(after: dot)...]) else { return nil }
        return (String(text[..<dot]), port)
    }
}

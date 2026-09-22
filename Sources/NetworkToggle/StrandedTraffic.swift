import Foundation
import Darwin
import Observation
import NetworkToggleKit

/// An interface that is up but should not be carrying traffic, because another one is the
/// active connection.
struct WatchedInterface: Hashable, Sendable {
    let bsdName: String
    let name: String
    let ipv4: String
    let isWiFi: Bool
}

/// Connections still running over a watched interface, grouped by who they are with.
struct StrandedInterface: Equatable {
    let bsdName: String
    let name: String
    let isWiFi: Bool
    let peers: [StrandedPeer]

    var connectionCount: Int { peers.reduce(0) { $0 + $1.count } }

    /// "2 connections to MediaNAS (file sharing)", or "5 connections to MediaNAS (file
    /// sharing) and 2 others".
    var summary: String {
        guard let first = peers.first else { return "Connections" }
        let total = connectionCount
        let lead = "\(total) connection\(total == 1 ? "" : "s") to \(first.label)"
        let others = peers.count - 1
        return others == 0 ? lead : "\(lead) and \(others) other\(others == 1 ? "" : "s")"
    }
}

struct StrandedPeer: Hashable {
    let label: String
    let count: Int
}

/// Finds connections left on an interface after another became the active connection.
///
/// macOS routes *new* connections over the active connection but never moves existing
/// ones: each stays bound to the address it was opened from until it closes. A file share
/// mounted while Wi-Fi was active keeps every copy to it on Wi-Fi indefinitely — measured
/// here at over 40 GB each way to a NAS while the menu said Ethernet was active and
/// showed Ethernet idle.
///
/// Like the throughput meter, this only runs while the menu is open. The connection list
/// comes from the privileged helper, because macOS gives an ordinary app none of it.
@Observable
@MainActor
final class StrandedTrafficMonitor {
    private(set) var stranded: [StrandedInterface] = []

    private let helper: HelperClient

    init(helper: HelperClient) {
        self.helper = helper
    }

    @ObservationIgnored private var watched: [WatchedInterface] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var serverNames: [String: String] = [:]
    @ObservationIgnored private let resolver = ShareNameResolver()
    @ObservationIgnored private var loggedFirstScan = false

    private static let fileSharingPorts: Set<Int> = [445, 548, 2049]

    /// Watches these interfaces for stranded connections; an empty list stops.
    func watch(_ interfaces: [WatchedInterface]) {
        if interfaces == watched, interfaces.isEmpty == (task == nil) { return }

        task?.cancel()
        task = nil
        watched = interfaces
        loggedFirstScan = false
        Diagnostics.note("stranded watch: \(interfaces.isEmpty ? "stopped" : interfaces.map { "\($0.bsdName)=\($0.ipv4)" }.joined(separator: ", "))")

        guard !interfaces.isEmpty else {
            if !stranded.isEmpty { stranded = [] }
            return
        }

        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scan()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func scan() async {
        let watched = self.watched
        let addresses = Set(watched.map(\.ipv4))

        guard helper.state.isReady else { return }
        guard let connections = await helper.establishedConnections() else {
            Diagnostics.note("stranded scan: helper did not return a connection list")
            return
        }
        guard !Task.isCancelled else { return }
        let hits = connections.filter { addresses.contains($0.localAddress) }
        if !loggedFirstScan {
            loggedFirstScan = true
            Diagnostics.note("stranded scan: helper listed \(connections.count) connections, \(hits.count) on watched interfaces")
        }

        publish(hits)

        // Name file-share peers after the server they belong to. Reverse DNS returns nothing
        // on a typical LAN, and asking the SMB client about a share — from the app or the
        // helper — needs network-volume access, which is too much to ask for a label. The
        // mount table gives server names for free; their .local addresses resolve in the
        // background (with local-network permission) and the notice picks them up on a
        // later scan. Until then it shows the address.
        if hits.contains(where: { Self.fileSharingPorts.contains($0.remotePort) }) {
            let names = resolver.addresses(for: MountedServers.names())
            if names != serverNames {
                serverNames = names
                publish(hits)
            }
        }
    }

    private func publish(_ hits: [TCPConnection]) {
        var result: [StrandedInterface] = []
        for interface in watched {
            let mine = hits.filter { $0.localAddress == interface.ipv4 }
            guard !mine.isEmpty else { continue }
            let peers = Dictionary(grouping: mine, by: label(for:))
                .map { StrandedPeer(label: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
            result.append(StrandedInterface(bsdName: interface.bsdName, name: interface.name,
                                            isWiFi: interface.isWiFi, peers: peers))
        }

        if result != stranded {
            stranded = result
            let text = result.map { "\($0.bsdName): " + $0.peers.map { "\($0.label)×\($0.count)" }.joined(separator: ", ") }
            Diagnostics.note("stranded: \(text.isEmpty ? "none" : text.joined(separator: "; "))")
        }
    }

    private func label(for connection: TCPConnection) -> String {
        let host = serverNames[connection.remoteAddress] ?? connection.remoteAddress
        let service: String
        switch connection.remotePort {
        case 445, 548, 2049: service = "file sharing"
        case 22: service = "SSH"
        case 80, 443: service = "web"
        case 5900: service = "screen sharing"
        default: service = "port \(connection.remotePort)"
        }
        return "\(host) (\(service))"
    }
}

enum MountedServers {
    /// Server names of mounted SMB shares — "MediaNAS" from `//user@MediaNAS._smb._tcp.local/Share` —
    /// or the address itself when a share was mounted by IP. Reads only the mount table.
    static func names() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        var names: Set<String> = []
        for var mount in UnsafeBufferPointer(start: mounts, count: Int(count)) {
            let type = withUnsafeBytes(of: &mount.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard type == "smbfs" else { continue }
            let from = withUnsafeBytes(of: &mount.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            names.insert(serverName(from))
        }
        return names
    }

    static func serverName(_ mountedFrom: String) -> String {
        var rest = Substring(mountedFrom)
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        let host = String(rest.prefix { $0 != "/" })
        let decoded = host.removingPercentEncoding ?? host
        if decoded.contains("._smb._tcp") { return String(decoded.prefix { $0 != "." }) }
        return decoded.hasSuffix(".local") ? String(decoded.dropLast(6)) : decoded
    }
}

/// Maps server names to IPv4 addresses without ever making a caller wait.
///
/// Each name is looked up once, on its own thread. getaddrinfo cannot be cancelled and,
/// for a .local name, can sit for as long as macOS holds it behind the local-network
/// permission — so nothing waits on it; whatever has resolved so far is returned.
final class ShareNameResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted: Set<String> = []
    private var byAddress: [String: String] = [:]

    func addresses(for names: Set<String>) -> [String: String] {
        lock.lock()
        let pending = names.subtracting(attempted)
        attempted.formUnion(pending)
        lock.unlock()

        for name in pending {
            if name.split(separator: ".").count == 4, name.allSatisfy({ $0.isNumber || $0 == "." }) {
                // Mounted by address: nothing to look up.
                lock.lock(); byAddress[name] = name; lock.unlock()
                continue
            }
            Thread.detachNewThread { [self] in
                let found = Self.ipv4Addresses(name + ".local")
                lock.lock(); for address in found { byAddress[address] = name }; lock.unlock()
            }
        }

        lock.lock(); defer { lock.unlock() }
        return byAddress
    }

    private static func ipv4Addresses(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            if let address = current.pointee.ai_addr {
                var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &inet, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.append(String(cString: buffer))
                }
            }
            entry = current.pointee.ai_next
        }
        return addresses
    }
}

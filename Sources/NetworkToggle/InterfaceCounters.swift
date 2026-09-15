import Darwin

/// Total bytes an interface has received and sent since it came up, straight from the
/// kernel.
///
/// Uses the routing socket's `NET_RT_IFLIST2` listing, filtered to one interface, because
/// it carries `if_data64`. The more obvious `getifaddrs` exposes 32-bit counters, which wrap
/// every 4 GiB — about every 34 seconds on a gigabit link running flat out — and would turn
/// a busy download into nonsense readings.
enum InterfaceCounters {
    struct Sample: Equatable {
        let received: UInt64
        let sent: UInt64
    }

    static func read(_ bsdName: String) -> Sample? {
        let index = if_nametoindex(bsdName)
        guard index != 0 else { return nil }

        // [CTL_NET, PF_ROUTE, protocol, address family, operation, interface index]
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> Sample? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                // The listing is a run of variable-length messages with no alignment
                // guarantee between them, hence loadUnaligned.
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { return nil }

                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(message.ifm_index) == index {
                        return Sample(received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
            return nil
        }
    }
}

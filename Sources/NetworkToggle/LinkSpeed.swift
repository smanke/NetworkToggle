import Foundation
import IOKit
import CoreWLAN

/// Negotiated link rate for an interface, in Mbps.
///
/// Wi-Fi reports its current transmit rate through CoreWLAN. Ethernet has no such API,
/// so the rate is read from the IORegistry: every BSD network interface publishes an
/// `IOLinkSpeed` property in bits per second on its provider. This is the same number
/// System Information shows, and it is what makes a 100 Mbps dock port visibly worse
/// than 866 Mbps Wi-Fi rather than merely "wired".
enum LinkSpeed {

    static func mbps(forBSDName bsd: String, isWiFi: Bool) -> Int? {
        if isWiFi {
            guard let interface = CWWiFiClient.shared().interface(withName: bsd),
                  interface.powerOn() else { return nil }
            let rate = interface.transmitRate()
            return rate > 0 ? Int(rate.rounded()) : nil
        }
        return ethernetMbps(bsd)
    }

    private static func ethernetMbps(_ bsd: String) -> Int? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        // IOLinkSpeed lives on the controller, one level up from the interface node.
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(parent) }

        guard let raw = IORegistryEntryCreateCFProperty(
            parent, "IOLinkSpeed" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }

        let bitsPerSecond = raw.int64Value
        guard bitsPerSecond > 0 else { return nil }
        return Int(bitsPerSecond / 1_000_000)
    }
}

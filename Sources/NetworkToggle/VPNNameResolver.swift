import Foundation

/// A human name for a VPN that macOS identifies only by a session UUID.
///
/// A NetworkExtension VPN such as NordVPN publishes its tunnel under a service ID that
/// exists nowhere in the network configuration, and that ID does not match the ID of the
/// extension's own configuration either — so there is no exact lookup. What is readable,
/// without privilege, is the extension store: if exactly one configuration there carries
/// an enabled VPN payload, that is the VPN that is up. With several, this returns nil and
/// the caller says "VPN" rather than guessing wrong.
enum VPNNameResolver {
    private static let storePath = "/Library/Preferences/com.apple.networkextension.plist"

    static func enabledVPNApplicationName() -> String? {
        guard let data = FileManager.default.contents(atPath: storePath),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any]
        else { return nil }

        // The store is an NSKeyedArchiver graph of private classes, so it is walked as a
        // raw property list and every reference followed by hand.
        func resolve(_ value: Any?) -> Any? {
            guard let value else { return nil }
            if let index = archiveIndex(value), objects.indices.contains(index) {
                return objects[index]
            }
            return value
        }
        func string(_ value: Any?) -> String? {
            guard let text = resolve(value) as? String, text != "$null", !text.isEmpty else { return nil }
            return text
        }

        var names: [String] = []
        for case let configuration as [String: Any] in objects where configuration["Identifier"] != nil {
            // Content filters (Little Snitch, the application firewall) live in the same
            // store with a null VPN payload; only a real, enabled VPN payload counts.
            guard let vpn = resolve(configuration["VPN"]) as? [String: Any],
                  (resolve(vpn["Enabled"]) as? Bool) == true
            else { continue }
            if let name = string(configuration["ApplicationName"]) ?? string(configuration["Name"]) {
                names.append(name)
            }
        }
        return names.count == 1 ? names[0] : nil
    }

    /// Foundation hands archive references back as opaque `CFKeyedArchiverUID` objects
    /// with no public accessor; the index is only exposed through their description.
    private static func archiveIndex(_ value: Any) -> Int? {
        let description = String(describing: value)
        guard description.contains("CFKeyedArchiverUID"),
              let match = description.range(of: #"value = \d+"#, options: .regularExpression)
        else { return nil }
        return Int(description[match].dropFirst("value = ".count))
    }
}

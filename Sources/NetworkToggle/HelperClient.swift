import Foundation
import ServiceManagement
import Observation
import NetworkToggleKit
import os

private let log = Logger(subsystem: NetworkToggleIDs.appBundleID, category: "helper-client")

enum HelperState: Equatable {
    case notInstalled
    case requiresApproval
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// Owns the privileged daemon: installs it, keeps a connection to it, and turns its
/// callback-style XPC into async calls.
///
/// Everything that mutates system configuration goes through here. The app itself holds
/// no elevated rights, so a bug in the UI cannot reorder anything on its own.
@Observable
@MainActor
final class HelperClient {
    private(set) var state: HelperState = .notInstalled

    @ObservationIgnored private var connection: NSXPCConnection?

    private var daemon: SMAppService {
        SMAppService.daemon(plistName: NetworkToggleIDs.helperPlistName)
    }

    // MARK: - Installation

    /// Path the daemon plist must occupy inside the bundle for SMAppService to see it.
    private var daemonPlistURL: URL {
        Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchDaemons")
            .appending(path: NetworkToggleIDs.helperPlistName)
    }

    func refreshState() {
        let status = daemon.status
        Diagnostics.note("SMAppService status raw=\(status.rawValue) bundle=\(Bundle.main.bundlePath)")

        switch status {
        case .enabled:
            state = .ready
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            state = .notInstalled
        case .notFound:
            // Daemons report notFound before they have ever been registered, so this is
            // not on its own evidence of a broken bundle. Only call it broken if the
            // plist really is absent — otherwise it means the same as notRegistered.
            state = FileManager.default.fileExists(atPath: daemonPlistURL.path)
                ? .notInstalled
                : .failed("The helper is missing from the app bundle. Reinstall NetworkToggle.")
        @unknown default:
            state = .notInstalled
        }
    }

    /// Registering prompts the user once, in System Settings. macOS refuses to register a
    /// daemon for an app running outside /Applications, so surface that specifically
    /// rather than reporting the generic failure it comes back as.
    func install() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            state = .failed("Move NetworkToggle to your Applications folder, then try again. "
                          + "macOS only grants privileged helpers to apps installed there.")
            return
        }
        // Registering something already registered throws EPERM ("Operation not
        // permitted"), which reads like a refusal and sends people hunting for a
        // permissions problem that does not exist. The first click registers and leaves
        // the service awaiting approval; a second click must not call register() again.
        refreshState()
        switch state {
        case .ready:
            return
        case .requiresApproval:
            Diagnostics.note("install() skipped: already registered, awaiting approval")
            openLoginItemsSettings()
            return
        case .notInstalled, .failed:
            break
        }

        do {
            try daemon.register()
            log.info("Helper registered")
        } catch {
            let nsError = error as NSError
            Diagnostics.note("register() failed: domain=\(nsError.domain) code=\(nsError.code) "
                             + "desc=\(nsError.localizedDescription) info=\(nsError.userInfo)")
            log.error("Helper registration failed: \(nsError.domain) \(nsError.code)")
            state = .failed(Self.explain(nsError))
            // Approval can still be granted from System Settings after a refusal, so the
            // state is re-read rather than left pinned to the failure.
            refreshState()
            return
        }
        refreshState()
    }

    /// Turns the terse errors SMAppService reports into something that says what to do.
    /// "Operation not permitted" on its own sends people looking in the wrong place.
    private static func explain(_ error: NSError) -> String {
        switch (error.domain, error.code) {
        case (NSOSStatusErrorDomain, 1), (NSPOSIXErrorDomain, 1):
            return "macOS refused to register the helper (Operation not permitted). "
                 + "Open Login Items & Extensions and allow NetworkToggle, then reopen this menu."
        case (_, 1):
            return "macOS refused to register the helper. Open Login Items & Extensions, "
                 + "allow NetworkToggle, then reopen this menu."
        default:
            return "\(error.localizedDescription) (\(error.domain) \(error.code))"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Asks a running helper to exit without unregistering it, so launchd starts the
    /// newer binary from the updated bundle next time the app needs it.
    func retireRunningHelper() async {
        _ = try? await withProxy { proxy, done in proxy.uninstall(reply: done) }
        invalidate()
    }

    func uninstallHelper() async {
        _ = try? await withProxy { proxy, done in proxy.uninstall(reply: done) }
        try? await daemon.unregister()
        invalidate()
        refreshState()
    }

    // MARK: - Connection

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let new = NSXPCConnection(
            machServiceName: NetworkToggleIDs.helperMachService,
            options: .privileged
        )
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)

        // The mirror of the check the helper makes on us: refuse to hand commands to
        // anything that is not the helper we shipped, signed by this team.
        new.setCodeSigningRequirement(NetworkToggleIDs.helperRequirement)

        new.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        new.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }

        new.resume()
        connection = new
        return new
    }

    private func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// Bridges one callback-style XPC method into async, turning both a transport failure
    /// and a helper-reported error string into a thrown `HelperCallError`.
    private func withProxy(
        _ body: @escaping (HelperProtocol, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        let result: Result<Void, HelperCallError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(.failure(.transport(error.localizedDescription)))
            }
            guard let helper = proxy as? HelperProtocol else {
                once.resume(.failure(.transport("The helper connection is unusable.")))
                return
            }
            body(helper) { @Sendable message in
                once.resume(message.map { .failure(.helper($0)) } ?? .success(()))
            }
        }
        try result.get()
    }

    // MARK: - Operations

    func setServiceOrder(_ ids: [String]) async throws {
        try await withProxy { proxy, done in proxy.setServiceOrder(ids, reply: done) }
    }

    func promote(_ serviceID: String) async throws {
        try await withProxy { proxy, done in proxy.promoteService(serviceID, reply: done) }
    }

    func setWiFiPower(_ on: Bool, bsdName: String) async throws {
        try await withProxy { proxy, done in proxy.setWiFiPower(on, bsdName: bsdName, reply: done) }
    }

    /// The helper's view of established TCP connections, or nil if it could not be asked.
    func establishedConnections() async -> [TCPConnection]? {
        let text: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { @Sendable error in
                Diagnostics.note("establishedConnections failed: \(error)")
                once.resume(nil)
            }
            guard let helper = proxy as? HelperProtocol else { once.resume(nil); return }
            helper.establishedConnections { @Sendable text in once.resume(text) }
        }
        return text.map(TCPConnectionList.parse)
    }

    enum HelperProbe: Sendable, CustomStringConvertible {
        case version(Int)
        /// The running helper fails the signature the app pins. Happens when an update
        /// replaces the helper's binary while the old one is still running.
        case signatureMismatch
        case unreachable

        var description: String {
            switch self {
            case let .version(build): "build \(build)"
            case .signatureMismatch: "signature mismatch"
            case .unreachable: "unreachable"
            }
        }
    }

    /// Asks the running helper which build it is.
    func probe() async -> HelperProbe {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<HelperProbe>(continuation)
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { @Sendable error in
                let nsError = error as NSError
                // NSXPCConnectionCodeSigningRequirementFailure
                once.resume(nsError.domain == NSCocoaErrorDomain && nsError.code == 4102 ? .signatureMismatch : .unreachable)
            }
            guard let helper = proxy as? HelperProtocol else { once.resume(.unreachable); return }
            helper.helperVersion { @Sendable build in once.resume(.version(build)) }
        }
    }

    /// Asks the running helper to exit without first checking its signature.
    ///
    /// A helper started before an update keeps running its old binary after the update
    /// replaces the file, and from then on it fails the signature check pinned on every
    /// connection. It can then neither be used nor, through a pinned connection, told to
    /// quit — every switch fails until the Mac restarts. This one request carries no data
    /// and nothing in the reply is trusted; the helper still verifies the app before it
    /// acts. launchd starts the new binary on the next request.
    func restartUnverifiedHelper() async {
        let unpinned = NSXPCConnection(machServiceName: NetworkToggleIDs.helperMachService, options: .privileged)
        unpinned.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        unpinned.resume()
        let _: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce<Bool>(continuation)
            let proxy = unpinned.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(false) }
            guard let helper = proxy as? HelperProtocol else { once.resume(false); return }
            helper.uninstall { @Sendable _ in once.resume(true) }
        }
        unpinned.invalidate()
        // Drop the pinned connection too, so the next call reaches the new helper.
        invalidate()
    }
}

/// Resumes a continuation exactly once, from whichever XPC callback lands first.
///
/// Deliberately not main-actor isolated, and every closure handed to NSXPC is marked
/// @Sendable for the same reason: NSXPC runs replies, error handlers and invalidation on
/// its own queue, and a closure that inherits HelperClient's main-actor isolation traps
/// there. It went unnoticed until a helper call first failed — replacing a stale helper —
/// and then crashed the app 7 seconds after launch.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let done = OSAllocatedUnfairLock(initialState: false)

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let first = done.withLock { finished -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { continuation.resume(returning: value) }
    }
}

enum HelperCallError: LocalizedError {
    case transport(String)
    case helper(String)

    var errorDescription: String? {
        switch self {
        case let .transport(message): "Could not reach the NetworkToggle helper. \(message)"
        case let .helper(message): message
        }
    }
}

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

        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        new.interruptionHandler = { [weak self] in
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
        _ body: @escaping (HelperProtocol, @escaping (String?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<Void, Error>) {
                let alreadyResumed = resumed.withLock { was -> Bool in
                    defer { was = true }
                    return was
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { error in
                finish(.failure(HelperCallError.transport(error.localizedDescription)))
            }
            guard let helper = proxy as? HelperProtocol else {
                finish(.failure(HelperCallError.transport("The helper connection is unusable.")))
                return
            }
            body(helper) { message in
                if let message {
                    finish(.failure(HelperCallError.helper(message)))
                } else {
                    finish(.success(()))
                }
            }
        }
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

    func installedHelperVersion() async -> Int? {
        await withCheckedContinuation { continuation in
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: nil)
            }
            guard let helper = proxy as? HelperProtocol else {
                continuation.resume(returning: nil)
                return
            }
            helper.helperVersion { continuation.resume(returning: $0) }
        }
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

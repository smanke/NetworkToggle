import AppKit

/// Downloads and installs the latest release from GitHub, then restarts.
///
/// This installs code fetched from the network, so nothing is trusted on the strength of
/// where it came from. Before anything is copied over the running app, the downloaded
/// bundle must:
///
/// 1. pass `codesign --verify --deep --strict`,
/// 2. carry the **same Team ID as the app that is running**, so a valid signature from
///    somebody else is refused, and
/// 3. pass Gatekeeper assessment, which means Apple notarized it.
///
/// A failure at any step aborts the update and leaves the installed app untouched.
enum UpdateController {
    private static let repository = "smanke/NetworkToggle"

    enum UpdateOutcome {
        case upToDate(current: String)
        case failed(String)
    }

    // MARK: - Entry point

    /// - Parameter silent: when true, say nothing unless there is an update to offer.
    ///   Used for the check at launch, where reporting "up to date" or a network hiccup
    ///   every time would just be noise.
    static func checkForUpdates(silent: Bool = false) {
        Task { @MainActor in
            let current = AppInfo.version
            do {
                let release = try await fetchLatestRelease()
                Diagnostics.note("update check: latest=\(release.version) current=\(current) "
                                 + "newer=\(isNewer(release.version, than: current))")
                guard isNewer(release.version, than: current) else {
                    if !silent { present(.upToDate(current: current)) }
                    return
                }
                // A version the user skipped is not raised again on its own.
                if silent, AppSettings.shared.skippedUpdateVersion == release.version {
                    return
                }

                // The launch check never installs. It only records that something is
                // available, and the menu surfaces it. Prompting from a background path
                // in a menu bar app is not safe: with no active app to own it, the modal
                // is not reliably shown and runModal() hands back its default button —
                // which silently installed an update nobody agreed to.
                if silent {
                    UpdateAvailability.shared.pending = release.version
                    Diagnostics.note("update \(release.version) available; surfaced in the menu")
                    return
                }

                let choice = confirmInstall(
                    newVersion: release.version,
                    current: current,
                    allowSkip: UpdateAvailability.shared.pending == release.version
                )
                Diagnostics.note("prompt returned: \(choice)")
                switch choice {
                case .cancel:
                    return
                case .skip:
                    AppSettings.shared.skippedUpdateVersion = release.version
                    UpdateAvailability.shared.pending = nil
                    return
                case .install:
                    break
                }

                let stagedApp = try await downloadAndStage(release)
                try verifySignature(of: stagedApp)
                try installAndRelaunch(from: stagedApp)
                // Control does not return: the app is replaced and restarted.
            } catch {
                if silent {
                    // Offline at launch is not worth interrupting anyone over.
                    NSLog("NetworkToggle: update check failed: \(error.localizedDescription)")
                } else {
                    present(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Release lookup

    private struct Release {
        let version: String
        let downloadURL: URL
    }

    private static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests without one.
        request.setValue("NetworkToggle/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw fail("Could not reach GitHub to check for updates.")
        }
        // A repository with no published releases answers 404, which is not the same
        // thing as being offline and should not be reported as a network problem.
        if http.statusCode == 404 {
            throw fail("There are no published releases to update to yet.")
        }
        guard http.statusCode == 200 else {
            throw fail("GitHub returned an error (\(http.statusCode)) while checking for updates.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw fail("The release information from GitHub could not be read.")
        }

        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        guard let urlString = dmg?["browser_download_url"] as? String,
              let url = URL(string: urlString), url.scheme == "https" else {
            throw fail("The latest release has no disk image to download.")
        }

        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, downloadURL: url)
    }

    /// Numeric component comparison, so 1.1.10 is correctly newer than 1.1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Download

    private static func downloadAndStage(_ release: Release) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw fail("The download failed.")
        }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NetworkToggleUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let dmg = staging.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloadedURL, to: dmg)

        // Mount read-only and without opening a Finder window.
        let mountPoint = staging.appendingPathComponent("mount")
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        guard attach.status == 0 else { throw fail("The downloaded disk image could not be opened.") }
        defer { run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw fail("The downloaded disk image does not contain an app.")
        }

        // Copy off the image before it is unmounted.
        let stagedApp = staging.appendingPathComponent(appName)
        try FileManager.default.copyItem(at: mountPoint.appendingPathComponent(appName), to: stagedApp)
        return stagedApp
    }

    // MARK: - Verification

    private static func verifySignature(of app: URL) throws {
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else {
            throw fail("The downloaded app's signature is not valid, so it was not installed.")
        }

        guard let downloadedTeam = teamIdentifier(of: app.path) else {
            throw fail("The downloaded app is not signed by an identifiable developer, so it was not installed.")
        }
        guard let runningTeam = teamIdentifier(of: Bundle.main.bundlePath) else {
            throw fail("This copy of the app is unsigned, so an update cannot be verified against it.")
        }
        guard downloadedTeam == runningTeam else {
            throw fail("The downloaded app is signed by a different developer (\(downloadedTeam)), so it was not installed.")
        }

        // Gatekeeper assessment: passes only if Apple notarized the build.
        let assess = run("/usr/sbin/spctl", ["-a", "-t", "exec", app.path])
        guard assess.status == 0 else {
            throw fail("The downloaded app is not notarized by Apple, so it was not installed.")
        }
    }

    private static func teamIdentifier(of path: String) -> String? {
        let result = run("/usr/bin/codesign", ["-dvvv", path])
        // codesign writes its description to stderr, which run() folds in.
        for line in result.output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    // MARK: - Install

    /// Hands the swap to a detached shell script, because the app cannot replace and
    /// relaunch itself while it is the one running.
    private static func installAndRelaunch(from stagedApp: URL) throws {
        let destination = Bundle.main.bundlePath
        let staging = stagedApp.deletingLastPathComponent()
        let script = staging.appendingPathComponent("install.sh")

        // The bundle is updated *in place* rather than deleted and recreated. Deleting it
        // orphans the app's privileged-helper approval: the entry stays visible and
        // switched on under Login Items while the daemon is actually gone, so every
        // update would silently send the user back through the setup prompt. A backup is
        // kept alongside only long enough to roll back a failed sync.
        let body = """
        #!/bin/sh
        # Wait for the running app to quit before replacing its bundle.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "\(destination).backup"
        /bin/cp -R "\(destination)" "\(destination).backup"
        if /usr/bin/rsync -a --delete "\(stagedApp.path)/" "\(destination)/"; then
          /bin/rm -rf "\(destination).backup"
        else
          /usr/bin/rsync -a --delete "\(destination).backup/" "\(destination)/"
          /bin/rm -rf "\(destination).backup"
        fi
        # Verified above, so clear the download flag to avoid a redundant prompt.
        /usr/bin/xattr -dr com.apple.quarantine "\(destination)" 2>/dev/null
        /usr/bin/open "\(destination)"
        /bin/rm -rf "\(staging.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path]
        try task.run()

        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "NetworkToggle.Update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - UI

    private enum ConfirmChoice: CustomStringConvertible {
        var description: String {
            switch self {
            case .install: "install"
            case .cancel: "cancel"
            case .skip: "skip"
            }
        }

        case install
        case cancel
        case skip
    }

    private static func confirmInstall(newVersion: String, current: String, allowSkip: Bool) -> ConfirmChoice {
        // An accessory app has no Dock presence, and a modal it puts up cannot reliably
        // take focus — runModal() then returns its default button without ever showing
        // anything. Becoming a regular app for the duration gives the alert something to
        // belong to; the policy is restored either way.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        let alert = NSAlert()
        alert.messageText = "Update to version \(newVersion)?"
        alert.informativeText = """
        You have \(current). The update will be downloaded, checked, and installed automatically.

        NetworkToggle will quit and reopen to finish. Your connection order and the \
        privileged helper are not affected.
        """
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Not Now")
        if allowSkip { alert.addButton(withTitle: "Skip This Version") }
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn where allowSkip: return .skip
        default: return .cancel
        }
    }

    private static func present(_ outcome: UpdateOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let current):
            alert.messageText = "You're up to date"
            alert.informativeText = "Version \(current) is the latest release."
        case .failed(let message):
            alert.messageText = "Update failed"
            alert.informativeText = message
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

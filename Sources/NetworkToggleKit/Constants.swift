import Foundation

public enum NetworkToggleIDs {
    public static let appBundleID = "com.smanke.NetworkToggle"
    public static let helperMachService = "com.smanke.NetworkToggle.Helper"
    public static let helperPlistName = "com.smanke.NetworkToggle.Helper.plist"
    public static let teamID = "32CWL275JJ"

    /// The code signing requirement each side of the XPC connection demands of the other.
    /// Anchored on the team ID rather than a code hash so it survives rebuilds — see the
    /// signing notes in build_app.sh.
    public static func requirement(identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    public static var appRequirement: String { requirement(identifier: appBundleID) }
    public static var helperRequirement: String { requirement(identifier: helperMachService) }
}

/// Current helper build. The app compares this against the installed helper and
/// re-registers when they diverge, so a helper left behind by an older install
/// gets replaced instead of silently answering with stale behaviour.
public enum HelperVersion {
    public static let current = 1
}

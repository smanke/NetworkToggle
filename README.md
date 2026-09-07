# NetworkToggle

A macOS menu bar app that makes the active network connection obvious and lets you
change it deliberately, instead of discovering an hour later that everything is still
running over Wi-Fi while a gigabit dock sits idle.

Requires macOS 26.

## The problem it solves

Three separate things cause "docked but still on Wi-Fi":

1. **A new dock creates a new network service.** Each dock's Ethernet chipset has its
   own MAC address, so plugging in an unfamiliar one makes macOS create a brand-new
   service and append it to the *bottom* of the service order — below Wi-Fi, where it
   will never be chosen. Configuring one dock does nothing for the next.
2. **A service with no usable lease never ranks.** macOS only promotes a service that
   has both an address and a router. A slow DHCP handshake or a self-assigned
   `169.254.x.x` address leaves Ethernet permanently below Wi-Fi.
3. **Open connections never migrate.** Even once the default route flips to Ethernet,
   existing TCP connections stay bound to the Wi-Fi source address for their lifetime.
   A VPN tunnel established over Wi-Fi keeps running over Wi-Fi. Only cycling Wi-Fi
   moves them.

NetworkToggle addresses all three, and is explicit about which one it is doing.

## Architecture

| Target | Runs as | Responsibility |
| --- | --- | --- |
| `NetworkToggleKit` | — | Shared XPC protocol, ids, and the unprivileged SCPreferences reader |
| `NetworkToggle` | you | Menu bar UI, `SCDynamicStore` monitoring, switch policy |
| `NetworkToggleHelper` | root | The only code that writes system configuration |

Reading the network configuration needs no privilege, so the app does that itself and
holds no elevated rights. Writing does, so every mutation is one of four narrow methods
on the daemon, each of which re-validates its arguments.

The daemon is installed with `SMAppService` — approved once, in System Settings — rather
than by prompting for an admin password on every launch.

### Security model

Both ends of the XPC connection pin the other's code signature to a requirement built
from the team ID, not a code hash:

```
identifier "com.smanke.NetworkToggle.Helper" and anchor apple generic
    and certificate leaf[subject.OU] = "32CWL275JJ"
```

The helper calls `setConnectionCodeSigningRequirement` so the kernel rejects
unauthorised callers before the delegate ever sees them; the app calls
`setCodeSigningRequirement` so it will not hand commands to a substituted daemon. A
code-hash-based (ad-hoc) signature would change on every rebuild and cannot be used —
`build_app.sh` fails rather than falling back to one.

`setServiceOrder` refuses anything that is not a permutation of the current order, so a
truncated list cannot silently unrank the services it omits.

### The guard that matters

Auto-switch does not fire on link-up. It waits for the interface to settle, requires a
non-link-local address *and* a default router, and then **pings the gateway**. A dock
whose uplink is dead presents a fully configured interface; only a reply distinguishes
it from a working one. No reply means NetworkToggle notifies instead of switching.

## Download

**[Download NetworkToggle (.dmg)](https://github.com/smanke/NetworkToggle/releases/latest/download/NetworkToggle.dmg)** — always the latest release.

Drag it to Applications and open it, then click **Install helper** once and approve the
prompt. Changing the connection order is a system setting, so it needs a small
privileged helper; the app itself holds no elevated rights.

Every [release](https://github.com/smanke/NetworkToggle/releases) also carries a
version-stamped copy of the same image, for pinning to a specific build.

## Build

```
./build_app.sh          # universal binary, signed with your Developer ID
./install.sh            # copies to /Applications and launches
```

`SMAppService` refuses to register a daemon for an app running anywhere but
`/Applications`, so running from `.build` will not work. `install.sh` updates an
existing install in place with `rsync` rather than replacing the directory, which would
orphan the daemon approval.

## Updates

NetworkToggle updates itself from the latest GitHub release's `.dmg` asset — a push
alone ships nothing to an installed copy. "Check for Updates…" in the menu does it on
demand; the launch check is silent unless there is something to offer, and a version you
skip is not raised again on its own.

A downloaded build is refused unless it passes `codesign --verify --deep --strict`,
carries the **same Team ID as the running copy**, and passes Gatekeeper assessment
(which means Apple notarized it). Any failure aborts and leaves the installed app alone.

The swap is an in-place `rsync`, not a delete and recreate. Replacing the bundle
directory would orphan the privileged helper's approval — the entry stays visible and
switched on under Login Items while the daemon is actually gone — so every update would
silently send you back through setup. After an update the app also asks a stale helper
to exit so launchd starts the new binary; the registration survives because the code
signing requirement is pinned to the team, not to a code hash.

Cutting a release:

```
./build_app.sh && ./notarize.sh && ./make_dmg.sh
cp .build/app/NetworkToggle-X.Y.Z.dmg .build/app/NetworkToggle.dmg
gh release create vX.Y.Z \
  ".build/app/NetworkToggle-X.Y.Z.dmg" \
  ".build/app/NetworkToggle.dmg" \
  --repo smanke/NetworkToggle
```

Both copies go up deliberately. GitHub's `releases/latest/download/<name>` redirect
needs an asset whose name does not change between releases, which is what makes the
download link in this README permanent; the version-stamped copy is what someone pins
to. They are byte-identical, so it does not matter which one the updater picks up.

Both the app *and* the disk image need their own notarization ticket: a download picks
up a quarantine attribute and Gatekeeper checks the image before it looks at the app.

## Development

`NETWORKTOGGLE_UI_PREVIEW=1` opens the popover's contents in an ordinary window;
`NETWORKTOGGLE_DEBUG=1` appends to `/tmp/networktoggle-debug.log`.

```
open -n --env NETWORKTOGGLE_UI_PREVIEW=1 --env NETWORKTOGGLE_DEBUG=1 /Applications/NetworkToggle.app
```

Icon: `./Tools/make_icns.sh` regenerates `Resources/AppIcon.icns`. The RJ45 socket is
drawn once in `Sources/NetworkToggle/ConnectorShape.swift` and compiled into both the
app and the icon generator, so the menu bar glyph and the app icon cannot drift apart.
Edit the path there, not the binary.

The menu bar glyph carries state in its weight: solid while a wired connection is
carrying traffic, hollow while it is not, badged when a wired link is sitting idle, and
struck through when nothing is connected. It drops the seven dividers between the eight
contacts that the app icon draws — at 18x16 they are under a pixel apart and smear.

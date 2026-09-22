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

## Live throughput

While the menu is open, the active connection shows live download and upload rates in
megabytes per second (1 MB = 1,000,000 bytes), refreshed every second and lightly
smoothed. With a VPN connected it measures the physical link underneath, so the figure
includes the VPN's own overhead — the real load on the wire.

Nothing is sampled while the menu is closed or when there is no active connection. Each
sample is one kernel query for a single interface's 64-bit byte counters; the 32-bit
counters from `getifaddrs` would wrap every 4 GiB, roughly every half minute on a busy
gigabit link.

## When a wired connection appears

Plug in a dock and NetworkToggle says so in a small panel below the menu bar. Which panel
depends on what macOS did on its own:

- **It already switched you** — the usual case, because the wired connection outranks Wi-Fi
  in the order: the panel reports **"Now on USB 10/100/1000 LAN"**, with **Keep it** and
  **Back to Wi-Fi**.
- **It did not** — the wired connection is available but something else is still active:
  the panel offers it — **"USB 10/100/1000 LAN is available"** — with **Switch** and
**Stay on Wi-Fi**.

Either way the two choices sit side by side, green for yes and red for no, the panel never
takes focus so it cannot interrupt typing, and it clears itself after 30 seconds. Whatever
is already plugged in when the app starts is not treated as an arrival, so launching the
app never puts a panel on screen. Settings offers **Ask me** (the
default), **Switch automatically**, or **Do nothing**.

The panel replaces a system notification because macOS hides a banner's buttons behind an
"Options" menu unless the user has set this app's notifications to Alerts — the two
choices could never sit side by side. Drawing it also means the buttons carry colour: a
panel that never takes focus renders standard controls in their inactive grey.

Before offering anything it waits for the link to settle and checks the gateway actually
answered on that interface, so a dock whose uplink is dead is never offered. That check
reads the router's resolved hardware address from the system configuration rather than
pinging it: ICMP from an ordinary app is dropped in silence without local-network
permission — verified by sending a ping that never came back while `/sbin/ping` answered
in 6 ms — so a probe alone would have refused every switch forever.

## Connections left on Wi-Fi

macOS sends *new* connections over the active connection but never moves existing ones:
each stays on the address it was opened from until it closes. A file share mounted while
Wi-Fi was active keeps every copy to it on Wi-Fi indefinitely — one NAS share here had
moved over 40 GB each way on Wi-Fi while Ethernet was the active connection.

While the menu is open, NetworkToggle lists connections still bound to an interface that
isn't the active one. It only *warns* when that matters: something is actually flowing
(more than 0.05 MB/s), or a file share is involved, whose next copy would go the wrong way
however idle it looks. Everything else — background keepalives that move a few KB/s — shows
as a quiet "N idle" count beside the connection instead of a warning. **Move to Ethernet** turns Wi-Fi off until they reconnect over the active
connection, then turns it back on. A quick off/on is not enough — Wi-Fi comes back with
the same address within seconds and the connections just resume — so it waits for them to
actually leave, for up to 30 seconds. File shares reconnect on their own within about ten
seconds. A connection an app pinned to Wi-Fi deliberately cannot move; the app reports how
many stayed.

The connection list comes from the privileged helper: macOS gives an ordinary app an empty
list, which hides the kernel's own file-share connections along with everything else's.
File-share servers are named from the mount table and resolved in the background; without
local-network permission the notice shows the server's address instead.

## VPNs

With a VPN connected, the menu shows the tunnel and the physical connection underneath
it — for example **NordVPN, over Thunderbolt Ethernet** — and that connection is the one
marked **Active · VPN**. Before 1.0.4 a full-tunnel VPN made the app report nothing as
connected, because macOS names the tunnel itself as the primary service and that service
is not one you configured.

The carrier is read from the VPN's own routing state: a NetworkExtension VPN excludes its
server from the tunnel and pins that route to an interface, which is checked against the
kernel's route and the VPN's live connection. The name comes from the one enabled VPN
configuration macOS has installed; with several, the menu just says "VPN".

**NetworkToggle will not move a running VPN to a different connection.** Measured with
NordVPN: putting Wi-Fi above the Ethernet link carrying the tunnel re-routed its server
within seconds, but the VPN's connection stayed bound to Ethernet's address and the
tunnel passed no traffic until the order was put back. So any reorder or switch that
would pull a full-tunnel VPN off its connection asks first. To choose which connection a
VPN uses, set the order while the VPN is disconnected, or change it and then reconnect
the VPN.

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
./release.sh 1.0.4
```

That sets the version, builds, notarizes, makes the disk image, tags, publishes, and
then checks that the permanent download link actually resolves before reporting success.
Set `RELEASE_NOTES` to supply the release body.

Every release carries the same disk image twice: version-stamped, and under the fixed
name `NetworkToggle.dmg`. GitHub's `releases/latest/download/<name>` redirect can only
resolve against an asset whose name is identical in every release, so shipping only the
version-stamped copy silently 404s the download link in this README for everyone —
which is exactly what happened to v1.0.3 when it was published by hand. `make_dmg.sh`
now emits both, and `release.sh` uploads both.

Both the app *and* the disk image need their own notarization ticket: a download picks
up a quarantine attribute and Gatekeeper checks the image before it looks at the app.

## Diagnostics

NetworkToggle appends what it decides to `~/Library/Logs/NetworkToggle.log` — which
connection it sees as active, every arrival and what it did about it, every switch. The
file is capped and always on, because os_log entries from this app never appear in
`log show` at any level, so without it "why did nothing happen when I plugged the dock in?"
could only be answered by reproducing with a special build.

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

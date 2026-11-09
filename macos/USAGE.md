# GoodbyeDPI VN for macOS

Requires macOS 13 or later. The application contains native Apple Silicon and
Intel binaries. Windows users continue to use the existing `.cmd` launchers.

## Start

Open `GoodbyeDPI macOS.app`, or double-click `3_steam_vn_dnsfix.command`.
Look for **DPI ○** in the menu bar, choose **Start**, and authenticate with your
Mac administrator account. The indicator becomes **DPI ●** after the backend
is listening and the firewall anchor has loaded. Restart Steam so its existing
connections are replaced.

If DNS poisoning is also affecting your connection, choose **Use Google DNS**
and select the network service you use, such as Wi-Fi. This is a separate,
explicit action. Each service's previous DNS configuration is saved once,
including whether it used automatic DNS.

Choose **Stop** to stop interception. Choose **Restore Previous DNS** for each
service whose DNS you changed. Stopping interception does not restore DNS.
Quitting the menu bar app leaves the background helper running; its quit dialog
explains this. The helper does not start automatically after reboot, but DNS
changes persist until restored.

The app is locally ad-hoc signed, not notarized with an Apple Developer identity.
If macOS blocks a copy downloaded from the internet, build from the supplied
source on your Mac or use Apple's per-app Open Anyway action in Privacy &
Security after reviewing the source. Do not disable Gatekeeper globally.

## Command line

From this package directory:

```sh
/bin/bash macos/goodbyedpi-macos.sh services
/bin/bash macos/goodbyedpi-macos.sh start
/bin/bash macos/goodbyedpi-macos.sh status
/bin/bash macos/goodbyedpi-macos.sh dns-set "Wi-Fi"
/bin/bash macos/goodbyedpi-macos.sh stop
/bin/bash macos/goodbyedpi-macos.sh dns-restore "Wi-Fi"
```

Administrative commands use `sudo`. Status and service listing are read-only.
The menu bar app uses the standard macOS administrator prompt instead.

## What is supported

The macOS version uses zapret's `tpws`; the Windows GoodbyeDPI executable and
WinDivert driver cannot run on macOS. It transparently handles outgoing TCP
ports 80 and 443 for non-root applications, including IPv4 and IPv6. HTTP/TLS
manipulation is restricted to the Steam domains in `steam-hosts.txt` and their
subdomains. Other public HTTP/HTTPS traffic traverses the local TCP proxy but
is forwarded without those manipulations. Private and loopback destinations
are excluded from interception.

The preset splits at byte 2, changes the HTTP Host header's case, and removes
the space after Host. These are `tpws` settings, not an exact port of GoodbyeDPI
`-3`. DNS uses Google's IPv4 and IPv6 resolvers when explicitly enabled.

To try the byte-40 split profile, run:

```sh
/bin/bash macos/goodbyedpi-macos.sh profile fast
/bin/bash macos/goodbyedpi-macos.sh stop
/bin/bash macos/goodbyedpi-macos.sh start
```

Use `profile compatibility` to return to byte 2. Profiles affect only the split
position and persist across app updates; neither setting is guaranteed for a
particular ISP. Existing Windows command-line flags are not accepted on macOS.

UDP games, QUIC, root-owned client connections, IP-address blocking, and every
possible ISP filtering method are not covered. DNS on port 53 can itself be
intercepted by an ISP. Successful startup does not prove that Steam is unblocked
on your connection. No remote proxy, VPN server, or TLS interception certificate
is involved.

Internet Sharing and IP forwarding must remain off while running. The helper
requires the standard macOS `com.apple/*` filter and redirect anchors to already
be loaded, and refuses custom main firewall rules or `set skip` configurations.
VPNs, firewall apps, and other tools that dynamically change PF may conflict.
Do not enable Internet Sharing or replace PF rules while this helper is running.

## Logs and recovery

**Show Log** displays the latest 64 KiB of `backend.log`; reopen it to refresh.
The root-owned installation directory is:

```text
/Library/Application Support/GoodbyeDPI VN/
```

It contains the helper, backend, domain list, licenses, log, `state.json`, and
`dns.json`. Preserve the JSON files until settings have been restored. DNS
snapshots use network service names; restore before renaming a service or
changing Network Locations. A removed/renamed service is deliberately refused.

If startup fails, read the menu status and log. If it reports **Recovery required**,
run **Stop** again. The helper recovers its saved firewall anchor and releases
only its own PF enable reference. It never disables PF globally, replaces
`/etc/pf.conf`, or flushes unrelated states. An unexpectedly exited backend
triggers cleanup; a forcibly killed supervisor requires Stop or the next Start
to recover. A reboot clears runtime PF rules; saved DNS still needs restoration.
Existing connections may need restarting after Stop.

One narrow crash window remains: if the system kills `pfctl`/the helper after
the kernel grants an enable reference but before its token is saved, PF may
remain enabled with no application redirection after recovery. A reboot clears
that reference. The app never guesses which other component's token to release
or disables the firewall globally to compensate.

The anchor is `com.apple/goodbyedpi-vn`. It is a direct child of Apple's standard
wildcard so the main ruleset need not be reloaded. If those wildcard hooks are
missing, the app refuses rather than attempting to repair your firewall.

To stop without the app or original package:

```sh
sudo '/Library/Application Support/GoodbyeDPI VN/helper' stop
sudo '/Library/Application Support/GoodbyeDPI VN/helper' dns-restore 'Wi-Fi'
```

## Build and test

Install Apple's Command Line Tools (`xcode-select --install`) if necessary:

```sh
/bin/bash macos/build.sh
python3 -m unittest discover -s macos/tests -v
```

The build is offline and uses the included source archive. It compiles both
architectures, creates universal binaries, bundles licenses, and applies local
signatures. Python 3 is needed only for tests, not to run the application.

Pinned upstream: `bol-van/zapret` revision
`73ee2aa04e6e94922e7dc07554a1c3a456dc3201`.

Archive: https://codeload.github.com/bol-van/zapret/tar.gz/73ee2aa04e6e94922e7dc07554a1c3a456dc3201

SHA-256: `dcef784d413ef95e98b34f0b657aac801b1f9b0601d6d9d95f6bf418d18e4533`.
The build checks this hash before extracting or compiling. No upstream installer
is executed. The original source archive is included for reproducibility and
license notices are bundled with the app.

Tests exercise the production lifecycle/DNS logic with simulated system commands.
Forwarding tests run the unmodified `tpws` on a loopback SOCKS listener and make
HTTP/HTTPS requests to `example.com`; internet access is required because upstream
intentionally refuses local SOCKS destinations. They verify TLS certificates and
the backend's split/HTTP manipulation logs, but do not capture packets or prove
wire-level segmentation. Apple's PF parser checks the actual generated anchor
with `-n`. Tests do not change the host's DNS, PF rules, or launchd services.
Artifacts are retained under `macos/build`. Live transparent PF routing and
ISP-specific Steam access need a separate administrator-enabled integration check.

Upstream macOS behavior: https://github.com/bol-van/zapret/blob/73ee2aa04e6e94922e7dc07554a1c3a456dc3201/docs/bsd.en.md

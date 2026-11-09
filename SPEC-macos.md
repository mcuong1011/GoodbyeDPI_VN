# macOS support specification

Status: approved by the user's "implement" instruction; implemented. Live
privileged transparent-routing and ISP-specific Steam verification remain pending.

## Objective

Add a native macOS way to run this package for the existing Steam access use
case. Preserve the supplied Windows launchers, tray application, binaries,
and service scripts.

The current package contains compiled Windows GoodbyeDPI executables and
WinDivert drivers, plus source for a Windows Forms tray launcher. It does not
contain the GoodbyeDPI networking engine source. This is a separate macOS
backend integration, not a recompilation of the Windows executable.

## Assumptions and scope

- Target macOS 13 or later, on Apple Silicon and Intel.
- Support Steam store, checkout, and content HTTP/HTTPS connections on TCP
  ports 80 and 443, including IPv4 and IPv6.
- Provide start, stop, status, and logs through a native menu bar application
  and a command-line controller.
- Provide an explicit Google DNS option, with restoration of the selected
  network service's previous configuration, including automatic DNS.
- Administrative authentication is required when starting transparent
  interception or changing DNS; ordinary status and log viewing do not need it.
- UDP game traffic, QUIC, root-owned client connections, and guaranteed bypass
  of every ISP's restrictions are outside the supported scope.
- Automatic start at login is not part of the initial implementation.

## Backend and architecture

Use the upstream zapret `tpws` backend, compiled natively for the target Mac.
Pin the upstream source revision and verify downloaded source before building.
Keep its license with any redistributed files. Do not download and execute an
unversioned installation script.

Use the documented macOS PF transparent redirection approach for outgoing
connections. Keep application rules in a dedicated anchor and preserve the
existing firewall configuration. Check compatibility before modifying PF;
fail with an actionable error if the existing configuration cannot be safely
integrated. Do not disable PF globally or flush unrelated rules or states.

Run the backend with the privileges its macOS PF lookup requires. Exclude its
connections from redirection to avoid loops. Bind only to the local interfaces
required for interception. Install privileged executable files and configuration
in a root-owned location before running them as a background service.

Treat the existing GoodbyeDPI `-3` preset as a description of intended behavior,
not compatible arguments for `tpws`. Document the selected HTTP/TLS manipulation
settings and expose a controlled way to tune them for the user's ISP.

Track the process, firewall resources, and DNS changes owned by this application.
Repeated starts must not create duplicate instances. Stop and startup-failure
recovery must remove the application's interception before terminating its
backend. Recover stale state after a crash without touching unrelated services.

Reject unsupported Internet Sharing configurations before enabling interception,
as upstream documents a conflict with its macOS transparent mode.

Sources:
- https://github.com/ValdikSS/GoodbyeDPI
- https://github.com/bol-van/zapret/blob/master/docs/bsd.en.md

## Proposed project structure

```text
macos/
  build.sh                  Native backend and application build
  goodbyedpi-macos.sh        Command-line controller
  GoodbyeDPI.swift           AppKit menu bar application
  Core.swift                Tested lifecycle and DNS transactions
  System.swift              Process, lock, and filesystem boundary
  Helper.swift              Validated privileged lifecycle operations
  steam-hosts.txt            Steam domains used for manipulation
  tests/                    Lifecycle, settings, and failure-path tests
  USAGE.md                  Installation, usage, recovery, and limitations
3_steam_vn_dnsfix.command    Finder entry point for macOS
```

The final file split may be simplified during implementation, provided the
privileged boundary and testable lifecycle remain clear.

## Proposed commands

Run these from the package directory after implementation:

```sh
/bin/bash macos/build.sh
/bin/bash macos/goodbyedpi-macos.sh start
/bin/bash macos/goodbyedpi-macos.sh status
/bin/bash macos/goodbyedpi-macos.sh stop
/bin/bash macos/goodbyedpi-macos.sh dns-set "Wi-Fi"
/bin/bash macos/goodbyedpi-macos.sh dns-restore "Wi-Fi"
python3 -m unittest discover -s macos/tests -v
```

The build requires Apple's Command Line Tools. The distributed application
must not require Python; Python is used only for development tests.

## Code style

Use English comments, quote shell arguments, and use argument arrays rather
than evaluating strings. Keep privileged operations small and validate inputs
before acting. Example shell style:

```sh
if [ ! -x "$backend_path" ]; then
    printf 'Backend is missing: %s\n' "$backend_path" >&2
    exit 1
fi
```

## Verification and acceptance criteria

1. Build and launch the menu bar application on the available Apple Silicon
   Mac. Verify Intel compilation separately; report Intel execution as untested
   unless an Intel machine is available.
2. Test first start, duplicate start, stop, restart, backend startup failure,
   backend exit, occupied port, and stale state recovery.
3. Test DNS save/restore for both custom and automatic settings, network service
   names containing spaces, repeated DNS changes, and partial command failure.
4. Test that invalid input or unsupported configuration makes no system changes.
5. Validate generated PF syntax and ensure stop affects only owned resources.
6. Exercise real HTTP/HTTPS forwarding locally. Separately report actual Steam
   access on the user's ISP; backend startup alone is not proof of bypass.
7. Verify Windows files remain byte-for-byte unchanged.
8. Document launch, stop, DNS restoration, troubleshooting, and coverage limits.

## Boundaries

- Always: retain recoverable settings, surface failures, test lifecycle logic,
  and distinguish mocked checks from real privileged networking verification.
- Ask before: enabling the finished interception on the user's active network
  or changing their live DNS configuration for an integration test.
- Never: remove user data, disable security protections globally, replace
  unrelated firewall rules, commit or push without a request, or claim that
  macOS reproduces every WinDivert feature.

## Review question

Is this Steam-focused macOS companion, using a native menu bar app and the
`tpws` backend, the intended scope?

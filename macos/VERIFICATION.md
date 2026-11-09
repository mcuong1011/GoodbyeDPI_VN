# Verification — 2026-11-06

Implemented a macOS companion with a universal AppKit menu bar application,
root-owned launchd supervisor, transparent tpws/PF integration, Steam host list,
two split profiles, and reversible DNS actions. Windows files are unchanged.

## Observed results

- `/bin/bash macos/build.sh` completed. App, helper, and tpws contain both arm64
  and x86_64 slices. The app bundle is approximately 1.1 MiB.
- Ad-hoc signing and `codesign --verify --deep --strict` succeeded.
- `python3 -m unittest discover -s macos/tests -v`: all 7 test methods passed,
  including 19 production-core lifecycle/DNS scenarios.
- The unmodified backend forwarded HTTP and certificate-verified HTTPS requests
  to example.com through a local SOCKS listener. Its log confirmed HTTP Host
  manipulation and selection of the byte-2 TLS split position. Non-Steam hosts
  passed through without manipulation when the Steam host list was supplied.
- A real SOCKS request to localhost was rejected, as required by upstream.
- Apple's `pfctl -n` accepted the generated production anchor without changing
  the firewall. Shell syntax and app property-list validation passed.
- A mutation reversing the original-DNS snapshot guard caused the round-trip
  test to fail. The mutation was built from a separate copy; production source
  was not changed for that check.
- SHA-256 comparison verified all 16 existing Windows executables, drivers,
  scripts, and tray files against the pre-change snapshot.
- LaunchServices opened the app on macOS 27.0.1 / Apple Silicon, and a read-only
  process check confirmed it running. The packaged helper reported stopped /
  not installed. No live DNS or PF settings were modified.

## Limits and review findings

- The native UI inspection tool timed out twice; no claim of visual menu testing
  is made. The app was left open in its inactive state for the user.
- Intel cross-compilation succeeded, but no Intel hardware execution was done.
  This host's Swift 6.4 linker warned that its optional compatibility-packs
  archive lacks an x86_64 slice. Builds and signatures completed; older macOS
  and Intel runtime compatibility still need device testing.
- macOS 13 is the build deployment target; execution was tested only on this
  host's macOS version.
- SOCKS forwarding and PF syntax checks do not prove transparent PF NAT lookup,
  on-wire TCP segmentation, or ISP-specific Steam bypass. Privileged integration
  was deliberately not enabled during implementation.
- Code review found a recovery failure when a crash occurred after a PF token
  was released but before state was saved. Cleanup now recognizes Apple's
  specific already-invalid-token response; the regression test passes.
- If cleanup fails, the supervisor retries while retaining the backend instead
  of immediately exiting and leaving a dead redirect target.
- A crash between the kernel granting a PF enable reference and saving the
  returned token can still leave an extra enable reference until reboot. This
  does not justify disabling PF globally; the limitation is documented in USAGE.
- DNS snapshots are tied to service names. Restore before renaming/removing a
  network service or switching Network Locations, as described in USAGE.

The source archive, third-party notices, build outputs, and test artifacts are
retained. No commits, pushes, or permanent file deletions were performed.

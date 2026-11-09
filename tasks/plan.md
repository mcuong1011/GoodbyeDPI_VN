# macOS implementation plan

The approved scope is the native Steam-focused companion in SPEC-macos.md.
The user's instruction to implement authorizes proceeding through these steps.

1. Pin, inspect, and compile zapret tpws. Verify the backend on local sockets.
2. Implement a Swift lifecycle core and command-line helper with regression tests.
   Use argument arrays, root-owned installation/state, a launchd supervisor,
   one application PF anchor, and PF reference tokens. Keep the main ruleset intact.
3. Add reversible per-service DNS operations and failure recovery tests.
4. Add the AppKit menu bar app, shell entry points, universal build, and usage docs.
5. Run the tests, inspect the built app, compare Windows checksums, and report
   live-network validation separately.

Swift replaces the proposed shell privileged helper so process arguments, state,
signals, locking, and file ownership can be handled without shell interpolation.
The helper and app share a small Foundation core. Python is only a test driver.

Risks: PF requires a real privileged integration test; tests use a command fake
for mutation paths. Custom firewall layouts and Internet Sharing are rejected.
The app does not enable interception or change live DNS merely by being opened.

Task details and completion evidence are in tasks/todo.md.

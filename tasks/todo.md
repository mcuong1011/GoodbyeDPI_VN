# macOS tasks

- [x] Backend: pin and checksum source, inspect build rules, build Apple Silicon
  and Intel slices; verify real HTTP/HTTPS through a loopback SOCKS listener to
  example.com. Upstream intentionally rejects local destinations.
- [x] Lifecycle: implement start/status/stop and crash recovery; test duplicate
  starts, stale state, startup failure, occupied port, and scoped PF cleanup.
- [x] DNS: preserve and restore custom/automatic DNS, including repeated changes
  and failure recovery; test service validation and names with spaces.
- [x] App: build native start/stop/status/log/DNS controls plus Finder launcher;
  verify universal binaries and launch the stopped app locally. Visual inspection
  could not be completed because the computer-use tool timed out.
- [x] Delivery: document usage and limitations, run all tests, verify unchanged
  Windows checksums, and record any unperformed live integration checks.

Pending optional integration: administrator-enabled PF interception, live DNS
change/restore, and actual Steam access on the user's ISP. These were not enabled
without the separate authorization required by the approved specification.

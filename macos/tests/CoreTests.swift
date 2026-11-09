import Foundation

enum TestFailure: Error { case failed(String) }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.failed(message) }
}
func expectError(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw TestFailure.failed("Expected operation to fail")
}

final class FakeSystem: SystemAccess {
    var calls: [[String]] = []
    var dns = ["Wi-Fi": ["192.0.2.53"], "USB Ethernet": [String]()]
    var failSet = false
    var failPF = false
    var failCleanup = false
    var tokenAlreadyReleased = false
    var customFirewall = false
    // Actual `pfctl -sr` / `-sn` output supplied by the user on macOS.
    var filterOutput = """
    No ALTQ support in kernel
    ALTQ related functions disabled
    scrub-anchor "com.apple/*" all fragment reassemble
    anchor "com.apple/*" all
    """
    var natOutput = """
    No ALTQ support in kernel
    ALTQ related functions disabled
    nat-anchor "com.apple/*" all
    rdr-anchor "com.apple/*" all
    """
    var sharing = false
    var boot = "boot-one"
    var backendArguments: [String] = []
    var child = FakeBackend()
    func command(_ executable: String, _ args: [String]) throws -> String {
        calls.append([executable] + args)
        if executable.hasSuffix("networksetup") {
            switch args[0] {
            case "-listallnetworkservices": return "An asterisk (*) denotes a disabled service.\nUSB Ethernet\nWi-Fi\n"
            case "-getdnsservers":
                let values = dns[args[1]]!
                return values.isEmpty ? "There aren't any DNS Servers set on \(args[1]).\n" : values.joined(separator: "\n")
            case "-setdnsservers":
                dns[args[1]] = Array(args.dropFirst(2)).filter { $0 != "Empty" }
                if failSet { failSet = false; throw TestFailure.failed("DNS write failed after mutation") }
            default: break
            }
        }
        if executable.hasSuffix("sysctl") {
            if args.contains("kern.bootsessionuuid") { return boot }
            return sharing ? "1" : "0"
        }
        if executable.hasSuffix("pgrep") { throw TestFailure.failed("No sharing process") }
        if executable.hasSuffix("ifconfig") { return "inet6 fe80::1%lo0 prefixlen 64" }
        if executable.hasSuffix("pfctl") {
            if args.first == "-X" && tokenAlreadyReleased { throw Failure("pfctl: pf: token invalid") }
            if args == ["-sr"] { return customFirewall ? "block drop all" : filterOutput }
            if args == ["-sn"] { return natOutput }
            if args == ["-E"] { return "pf enabled\nToken : 12345\n" }
            if args.contains("-f") && args.last != "/dev/null" && !args.contains("-n") && failPF {
                throw TestFailure.failed("PF load failed")
            }
            if args.last == "/dev/null" && failCleanup { throw TestFailure.failed("PF cleanup failed") }
        }
        return ""
    }
    func backend(_ arguments: [String]) throws -> BackendProcess {
        backendArguments = arguments
        child.started = true
        return child
    }
}

final class FakeBackend: BackendProcess {
    var started = false
    var alive = true
    var ready = true
    var stopped = false
    var running: Bool { alive && started && !stopped }
    func waitUntilReady() throws {
        if !ready { throw TestFailure.failed("Port occupied / backend failed") }
    }
    func stop() { stopped = true }
}

@main struct CoreTests {
    static func main() throws {
        let scopedListeners = "p29437\nf4\nn127.0.0.1:988\nf5\nn[fe80:1::1]:988\n"
        try expect(LiveBackend.hasRequiredListeners(scopedListeners, loopbackIndex: 1), "Darwin embedded IPv6 scope must be recognized")
        try expect(!LiveBackend.hasRequiredListeners("n127.0.0.1:988\nn[fe80:2::1]:988", loopbackIndex: 1), "A different interface must not satisfy readiness")
        try expect(!LiveBackend.hasRequiredListeners("n127.0.0.1:988\nn[fe80:1::1]:989", loopbackIndex: 1), "A different port must not satisfy readiness")
        let root = CommandLine.arguments[1]
        var count = 0
        func test(_ name: String, _ action: (Engine, FakeSystem) throws -> Void) throws {
            let dir = root + "/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let system = FakeSystem()
            let engine = try Engine(system: system, directory: dir, pfConfiguration: "# default\n")
            try action(engine, system)
            count += 1
            print("PASS \(name)")
        }
        try test("standard Apple scrub anchor passes preflight without loading firewall rules") { engine, system in
            try engine.preflight()
            try expect(!system.child.started, "Preflight must not start the backend")
            try expect(!system.calls.contains { $0.contains("-E") || ($0.contains("-f") && !$0.contains("-n")) }, "Preflight must not change PF")
        }
        try test("standard anchors do not mask custom filter rules") { engine, system in
            system.filterOutput += "\nblock drop all"
            try expectError { try engine.activate() }
            try expect(!system.child.started, "Custom policy still rejected")
        }
        try test("missing redirect anchor is still rejected") { engine, system in
            system.natOutput = "nat-anchor \"com.apple/*\" all"
            try expectError { try engine.activate() }
            try expect(!system.child.started, "Missing hook still rejected")
        }
        try test("custom scrub options are still rejected") { engine, system in
            system.filterOutput = system.filterOutput.replacingOccurrences(of: "fragment reassemble", with: "fragment reassemble no-df")
            try expectError { try engine.activate() }
            try expect(!system.child.started, "Custom scrub still rejected")
        }
        try test("commented skip directive does not block startup") { engine, system in
            let configured = try Engine(system: system, directory: engine.directory, pfConfiguration: "# set skip on lo0\n")
            try configured.preflight()
        }
        try test("active skip directive is still rejected") { engine, system in
            let configured = try Engine(system: system, directory: engine.directory, pfConfiguration: "set skip on lo0 # custom\n")
            try expectError { try configured.activate() }
            try expect(!system.child.started, "Active skip still rejected")
        }
        try test("custom DNS round trip and repeated set preserve original") { engine, system in
            try engine.setDNS("Wi-Fi")
            try engine.setDNS("Wi-Fi")
            try expect(system.dns["Wi-Fi"] == Engine.googleDNS, "Google DNS applied")
            try engine.restoreDNS("Wi-Fi")
            try expect(system.dns["Wi-Fi"] == ["192.0.2.53"], "Original DNS restored")
        }
        try test("automatic DNS and service names containing spaces") { engine, system in
            try engine.setDNS("USB Ethernet")
            try engine.restoreDNS("USB Ethernet")
            try expect(system.dns["USB Ethernet"] == [], "Automatic DNS restored")
        }
        try test("partial DNS write restores prior configuration") { engine, system in
            system.failSet = true
            try expectError { try engine.setDNS("Wi-Fi") }
            try expect(system.dns["Wi-Fi"] == ["192.0.2.53"], "Rollback after partial mutation")
        }
        try test("invalid service never changes settings") { engine, system in
            try expectError { try engine.setDNS("Wi-Fi; touch /tmp/no") }
            try expect(!system.calls.contains { $0.contains("-setdnsservers") }, "No mutation")
        }
        try test("restore without snapshot refuses") { engine, system in
            try expectError { try engine.restoreDNS("Wi-Fi") }
            try expect(!system.calls.contains { $0.contains("-setdnsservers") }, "No mutation")
        }
        try test("start and stop release only owned firewall reference") { engine, system in
            try engine.activate()
            try expect(engine.state.phase == "running", "Running")
            try engine.deactivate()
            try expect(engine.state.phase == "stopped", "Stopped")
            try expect(system.child.stopped, "Backend stopped")
            try expect(system.calls.contains { $0 == ["/sbin/pfctl", "-X", "12345"] }, "Owned token released")
            try expect(!system.calls.contains { $0.contains("-F") || $0.contains("-d") }, "No global flush or disable")
        }
        try test("duplicate activation refuses") { engine, _ in
            try engine.activate()
            try expectError { try engine.activate() }
            try engine.deactivate()
        }
        try test("occupied port leaves firewall untouched") { engine, system in
            system.child.ready = false
            try expectError { try engine.activate() }
            try expect(!system.calls.contains { $0.contains("-E") }, "No PF enable before readiness")
            try expect(system.child.stopped, "Failed backend terminated")
        }
        try test("failed PF activation rolls back") { engine, system in
            system.failPF = true
            try expectError { try engine.activate() }
            try expect(engine.state.token == nil, "Token released")
            try expect(system.child.stopped, "Backend stopped")
        }
        try test("cleanup failure retains recovery state and backend") { engine, system in
            try engine.activate()
            system.failCleanup = true
            try expectError { try engine.deactivate() }
            try expect(engine.state.token != nil, "Recovery token retained")
            try expect(!system.child.stopped, "No black hole from killing backend first")
            system.failCleanup = false
            try engine.deactivate()
        }
        try test("custom firewall refuses before backend launch") { engine, system in
            system.customFirewall = true
            try expectError { try engine.activate() }
            try expect(!system.child.started, "No backend")
        }
        try test("Internet Sharing / forwarding refuses before mutation") { engine, system in
            system.sharing = true
            try expectError { try engine.activate() }
            try expect(!system.child.started, "No backend")
        }
        try test("saved state recovers after supervisor disappears") { engine, system in
            try engine.activate()
            let recovered = try Engine(system: system, directory: engine.directory, pfConfiguration: "")
            try recovered.deactivate()
            try expect(!recovered.state.anchorActive && recovered.state.token == nil, "Stale interception cleared")
            try engine.deactivate()
        }
        try test("reboot does not release another session's token") { engine, system in
            try engine.activate()
            system.boot = "boot-two"
            try engine.deactivate()
            try expect(!system.calls.contains { $0.contains("-X") }, "No old token release after reboot")
        }
        try test("crash after token release can finish recovery") { engine, system in
            try engine.activate()
            system.tokenAlreadyReleased = true
            try engine.deactivate()
            try expect(engine.state.token == nil && engine.state.phase == "stopped", "Already-released reference cleared")
        }
        try test("failed DNS restoration keeps snapshot for retry") { engine, system in
            try engine.setDNS("Wi-Fi")
            system.failSet = true
            try expectError { try engine.restoreDNS("Wi-Fi") }
            try engine.restoreDNS("Wi-Fi")
            try expect(system.dns["Wi-Fi"] == ["192.0.2.53"], "Original snapshot survives failure")
        }
        try test("corrupted state fails closed") { engine, system in
            try "invalid".write(toFile: engine.directory + "/state.json", atomically: true, encoding: .utf8)
            try expectError { _ = try Engine(system: system, directory: engine.directory, pfConfiguration: "") }
            try expect(system.calls.isEmpty, "No mutation from corrupt state")
        }
        try test("profile uses only validated split positions") { engine, system in
            try expectError { try engine.setProfile("--daemon") }
            try engine.setProfile("fast")
            try engine.activate()
            try expect(system.backendArguments.contains("--split-pos=40"), "Selected profile applied")
            try engine.deactivate()
        }
        try test("supervisor lock excludes concurrent processes and releases on close") { engine, _ in
            let path = engine.directory + "/lock"
            var lock: FileLock? = try FileLock(path)
            try expect(FileLock.held(path), "Lock detected")
            try expectError { _ = try FileLock(path) }
            withExtendedLifetime(lock) {}
            lock = nil
            try expect(!FileLock.held(path), "Released lock detected")
        }
        print("\(count) core tests passed")
    }
}

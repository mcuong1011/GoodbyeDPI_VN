import Foundation
import Darwin

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

protocol BackendProcess: AnyObject {
    var running: Bool { get }
    func waitUntilReady() throws
    func stop()
}

protocol SystemAccess {
    func command(_ executable: String, _ arguments: [String]) throws -> String
    func backend(_ arguments: [String]) throws -> BackendProcess
}

struct RuntimeState: Codable {
    var phase = "stopped"
    var token: String?
    var boot: String?
    var anchorActive = false
    var error: String?
}

// DNS snapshots are separate from runtime state so the supervisor cannot
// overwrite a DNS change made while it is running.
final class Engine {
    static let anchor = "com.apple/goodbyedpi-vn"
    static let googleDNS = ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
    let system: SystemAccess
    let directory: String
    let pfConfiguration: String
    var state: RuntimeState
    var child: BackendProcess?

    init(system: SystemAccess, directory: String, pfConfiguration: String) throws {
        self.system = system
        self.directory = directory
        self.pfConfiguration = pfConfiguration
        state = try Self.read(RuntimeState.self, directory + "/state.json") ?? RuntimeState()
    }

    static func read<T: Decodable>(_ type: T.Type, _ path: String) throws -> T? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func write<T: Encodable>(_ value: T, _ name: String) throws {
        let path = directory + "/" + name
        let data = try JSONEncoder().encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        guard chmod(path, 0o644) == 0 else { throw Failure("Cannot set permissions on \(path)") }
    }

    func saveState() throws { try write(state, "state.json") }

    func setProfile(_ name: String) throws {
        guard ["compatibility", "fast"].contains(name) else {
            throw Failure("Profile must be compatibility (split at byte 2) or fast (split at byte 40). Stop and start to apply.")
        }
        try write(name, "profile.json")
    }

    func services() throws -> [String] {
        let output = try system.command("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return output.components(separatedBy: .newlines).dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    func validateService(_ service: String) throws {
        guard !service.isEmpty, !service.hasPrefix("-"), !service.contains("\n"),
              try services().contains(service) else {
            throw Failure("Unknown or disabled network service: \(service). Use the services command to list choices.")
        }
    }

    static func isAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }

    func currentDNS(_ service: String) throws -> [String] {
        let output = try system.command("/usr/sbin/networksetup", ["-getdnsservers", service])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output == "There aren't any DNS Servers set on \(service)." { return [] }
        let values = output.components(separatedBy: .newlines)
        guard !values.isEmpty, values.allSatisfy(Self.isAddress) else {
            throw Failure("Could not read DNS settings for \(service): \(output)")
        }
        return values
    }

    func applyDNS(_ values: [String], _ service: String) throws {
        _ = try system.command("/usr/sbin/networksetup", ["-setdnsservers", service] + (values.isEmpty ? ["Empty"] : values))
        guard try currentDNS(service) == values else { throw Failure("DNS verification failed for \(service)") }
        // Cache flushing is best effort; setting and verifying DNS is the transaction.
        _ = try? system.command("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try? system.command("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    func setDNS(_ service: String) throws {
        try validateService(service)
        var snapshots = try Self.read([String: [String]].self, directory + "/dns.json") ?? [:]
        let before = try currentDNS(service)
        if snapshots[service] == nil {
            snapshots[service] = before
            try write(snapshots, "dns.json") // Persist before the first mutation.
        }
        do { try applyDNS(Self.googleDNS, service) }
        catch {
            let original = error
            do { try applyDNS(before, service) }
            catch { throw Failure("DNS change failed: \(original). Rollback failed: \(error). The saved settings are retained; run dns-restore.") }
            throw original
        }
    }

    func restoreDNS(_ service: String) throws {
        try validateService(service)
        var snapshots = try Self.read([String: [String]].self, directory + "/dns.json") ?? [:]
        guard let saved = snapshots[service], saved.allSatisfy(Self.isAddress) else {
            throw Failure("No valid saved DNS settings for \(service).")
        }
        try applyDNS(saved, service)
        snapshots[service] = nil
        try write(snapshots, "dns.json")
    }

    static let rules = """
    # Owned by GoodbyeDPI VN. Only local, non-root TCP clients are redirected.
    table <localnets> const { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, ::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8 }
    rdr pass on lo0 inet proto tcp from !127.0.0.0/8 to !<localnets> port {80,443} -> 127.0.0.1 port 988
    rdr pass on lo0 inet6 proto tcp from !::1 to !<localnets> port {80,443} -> fe80::1 port 988
    pass out quick route-to (lo0 127.0.0.1) inet proto tcp from any to !<localnets> port {80,443} user > root
    pass out quick route-to (lo0 fe80::1) inet6 proto tcp from any to !<localnets> port {80,443} user > root

    """

    func preflight() throws {
        let filters = try system.command("/sbin/pfctl", ["-sr"])
        let translations = try system.command("/sbin/pfctl", ["-sn"])
        // A dedicated child of the standard wildcard avoids reloading /etc/pf.conf.
        // Reject custom root rules rather than unexpectedly overriding their policy.
        func rulesOnly(_ text: String) -> [String] {
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("No ALTQ") && !$0.hasPrefix("ALTQ") }
        }
        let filterRules = rulesOnly(filters)
        let natRules = rulesOnly(translations)
        let appleFilterAnchor = "anchor \"com.apple/*\" all"
        let appleScrubAnchor = "scrub-anchor \"com.apple/*\" all fragment reassemble"
        // `pfctl -sr` includes normalization rules. Apple's default scrub
        // anchor is part of the standard configuration, not a custom policy.
        guard (filterRules == [appleFilterAnchor] || filterRules == [appleScrubAnchor, appleFilterAnchor]),
              natRules.contains("rdr-anchor \"com.apple/*\" all"),
              natRules.allSatisfy({ ["rdr-anchor \"com.apple/*\" all", "nat-anchor \"com.apple/*\" all"].contains($0) }),
              !pfConfiguration.components(separatedBy: .newlines).contains(where: {
                  $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?.range(of: #"\bset\s+skip\b"#, options: .regularExpression) != nil
              }) else {
            throw Failure("Unsupported PF configuration. The standard com.apple/* filter and rdr anchors must already be loaded, with no custom root rules or set skip. The main firewall was not changed.")
        }
        guard try system.command("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0",
              try system.command("/usr/sbin/sysctl", ["-n", "net.inet6.ip6.forwarding"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0",
              (try? system.command("/usr/bin/pgrep", ["-x", "InternetSharing"])) == nil else {
            throw Failure("Disable Internet Sharing and IP forwarding before starting GoodbyeDPI.")
        }
        guard try system.command("/sbin/ifconfig", ["lo0"]).contains("fe80::1%lo0") else {
            throw Failure("The required IPv6 loopback address fe80::1%lo0 is missing.")
        }
        try Self.rules.write(toFile: directory + "/pf.anchor", atomically: true, encoding: .utf8)
        _ = try system.command("/sbin/pfctl", ["-n", "-a", Self.anchor, "-f", directory + "/pf.anchor"])
    }

    func activate() throws {
        guard child == nil else { throw Failure("Already running") }
        if state.anchorActive || state.token != nil { try deactivate() }
        try preflight()
        state.phase = "starting"
        state.error = nil
        try saveState()
        do {
            let profile = try Self.read(String.self, directory + "/profile.json") ?? "compatibility"
            guard ["compatibility", "fast"].contains(profile) else { throw Failure("Invalid saved profile") }
            child = try system.backend([
                "--user=root", "--port=988", "--bind-addr=127.0.0.1",
                "--bind-iface6=lo0", "--bind-linklocal=force",
                "--hostlist=" + directory + "/steam-hosts.txt",
                "--split-pos=\(profile == "fast" ? 40 : 2)", "--hostcase", "--hostnospace"
            ])
            try child!.waitUntilReady()
            state.boot = try system.command("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let output = try system.command("/sbin/pfctl", ["-E"])
            guard let tokenLine = output.components(separatedBy: .newlines).first(where: { $0.contains("Token :") }),
                  let token = tokenLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  !token.isEmpty, token.allSatisfy({ $0.isNumber }) else {
                throw Failure("PF did not return an enable-reference token: \(output)")
            }
            state.token = token
            state.anchorActive = true // A failed/partial load must also be cleaned up.
            try saveState()
            _ = try system.command("/sbin/pfctl", ["-a", Self.anchor, "-f", directory + "/pf.anchor"])
            guard child!.running else { throw Failure("Backend exited during activation") }
            state.phase = "running"
            try saveState()
        } catch {
            let original = error
            do { try deactivate() }
            catch { throw Failure("Startup failed: \(original). Cleanup failed: \(error). Run stop to retry recovery.") }
            state.phase = "failed"
            state.error = String(describing: original)
            try saveState()
            throw original
        }
    }

    func deactivate() throws {
        if state.anchorActive {
            _ = try system.command("/sbin/pfctl", ["-a", Self.anchor, "-f", "/dev/null"])
            state.anchorActive = false
            try saveState()
        }
        if let token = state.token {
            let boot = try system.command("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if state.boot == boot {
                guard !token.isEmpty, token.allSatisfy({ $0.isNumber }) else { throw Failure("Invalid saved PF token") }
                do { _ = try system.command("/sbin/pfctl", ["-X", token]) }
                catch {
                    // A crash can occur after the kernel releases the token but
                    // before state is saved. Apple's specific invalid-token
                    // response means that release is already complete.
                    guard String(describing: error).contains("pf: token invalid") else { throw error }
                }
            }
            state.token = nil
            try saveState()
        }
        child?.stop()
        child = nil
        state.phase = "stopped"
        try saveState()
    }
}

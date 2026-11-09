import Foundation
import Darwin

@main struct Helper {
    static func main() {
        do { try execute(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("GoodbyeDPI: \(error)\n".utf8))
            exit(1)
        }
    }

    static func execute(_ args: [String]) throws {
        guard let action = args.first else { throw Failure("Usage: helper install|start|stop|status|services|dns-set SERVICE|dns-restore SERVICE|profile compatibility|fast") }
        let expected = ["dns-set", "dns-restore", "profile"].contains(action) ? 2 : 1
        guard args.count == expected else { throw Failure("Incorrect arguments for \(action)") }
        let system = LiveSystem()
        if action == "services" {
            print(try system.command("/usr/sbin/networksetup", ["-listallnetworkservices"]), terminator: "")
            return
        }
        if action == "status" {
            guard FileManager.default.fileExists(atPath: installDirectory + "/state.json") else {
                print("Not installed / stopped")
                return
            }
            let state = try Engine.read(RuntimeState.self, installDirectory + "/state.json")!
            let active = FileLock.held(installDirectory + "/supervisor.lock")
            if state.phase == "running" && active { print("Running — Steam TCP 80/443") }
            else if state.anchorActive || state.token != nil { print("Recovery required — run Stop: \(state.error ?? state.phase)") }
            else if state.phase == "starting" && active { print("Starting") }
            else if let error = state.error { print("Stopped — \(error)") }
            else { print("Stopped") }
            return
        }
        guard ["install", "start", "stop", "run", "dns-set", "dns-restore", "profile"].contains(action) else {
            throw Failure("Unknown command: \(action)")
        }
        guard geteuid() == 0 else { throw Failure("This command requires administrator authentication. Use the app or sudo.") }
        umask(0o022)
        try secureDirectory()
        if action == "run" {
            try supervise(system)
            return
        }
        let lock = try FileLock(installDirectory + "/operation.lock")
        defer { withExtendedLifetime(lock) {} }
        let engine = try makeEngine(system)
        switch action {
        case "install": try install(system)
        case "start": try start(system, engine)
        case "stop": try stop(system)
        case "dns-set": try engine.setDNS(args[1]); print("Google DNS enabled for \(args[1]).")
        case "dns-restore": try engine.restoreDNS(args[1]); print("Previous DNS restored for \(args[1]).")
        case "profile": try engine.setProfile(args[1]); print("Profile saved. Stop and start to apply.")
        default: break
        }
    }

    static func install(_ system: LiveSystem) throws {
        guard !FileLock.held(installDirectory + "/supervisor.lock") else {
            print("Already installed and running. Stop before upgrading.")
            return
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for name in ["helper", "tpws", "steam-hosts.txt", "LICENSE-zapret.txt", "THIRD-PARTY-NOTICES.txt"] {
            let path = source.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw Failure("Required package file missing or not a regular file: \(path)")
            }
        }
        for name in ["helper", "tpws", "steam-hosts.txt", "LICENSE-zapret.txt", "THIRD-PARTY-NOTICES.txt"] {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            let target = installDirectory + "/" + name
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
            guard chmod(target, ["helper", "tpws"].contains(name) ? 0o755 : 0o644) == 0 else { throw Failure("Cannot set installed permissions") }
        }
        let plist: [String: Any] = [
            "Label": serviceLabel,
            "ProgramArguments": [installDirectory + "/helper", "run"],
            "RunAtLoad": true, "KeepAlive": false,
            "ProcessType": "Interactive", "ExitTimeOut": 15,
            "AbandonProcessGroup": false,
            "StandardOutPath": installDirectory + "/backend.log",
            "StandardErrorPath": installDirectory + "/backend.log"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: installDirectory + "/service.plist"), options: .atomic)
        print("Installed macOS helper and tpws. No networking settings changed.")
    }

    static func start(_ system: LiveSystem, _ engine: Engine) throws {
        if FileLock.held(installDirectory + "/supervisor.lock") {
            guard engine.state.phase == "running" else { throw Failure("A service is starting or recovering. Check status/logs first.") }
            print("Already running.")
            return
        }
        // A previous supervisor may have crashed. Recover its owned PF state
        // before replacing the launchd job; never trust a stored process ID.
        try engine.deactivate()
        try engine.preflight()
        guard FileManager.default.isExecutableFile(atPath: installDirectory + "/tpws") else {
            throw Failure("Run install first.")
        }
        if (try? system.command("/bin/launchctl", ["print", "system/" + serviceLabel])) != nil {
            _ = try system.command("/bin/launchctl", ["bootout", "system/" + serviceLabel])
        }
        try "run".write(toFile: installDirectory + "/request", atomically: true, encoding: .utf8)
        engine.state.phase = "starting"
        engine.state.error = nil
        try engine.saveState()
        _ = try system.command("/bin/launchctl", ["bootstrap", "system", installDirectory + "/service.plist"])
        for _ in 0..<150 {
            let state = try Engine.read(RuntimeState.self, installDirectory + "/state.json") ?? RuntimeState()
            if state.phase == "running", FileLock.held(installDirectory + "/supervisor.lock") {
                print("Running. Restart Steam to create new connections.")
                return
            }
            if state.phase == "failed" { throw Failure(state.error ?? "Backend failed; see backend.log") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A timed-out start must not unexpectedly turn interception on later.
        try stop(system)
        throw Failure("Startup timed out and was stopped. See backend.log.")
    }

    static func stop(_ system: LiveSystem) throws {
        try "stop".write(toFile: installDirectory + "/request", atomically: true, encoding: .utf8)
        for _ in 0..<150 {
            if !FileLock.held(installDirectory + "/supervisor.lock") { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !FileLock.held(installDirectory + "/supervisor.lock") else {
            throw Failure("The supervisor has not finished cleanup. Check backend.log and retry Stop; it has not been forcibly killed.")
        }
        // Also handles an abruptly killed supervisor with persisted PF state.
        try makeEngine(system).deactivate()
        if (try? system.command("/bin/launchctl", ["print", "system/" + serviceLabel])) != nil {
            _ = try system.command("/bin/launchctl", ["bootout", "system/" + serviceLabel])
        }
        print("Stopped. DNS is independent; use dns-restore to restore saved DNS.")
    }

    static func supervise(_ system: LiveSystem) throws {
        let lock = try FileLock(installDirectory + "/supervisor.lock")
        defer { withExtendedLifetime(lock) {} }
        let engine = try makeEngine(system)
        // Signals are handled on the same run loop as state transitions.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        var stopping = false
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { stopping = true }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }
        do {
            guard (try? String(contentsOfFile: installDirectory + "/request", encoding: .utf8)) != "stop" else { return }
            try engine.activate()
            while !stopping {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
                if (try? String(contentsOfFile: installDirectory + "/request", encoding: .utf8)) == "stop" { break }
                guard engine.child?.running == true else { throw Failure("tpws exited unexpectedly. Interception has been stopped; check backend.log.") }
            }
            try engine.deactivate()
        } catch {
            let original = error
            // Keep the backend alive if PF cleanup failed. Exiting here would
            // make launchd kill it while traffic was still being redirected.
            while true {
                do { try engine.deactivate(); break }
                catch {
                    engine.state.phase = "recovering"
                    engine.state.error = "\(original); cleanup: \(error). Retrying cleanup."
                    try? engine.saveState()
                    FileHandle.standardError.write(Data("\(engine.state.error!)\n".utf8))
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
                }
            }
            engine.state.phase = "failed"
            engine.state.error = String(describing: original)
            try engine.saveState()
            throw original
        }
    }
}

import Foundation
import Darwin

let installDirectory = "/Library/Application Support/GoodbyeDPI VN"
let serviceLabel = "local.goodbyedpi.vn"

final class LiveSystem: SystemAccess {
    let directory: String
    init(directory: String = installDirectory) { self.directory = directory }

    func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain before waiting: a full pipe must never deadlock the helper.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    func backend(_ arguments: [String]) throws -> BackendProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: directory + "/tpws")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        return LiveBackend(process: process, system: self)
    }
}

final class LiveBackend: BackendProcess {
    let process: Process
    let system: LiveSystem
    init(process: Process, system: LiveSystem) { self.process = process; self.system = system }
    var running: Bool { process.isRunning }

    static func hasRequiredListeners(_ output: String, loopbackIndex: UInt32) -> Bool {
        let lines = Set(output.components(separatedBy: .newlines))
        guard loopbackIndex != 0, lines.contains("n127.0.0.1:988") else { return false }
        let embedded = String(loopbackIndex, radix: 16)
        return lines.contains("n[fe80:\(embedded)::1]:988") ||
            lines.contains("n[fe80::1%lo0]:988") || lines.contains("n[fe80::1]:988")
    }

    func waitUntilReady() throws {
        var lastCheck = "No listener check completed."
        for _ in 0..<40 {
            guard running else { throw Failure("tpws exited before listening; see backend.log (port 988 may be occupied).") }
            do {
                let listeners = try system.command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(process.processIdentifier), "-iTCP:988", "-sTCP:LISTEN", "-Fn"])
                if Self.hasRequiredListeners(listeners, loopbackIndex: if_nametoindex("lo0")) { return }
                lastCheck = listeners.isEmpty ? "No listeners reported." : listeners
            } catch {
                lastCheck = String(describing: error)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw Failure("tpws did not open both loopback listeners within the startup deadline. Listener check: \(lastCheck)")
    }

    func stop() {
        guard running else { return }
        process.terminate()
        for _ in 0..<30 {
            if !running { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // The Process object still owns this live child; never kill a saved PID.
        if running { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

// Open only within the root-owned installation directory. Locks disappear on
// process exit, unlike PID files, so PID reuse and stale files cannot kill apps.
final class FileLock {
    let descriptor: Int32
    init(_ path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure("Cannot open lock: \(path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure("Another GoodbyeDPI operation is already in progress.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static func held(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}

func secureDirectory() throws {
    // Validate every ancestor, including the destination itself. Never follow
    // a pre-planted symlink or accept a directory writable by another account.
    var path = ""
    for part in installDirectory.split(separator: "/") {
        path += "/" + part
        var info = stat()
        if lstat(path, &info) != 0 {
            guard path == installDirectory, errno == ENOENT, mkdir(path, 0o755) == 0,
                  lstat(path, &info) == 0 else { throw Failure("Cannot create secure directory: \(path)") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0,
              (info.st_mode & 0o022) == 0 else { throw Failure("Unsafe installation directory: \(path)") }
    }
    // Existing files must also be owned by root and cannot be symlinks.
    for name in try FileManager.default.contentsOfDirectory(atPath: installDirectory) {
        var info = stat()
        let file = installDirectory + "/" + name
        guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, (info.st_mode & 0o022) == 0 else {
            throw Failure("Unsafe installed file: \(file)")
        }
    }
}

func makeEngine(_ system: LiveSystem) throws -> Engine {
    try Engine(system: system, directory: installDirectory,
               pfConfiguration: String(contentsOfFile: "/etc/pf.conf", encoding: .utf8))
}

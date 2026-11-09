import AppKit

@main struct GoodbyeDPI {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let status = NSMenuItem(title: "Checking status…", action: nil, keyEquivalent: "")
    var controls: [NSMenuItem] = []
    var timer: Timer?
    var busy = false
    var checking = false
    let queue = DispatchQueue(label: "local.goodbyedpi.vn.ui")
    var logWindow: NSWindow?

    var helper: String { Bundle.main.resourceURL!.appendingPathComponent("helper").path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count > 1 {
            NSApp.terminate(nil)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "DPI ○"
        item.button?.toolTip = "GoodbyeDPI VN — stopped"
        let menu = NSMenu()
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Start", #selector(start), to: menu)
        add("Stop", #selector(stop), to: menu)
        add("Show Log", #selector(showLog), to: menu)
        menu.addItem(.separator())
        for (title, action) in [("Use Google DNS", "dns-set"), ("Restore Previous DNS", "dns-restore")] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            parent.submenu = submenu
            menu.addItem(parent)
            queue.async { [weak self] in
                guard let self = self else { return }
                let output = (try? self.run(["services"])) ?? ""
                let names = output.components(separatedBy: .newlines).dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }
                DispatchQueue.main.async {
                    for name in names {
                        let entry = self.add(name, #selector(self.dns(_:)), to: submenu)
                        entry.representedObject = [action, name]
                    }
                    if names.isEmpty { submenu.addItem(withTitle: "No enabled services found", action: nil, keyEquivalent: "") }
                }
            }
        }
        menu.addItem(.separator())
        add("Usage and Limitations", #selector(usage), to: menu)
        menu.addItem(.separator())
        add("Quit Menu Bar App…", #selector(quit), to: menu)
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @discardableResult func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        controls.append(entry)
        return entry
    }

    func run(_ arguments: [String]) throws -> String {
        try LiveSystem().command(helper, arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh() {
        guard !busy, !checking else { return }
        checking = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let text: String
            do { text = try self.run(["status"]) } catch { text = "Status unavailable: \(error)" }
            DispatchQueue.main.async {
                self.checking = false
                guard !self.busy else { return }
                self.status.title = text
                self.item.button?.title = text.hasPrefix("Running") ? "DPI ●" : "DPI ○"
                self.item.button?.toolTip = "GoodbyeDPI VN — \(text)"
            }
        }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    func perform(_ arguments: [String], install: Bool = false) {
        guard !busy else { return }
        busy = true
        controls.forEach { $0.isEnabled = false }
        status.title = "Working…"
        let installed = installDirectory + "/helper"
        let command = (install ? Self.shellQuote(helper) + " install && " : "") +
            ([installed] + arguments).map(Self.shellQuote).joined(separator: " ")
        queue.async { [weak self] in
            var error: NSDictionary?
            let script = NSAppleScript(source: "do shell script \(Self.appleScriptString(command)) with administrator privileges")
            _ = script?.executeAndReturnError(&error)
            let message = error?[NSAppleScript.errorMessage] as? String
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.controls.forEach { $0.isEnabled = true }
                if let message = message { self.alert("Operation did not complete", message) }
                self.refresh()
            }
        }
    }

    @objc func start() { perform(["start"], install: true) }
    @objc func stop() { perform(["stop"]) }
    @objc func dns(_ sender: NSMenuItem) {
        guard let arguments = sender.representedObject as? [String] else { return }
        perform(arguments, install: true)
    }

    @objc func showLog() {
        let text: String
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: installDirectory + "/backend.log"))
            defer { try? file.close() }
            let size = try file.seekToEnd()
            try file.seek(toOffset: size > 65536 ? size - 65536 : 0)
            text = String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
        } catch { text = "No log yet. Start GoodbyeDPI to create the backend log.\n\n\(error)" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "GoodbyeDPI — Latest Log (reopen to refresh)"
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.autoresizingMask = [.width]
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        logWindow?.close()
        logWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func usage() {
        if let url = Bundle.main.url(forResource: "USAGE", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }

    @objc func quit() {
        let alert = NSAlert()
        alert.messageText = "Quit the menu bar app?"
        alert.informativeText = "Quitting does not stop the backend or restore DNS settings. Use Stop first to end interception, and Restore Previous DNS to undo DNS changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Menu Bar App")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }

    func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

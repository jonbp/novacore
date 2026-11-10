// Novacore's icon in the macOS menu bar, the counterpart of the Windows tray
// icon in tray/windows/ and the Plasma widget in tray/plasmoid/.
//
// It draws what the CLI describes. `novacore tray menu` gives the menu as
// JSON, with each item's action, and the dialogs to show (see
// tray/PROTOCOL.md), so new features belong in the CLI, not here. Commands
// that change something run through `novacore tray run`, detached, and this
// follows them with `novacore tray poll`.
//
// `novacore tray install` compiles this file into ~/Applications/Novacore
// Tray.app, with the CLI's path and this file's hash in its Info.plist, and
// starts it from a LaunchAgent. From then on it rebuilds itself when the
// repo's copy changes, e.g. after a git pull (checkForUpdate).

import AppKit
import CryptoKit
import UserNotifications

typealias JSON = [String: Any]

let appID = "io.github.jonbp.novacore.tray"
let ellipsis = "\u{2026}"
let middleDot = "\u{00B7}"

// The CLI, as `tray install` wrote it in Info.plist, or the first argument
// when this is run outside its app, e.g. while working on it.
let info = Bundle.main.infoDictionary ?? [:]
let command = info["NovacoreCommand"] as? String
    ?? (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "novacore")
let builtHash = info["NovacoreSourceHash"] as? String ?? ""
let repo = URL(fileURLWithPath: command).deletingLastPathComponent().deletingLastPathComponent()
let installedApp = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/Novacore Tray.app").path

// MARK: - Running novacore

struct Output {
    var code: Int32 = -1
    var out = ""
    var err = ""

    var lines: [String] { (out + err).components(separatedBy: "\n") }

    // novacore's own error message among LINES, which starts with a heavy
    // cross, if it wrote one.
    static func failure(in lines: [String]) -> String? {
        lines.last { $0.trimmed.hasPrefix("\u{2716}") }
    }

    // The line that best explains a failure: the first novacore wrote to
    // stderr, where its error messages go, else the first it wrote at all.
    var errorLine: String {
        let pick = { (s: String) in s.components(separatedBy: "\n").first { !$0.trimmed.isEmpty } }
        guard let line = pick(err) ?? pick(out) else { return "novacore exited with code \(code)" }
        return line.withoutLeadingSymbols
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    // Without novacore's ✖ or ✔ and the spaces before them.
    var withoutLeadingSymbols: String {
        replacingOccurrences(of: "^[^\\p{L}\\p{N}]+", with: "", options: .regularExpression).trimmed
    }
    var withoutLabelEllipsis: String {
        hasSuffix(ellipsis) ? String(dropLast()) : self
    }
}

func clean(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\r", with: "")
}

// Run novacore with ARGS off the main thread, and call DONE on it after.
func runNovacore(_ args: [String], _ done: @escaping (Output) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.currentDirectoryURL = repo
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    DispatchQueue.global().async {
        var result = Output()
        do {
            try process.run()
            // Read both at once, so neither pipe fills up and blocks it.
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            result = Output(code: process.terminationStatus, out: clean(outData), err: clean(errData))
        } catch {
            result.err = "Couldn't run \(command): \(error.localizedDescription)"
        }
        DispatchQueue.main.async { done(result) }
    }
}

// Quote S for a POSIX shell.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// Replace {key} in TEXT with each value.
func fill(_ text: String, _ values: [(String, String)]) -> String {
    values.reduce(text) { $0.replacingOccurrences(of: "{\($1.0)}", with: $1.1) }
}

func activate() {
    if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

// MARK: - Icon

// The status icons, like the other tray icons', come from status-icons.png,
// copied into the app from tray/, which tray/build-icons.sh renders from
// tray/status.svg: the globe from Novacore's link on jonbp.co.uk, with a pill
// whose colour shows the status. The sheet has a 64px cell for each theme and
// status, dark then light, each running, stopped, busy then error, with a
// column per size and the icon in each cell's top left corner.

enum IconState: String, CaseIterable { case running, stopped, busy, error }

let statusSizes = [16, 20, 24, 28, 32, 36, 40, 48, 64]

let statusSheet: CGImage? = Bundle.main.url(forResource: "status-icons", withExtension: "png")
    .flatMap { try? Data(contentsOf: $0) }
    .flatMap { NSBitmapImageRep(data: $0)?.cgImage }

func statusImage(_ state: IconState) -> NSImage {
    let side: CGFloat = 16  // points
    // Drawn when shown, so it follows the menu bar between light and dark.
    return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        guard let sheet = statusSheet else {
            NSApp.applicationIconImage.draw(in: rect)
            return true
        }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let row = (dark ? 0 : 4) + IconState.allCases.firstIndex(of: state)!
        // The image for the screen's pixels: 16px, or 32px on a Retina screen.
        let pixels = Int((rect.width * ctx.userSpaceToDeviceSpaceTransform.a).rounded())
        let col = statusSizes.firstIndex { $0 >= pixels } ?? statusSizes.count - 1
        let n = statusSizes[col]
        guard let cell = sheet.cropping(to: CGRect(x: col * 64, y: row * 64, width: n, height: n)) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cell, in: rect)
        return true
    }
}

// A button that runs a closure.
class ClosureButton: NSButton {
    var handler: () -> Void = {}

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc func fire() { handler() }
}

// MARK: - Forms

// The fields of a form dialog from the CLI, laid out for an NSAlert, checked
// as you type. See "Form dialogs" in tray/PROTOCOL.md.
class Form: NSObject, NSTextFieldDelegate {
    struct Field {
        let spec: JSON
        let id: String
        let type: String
        let control: NSView
        let hint: NSTextField?
    }

    var fields: [Field] = []
    let grid = NSGridView()
    let submit: NSButton

    init(_ specs: [JSON], submit: NSButton) {
        self.submit = submit
        super.init()
        for spec in specs {
            let id = spec["id"] as? String ?? ""
            let type = spec["type"] as? String ?? "text"
            let label = spec["label"] as? String ?? ""
            let options = spec["options"] as? [String] ?? []
            let value = spec["value"]
            var control: NSView
            var hint: NSTextField?
            switch type {
            case "choice":
                let popup = NSPopUpButton()
                popup.addItems(withTitles: options)
                if let v = value as? String { popup.selectItem(withTitle: v) }
                popup.target = self
                popup.action = #selector(changed)
                control = popup
                hint = hintLabel()
            case "combo":
                let combo = NSComboBox()
                combo.addItems(withObjectValues: options)
                combo.stringValue = value as? String ?? ""
                control = combo
                if let note = spec["note"] as? String { hint = hintLabel(note) }
            case "check":
                let check = NSButton(checkboxWithTitle: label, target: nil, action: nil)
                check.state = (value as? Bool ?? false) ? .on : .off
                control = check
            default:
                let text = NSTextField(string: value as? String ?? "")
                text.delegate = self
                control = text
                hint = hintLabel()
            }
            if let enabled = spec["enabled"] as? Bool, let c = control as? NSControl { c.isEnabled = enabled }
            if type == "check" {
                grid.addRow(with: [NSGridCell.emptyContentView, control])
            } else {
                grid.addRow(with: [NSTextField(labelWithString: label), control])
            }
            if let hint { grid.addRow(with: [NSGridCell.emptyContentView, hint]) }
            fields.append(Field(spec: spec, id: id, type: type, control: control, hint: hint))
        }
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 320
        grid.rowSpacing = 6
        update()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
    }

    func hintLabel(_ text: String = " ") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    var firstField: NSView? { fields.first { $0.type == "text" }?.control }

    func controlTextDidChange(_ notification: Notification) { update() }
    @objc func changed() { update() }

    func update() {
        var ok = true
        for field in fields {
            switch field.type {
            case "text":
                let text = field.control as! NSTextField
                if field.spec["lowercase"] as? Bool == true, text.stringValue != text.stringValue.lowercased() {
                    text.stringValue = text.stringValue.lowercased()
                }
                let v = text.stringValue.trimmed
                var problem: String?
                if v.isEmpty {
                    ok = false
                } else {
                    for rule in field.spec["rules"] as? [JSON] ?? [] {
                        let error = (rule["error"] as? String ?? "Not allowed").replacingOccurrences(of: "{value}", with: v)
                        if let pattern = rule["match"] as? String, v.range(of: pattern, options: .regularExpression) == nil {
                            problem = error
                        } else if let list = rule["notIn"] as? [String], list.contains(v) {
                            problem = error
                        }
                        if problem != nil { break }
                    }
                }
                if problem != nil { ok = false }
                field.hint?.textColor = problem == nil ? .secondaryLabelColor : .systemRed
                field.hint?.stringValue = problem
                    ?? (v.isEmpty ? " " : (field.spec["hint"] as? String ?? " ").replacingOccurrences(of: "{value}", with: v))
            case "choice":
                let v = (field.control as! NSPopUpButton).titleOfSelectedItem ?? ""
                field.hint?.stringValue = (field.spec["hints"] as? [String: String])?[v] ?? " "
            default:
                break
            }
        }
        submit.isEnabled = ok
    }

    // Each field's answer, as `tray submit` takes them.
    var values: [(String, String)] {
        fields.map { field in
            switch field.control {
            case let check as NSButton where field.type == "check":
                return (field.id, check.state == .on ? "1" : "0")
            case let popup as NSPopUpButton:
                return (field.id, popup.titleOfSelectedItem ?? "")
            case let text as NSTextField:
                return (field.id, text.stringValue.trimmed)
            default:
                return (field.id, "")
            }
        }
    }
}

// MARK: - The tray

class Tray: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var icons: [IconState: NSImage] = [:]
    var model: JSON?               // novacore tray menu, parsed
    var modelJSON = ""
    var problem = ""               // why novacore tray menu failed
    var refreshing = false
    var polling = false            // asking how the running command is doing
    var checkedAction = false
    var busy = false               // a command such as novacore up is running
    var busyLabel = ""
    var actionURL = ""
    var output: [String] = []
    var menuSignature = ""
    var menuOpen = false
    var updating = false
    var lastUpdateCheck: Date?
    var skippedUpdate = ""         // the hash of a repo version that didn't build
    var infoWindows: [String: NSWindow] = [:]
    var outputWindow: NSWindow?
    var outputView: NSTextView?
    var appearanceObserver: NSKeyValueObservation?
    // The editors an editor action's app can name, if they're installed.
    let editors: [String: URL] = [
        "vscode": "com.microsoft.VSCode",
        "zed": "dev.zed.Zed",
    ].compactMapValues { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One at a time: the newest wins, e.g. when the old one is updating.
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: appID) where other.processIdentifier != me {
            other.terminate()
        }
        setUpMainMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let defaults = UserDefaults.standard
        if let last = defaults.string(forKey: "lastRunHash"), !builtHash.isEmpty, last != builtHash {
            notify("Novacore", "The menu bar icon has been updated.")
        }
        if !builtHash.isEmpty { defaults.set(builtHash, forKey: "lastRunHash") }

        for state in IconState.allCases { icons[state] = statusImage(state) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        // The images draw for the menu bar's appearance, so redraw on a change.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { button, _ in
            DispatchQueue.main.async { button.needsDisplay = true }
        }

        schedule(30) { [weak self] in self?.refresh() }
        // Follow a running command's progress.
        schedule(1) { [weak self] in if self?.busy == true { self?.pollAction() } }
        updateView()
        refresh()
    }

    func schedule(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        // Common modes, so it carries on while a menu or dialog is open.
        RunLoop.main.add(Timer(timeInterval: seconds, repeats: true) { _ in block() }, forMode: .common)
    }

    // Accessory apps have no menu bar of their own, but text fields still need
    // its shortcuts for copy and paste.
    func setUpMainMenu() {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
                                     ("Close", "performClose:", "w")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let item = NSMenuItem()
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }

    // MARK: Status

    func refresh() {
        if refreshing || busy { return }
        refreshing = true
        runNovacore(["tray", "menu"]) { result in
            self.refreshing = false
            if result.code != 0 {
                self.problem = result.errorLine
            } else if let obj = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? JSON {
                self.model = obj
                self.modelJSON = result.out
                self.problem = ""
                // See if a command from before we started is still running.
                if !self.checkedAction {
                    self.checkedAction = true
                    self.pollAction()
                }
            } else {
                self.problem = "Couldn't read novacore's output. Is the CLI up to date?"
            }
            self.updateView()
            self.checkForUpdate()
        }
    }

    var statusText: String {
        if busy { return busyLabel }
        if !problem.isEmpty { return "Can't run novacore" }
        guard let model else { return "Checking\(ellipsis)" }
        return model["status"] as? String ?? ""
    }

    var iconState: IconState {
        if busy { return .busy }
        if !problem.isEmpty { return .error }
        return IconState(rawValue: model?["state"] as? String ?? "") ?? .stopped
    }

    // Bring the icon, tooltip and menu up to date.
    func updateView() {
        statusItem.button?.image = icons[iconState]
        statusItem.button?.toolTip = "Novacore\n\(statusText)"
        // Rebuilding the menu closes its open submenus, so only do it on a change.
        let signature = "\(busy)|\(busyLabel)|\(problem)|\(output.isEmpty)|\(modelJSON)"
        if signature != menuSignature {
            menuSignature = signature
            buildMenu()
        }
        updateOutputWindow()
    }

    // MARK: Menu

    func buildMenu() {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Novacore \(middleDot) \(statusText)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var detail = problem.isEmpty ? (model?["problem"] as? String ?? "") : problem
        if !detail.isEmpty {
            if detail.count > 80 { detail = String(detail.prefix(79)) + ellipsis }
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let items = model?["items"] as? [JSON] {
            addItems(items, to: menu)
        } else {
            // novacore couldn't say, so just what this can do on its own.
            addItems([["label": "Refresh", "action": ["tray": "refresh"]], ["separator": true],
                      ["label": "Quit", "action": ["tray": "quit"]]], to: menu)
        }
    }

    func addItems(_ items: [JSON], to menu: NSMenu) {
        for spec in items {
            if spec["separator"] as? Bool == true {
                menu.addItem(.separator())
                continue
            }
            let action = spec["action"] as? JSON
            if let action, action["editor"] != nil && editor(for: action) == nil { continue }
            let title = spec["label"] as? String ?? ""
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            var enabled = spec["enabled"] as? Bool ?? true
            if busy && spec["idle"] as? Bool == true { enabled = false }
            if action?["tray"] as? String == "output" && output.isEmpty { enabled = false }
            item.isEnabled = enabled
            if let action {
                item.target = self
                item.action = #selector(menuItemClicked(_:))
                item.representedObject = action
            }
            if spec["checked"] as? Bool == true { item.state = .on }
            if spec["bold"] as? Bool == true {
                item.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
            }
            if let sub = spec["items"] as? [JSON] {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                addItems(sub, to: submenu)
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    // Opening the menu is a good time to check.
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc func menuItemClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? JSON else { return }
        // Let the menu close first, so dialogs come up in front.
        DispatchQueue.main.async { self.perform(action) }
    }

    // The editor an editor action names, or nil if it isn't installed.
    func editor(for action: JSON) -> URL? {
        editors[action["app"] as? String ?? "vscode"]
    }

    // Carry out an action from the CLI. See "Actions" in tray/PROTOCOL.md.
    func perform(_ action: JSON) {
        let title = action["title"] as? String ?? "Novacore"
        if let url = action["open"] as? String, let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        } else if let path = action["folder"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let path = action["editor"] as? String, let app = editor(for: action) {
            open(URL(fileURLWithPath: path), with: app)
        } else if let path = action["terminal"] as? String, let terminal {
            open(URL(fileURLWithPath: path), with: terminal)
        } else if let args = action["console"] as? [String] {
            openConsole(title, args)
        } else if let args = action["run"] as? [String] {
            startAction(args, label: action["label"] as? String ?? "Working\(ellipsis)",
                        done: action["done"] as? String ?? "", url: action["url"] as? String ?? "")
        } else if action["dialog"] as? String == "form" {
            showForm(action)
        } else if action["dialog"] as? String == "info" {
            showInfo(action)
        } else if let name = action["tray"] as? String {
            switch name {
            case "output": showOutput()
            case "refresh": refresh()
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }
    }

    func open(_ file: URL, with app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // Run novacore ARGS in a new Terminal window, through a .command file,
    // which Terminal runs without asking for permission to be scripted.
    func openConsole(_ title: String, _ args: [String]) {
        guard let terminal else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Novacore")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).command")
        let script = """
            #!/bin/bash
            rm -f -- "$0"
            printf '\\033]0;%s\\007' \(shellQuote(title))
            export PATH=\(shellQuote(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"))
            cd \(shellQuote(repo.path))
            exec \(([command] + args).map(shellQuote).joined(separator: " "))

            """
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            open(file, with: terminal)
        } catch {
            notify("Couldn't open a terminal", error.localizedDescription)
        }
    }

    // MARK: Commands

    // Run a novacore command that changes something, such as up or php. It
    // runs detached (see `novacore tray run`), so it finishes even if this
    // quits meanwhile, and pollAction follows it from there.
    func startAction(_ args: [String], label: String, done: String, url: String) {
        if busy { return }
        busy = true
        busyLabel = label
        actionURL = url
        output = []
        updateView()
        runNovacore(["tray", "run", label, done] + args) { result in
            if result.code == 0 { return }
            // It didn't start, e.g. as another command is still running.
            self.busy = false
            self.notify("Couldn't start: \(label.withoutLabelEllipsis)", result.errorLine)
            self.updateView()
        }
    }

    // Check on the running command: its output so far, or how it ended.
    func pollAction() {
        if polling { return }
        polling = true
        runNovacore(["tray", "poll"]) { result in
            self.polling = false
            if result.code != 0 { return }  // Try again on the next tick.
            var lines = result.out.components(separatedBy: "\n")
            while lines.count < 4 { lines.append("") }
            let exit = lines[0].trimmed, alive = lines[1] == "alive", label = lines[2], done = lines[3]
            var log = Array(lines.dropFirst(4))
            while let last = log.last, last.trimmed.isEmpty { log.removeLast() }

            if exit.isEmpty && alive {
                // Running, perhaps started before this was.
                self.busy = true
                if !label.isEmpty { self.busyLabel = label }
                self.output = log
                self.updateView()
                return
            }
            // Finished. Only report it if we saw it running; otherwise it's an old one.
            if !self.busy { return }
            self.busy = false
            self.output = log
            if exit == "0" {
                self.notify("Novacore", done.isEmpty ? "Done: \(label.withoutLabelEllipsis)" : done, url: self.actionURL)
            } else {
                var message = Output.failure(in: log) ?? log.last { !$0.trimmed.isEmpty }
                if exit.isEmpty { message = "novacore stopped before it finished." }
                self.notify("Couldn't finish: \(label.withoutLabelEllipsis)",
                            message?.withoutLeadingSymbols ?? "novacore exited with code \(exit)", showsOutput: true)
            }
            self.updateView()
            self.refresh()
        }
    }

    // Rebuild this app when the repo's source or icons have changed, e.g. after
    // a git pull, by running `novacore tray install`, which restarts it.
    func checkForUpdate() {
        guard !builtHash.isEmpty, Bundle.main.bundlePath == installedApp, !updating else { return }
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 60 { return }
        // Restarting would close the menu or a window in use, so wait for a
        // quiet moment. A running command is fine: it runs on its own.
        if menuOpen || NSApp.modalWindow != nil || !infoWindows.isEmpty || outputWindow != nil { return }
        lastUpdateCheck = Date()
        // The same files as mac_tray_hash in bin/novacore, in the same order.
        let dir = repo.appendingPathComponent("tray/macos")
        guard let source = try? Data(contentsOf: dir.appendingPathComponent("NovacoreTray.swift")),
              let icon = try? Data(contentsOf: dir.appendingPathComponent("novacore.icns")),
              let sheet = try? Data(contentsOf: repo.appendingPathComponent("tray/status-icons.png")) else { return }
        let hash = SHA256.hash(data: source + icon + sheet).map { String(format: "%02x", $0) }.joined()
        if hash == builtHash || hash == skippedUpdate { return }

        updating = true
        runNovacore(["tray", "install"]) { result in
            self.updating = false
            if result.code == 0 {
                // launchd has started the new one, which quits this one, but
                // in case this wasn't started by launchd:
                NSApp.terminate(nil)
                return
            }
            // Don't try that version again, e.g. one saved mid-edit.
            self.skippedUpdate = hash
            self.output = result.lines
            let message = Output.failure(in: result.lines) ?? result.errorLine
            self.notify("Couldn't update the menu bar icon", message.withoutLeadingSymbols, showsOutput: true)
            self.updateView()
        }
    }

    // MARK: Notifications

    // A notification. Clicking one with SHOWSOUTPUT opens the output window,
    // and one with a URL opens that. If notifications are off, failures
    // open the output window straight away, so they aren't missed.
    func notify(_ title: String, _ body: String, url: String = "", showsOutput: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            DispatchQueue.main.async {
                if !allowed {
                    if showsOutput { self.showOutput() }
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.userInfo = ["url": url, "output": showsOutput]
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if info["output"] as? Bool == true {
                self.showOutput()
            } else if let url = info["url"] as? String, !url.isEmpty, let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        }
        completionHandler()
    }

    // MARK: Windows

    func newWindow(_ title: String, _ content: NSView, resizable: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable); style.insert(.miniaturizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === outputWindow {
            outputWindow = nil
            outputView = nil
        }
        infoWindows = infoWindows.filter { $0.value !== window }
    }

    // The output of the last command.
    func showOutput() {
        if outputWindow == nil {
            let scroll = NSTextView.scrollableTextView()
            let text = scroll.documentView as! NSTextView
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textContainerInset = NSSize(width: 6, height: 6)
            scroll.frame = NSRect(x: 0, y: 0, width: 760, height: 440)
            outputWindow = newWindow("Novacore", scroll, resizable: true)
            outputWindow?.setContentSize(NSSize(width: 760, height: 440))
            outputWindow?.center()
            outputView = text
        }
        updateOutputWindow()
        activate()
        outputWindow?.makeKeyAndOrderFront(nil)
    }

    func updateOutputWindow() {
        guard let window = outputWindow, let view = outputView else { return }
        window.title = busy ? "Novacore \(middleDot) \(busyLabel)" : "Novacore \(middleDot) Output"
        let text = output.isEmpty ? "Waiting for output\(ellipsis)" : output.joined(separator: "\n")
        if view.string != text {
            view.string = text
            view.scrollToEndOfDocument(nil)
        }
    }

    // A dialog of details, each with a Copy button, e.g. a site's Info.
    func showInfo(_ spec: JSON) {
        let title = spec["title"] as? String ?? "Novacore"
        if let window = infoWindows[title] {
            activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let grid = NSGridView()
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 6
        for section in spec["sections"] as? [JSON] ?? [] {
            let heading = NSTextField(labelWithString: section["heading"] as? String ?? "")
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let row = grid.addRow(with: [heading, NSGridCell.emptyContentView, NSGridCell.emptyContentView])
            row.mergeCells(in: NSRange(location: 0, length: 3))
            if grid.numberOfRows > 1 { row.topPadding = 12 }
            for pair in section["rows"] as? [[String]] ?? [] where pair.count == 2 {
                let value = NSTextField(string: pair[1])
                value.isEditable = false
                value.isSelectable = true
                value.lineBreakMode = .byTruncatingMiddle
                value.widthAnchor.constraint(equalToConstant: 460).isActive = true
                let copy = ClosureButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pair[1], forType: .string)
                }
                copy.controlSize = .small
                grid.addRow(with: [NSTextField(labelWithString: pair[0]), value, copy])
            }
        }
        grid.column(at: 0).xPlacement = .trailing

        var buttons: [NSView] = (spec["buttons"] as? [JSON] ?? []).map { button in
            ClosureButton(button["label"] as? String ?? "") { [weak self] in
                if let action = button["action"] as? JSON { self?.perform(action) }
            }
        }
        var window: NSWindow?
        let close = ClosureButton("Close") { window?.close() }
        close.keyEquivalent = "\r"
        buttons.append(close)
        let row = NSStackView(views: buttons)
        let stack = NSStackView(views: [grid, row])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        window = newWindow(title, stack)
        infoWindows[title] = window
        activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // A dialog that asks for something, then runs its action with the
    // answers, e.g. Add Site.
    func showForm(_ spec: JSON) {
        let alert = NSAlert()
        alert.messageText = spec["heading"] as? String ?? spec["title"] as? String ?? ""
        alert.informativeText = spec["message"] as? String ?? ""
        alert.icon = NSApp.applicationIconImage
        let submit = alert.addButton(withTitle: spec["submit"] as? String ?? "OK")
        let cancel = alert.addButton(withTitle: "Cancel")
        if spec["destructive"] as? Bool == true {
            // Return cancels rather than, say, removing a site.
            submit.hasDestructiveAction = true
            submit.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        let fields = spec["fields"] as? [JSON] ?? []
        let form = Form(fields, submit: submit)
        if !fields.isEmpty { alert.accessoryView = form.grid }
        alert.layout()
        if let first = form.firstField { alert.window.initialFirstResponder = first }
        activate()
        guard alert.runModal() == .alertFirstButtonReturn,
              let action = spec["action"] as? JSON, let run = action["run"] as? [String] else { return }

        let values = form.values
        startAction(run + values.map { "\($0.0)=\($0.1)" },
                    label: fill(action["label"] as? String ?? "Working\(ellipsis)", values),
                    done: fill(action["done"] as? String ?? "", values),
                    url: fill(action["url"] as? String ?? "", values))
    }
}

let app = NSApplication.shared
let tray = Tray()
app.delegate = tray
app.setActivationPolicy(.accessory)
app.run()

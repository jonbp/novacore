// Novacore's icon in the macOS menu bar, the counterpart of the Windows tray
// icon in tray/windows/ and the Plasma widget in tray/plasmoid/.
//
// It draws what the CLI describes. `novacore tray menu` gives the menu as
// JSON, with each item's action, and the dialogs to show (see
// tray/PROTOCOL.md), so new features belong in the CLI, not here. Commands
// that change something run through `novacore tray run`, detached, and this
// follows them with `novacore tray poll`.
//
// A click opens a panel in the style of Control Center, and a right click or
// Control-click the same items as a menu.
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

// The PATH and LANG you had when you ran `tray install`, so the CLI finds
// docker. launchd gives the app them when it starts it at login, but opening
// the app from Finder or Spotlight gives it macOS's bare PATH instead.
for (key, name) in [("NovacorePath", "PATH"), ("NovacoreLang", "LANG")] {
    if let value = info[key] as? String, !value.isEmpty { setenv(name, value, 1) }
}
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

// MARK: - Panel views
//
// What a click on the icon opens: a panel in the style of macOS's Control
// Center, drawn from the layout novacore gives with the menu, as the Windows
// tray icon's panel is (see "The panel" in tray/PROTOCOL.md). The views lay themselves out by hand and
// draw with the system's colours, so they follow light and dark mode and the
// accent colour by themselves. Tray.buildPanel fills them in.

let panelWidth: CGFloat = 340

// SF Symbols for the icon names in tray/PROTOCOL.md, and the panel's own.
let symbolNames: [String: String] = [
    "dashboard": "house", "site": "globe", "open": "arrow.up.right",
    "git": "chevron.left.forwardslash.chevron.right", "info": "info.circle", "folder": "folder",
    "code": "square.and.pencil", "terminal": "terminal", "log": "doc.text", "remove": "trash",
    "add": "plus", "start": "play.fill", "stop": "stop.fill", "restart": "arrow.clockwise",
    "bug": "ladybug", "tools": "wrench.and.screwdriver", "database": "cylinder.split.1x2",
    "output": "terminal", "refresh": "arrow.clockwise", "quit": "power",
    "error": "exclamationmark.triangle.fill", "right": "chevron.right", "down": "chevron.down",
    "updown": "chevron.up.chevron.down",
]

func symbol(_ name: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular) -> NSImage? {
    guard let s = symbolNames[name] else { return nil }
    return NSImage(systemSymbolName: s, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

// Draw IMAGE in COLOR, centred in RECT.
func drawSymbol(_ image: NSImage?, _ color: NSColor, in rect: NSRect) {
    guard let image else { return }
    let size = image.size
    // The colour for the current appearance, solid, with its alpha applied
    // when drawing, as filling the symbol with a faint colour would leave it
    // mostly black. Resolved for plain light or dark, as the panel's vibrant
    // appearance gives opaque greys that only work with vibrancy's blending.
    let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var resolved = color
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
    }
    let solid = resolved.withAlphaComponent(1)
    let tinted = NSImage(size: size, flipped: false) { r in
        image.draw(in: r)
        solid.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let r = NSRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                   width: size.width, height: size.height)
    tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent,
                respectFlipped: true, hints: nil)
}

// Draw one line of TEXT, centred vertically in RECT, cut short to fit.
func drawText(_ text: String, _ font: NSFont, _ color: NSColor, in rect: NSRect, align: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    style.alignment = align
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let h = ceil(s.size().height)
    s.draw(with: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

func fillRounded(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

// A faint fill of the text colour: dark on light, light on dark.
func tint(_ alpha: CGFloat) -> NSColor { NSColor.labelColor.withAlphaComponent(alpha) }

let avatarColors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemGreen,
                               .systemPink, .systemIndigo, .systemRed, .systemBrown]

// A colour for NAME's avatar, the same each time.
func avatarColor(_ name: String) -> NSColor {
    var h: Int32 = 0
    for c in name.utf16 { h = h &* 31 &+ Int32(c) }
    return avatarColors[Int(h & 0x7FFFFFFF) % avatarColors.count]
}

func statusColor(_ state: IconState) -> NSColor {
    switch state {
    case .running: return .systemGreen
    case .stopped: return .systemGray
    case .busy: return .systemOrange
    case .error: return .systemRed
    }
}

// A view whose height depends on its width.
protocol Sized { func height(for width: CGFloat) -> CGFloat }

class Flipped: NSView {
    override var isFlipped: Bool { true }
    // Lay out the subviews for the current size.
    func place() {}
}

// Views one above the other, each the full width less its margins.
class Column: Flipped, Sized {
    var padding = NSEdgeInsets()
    private var margins: [ObjectIdentifier: NSEdgeInsets] = [:]

    func add(_ view: NSView, top: CGFloat = 0, side: CGFloat = 0, bottom: CGFloat = 0) {
        addSubview(view)
        margins[ObjectIdentifier(view)] = NSEdgeInsets(top: top, left: side, bottom: bottom, right: side)
    }

    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        margins = [:]
    }

    // Lay the views out for WIDTH, and return the height they take.
    @discardableResult func arrange(_ width: CGFloat) -> CGFloat {
        var y = padding.top
        for v in subviews where !v.isHidden {
            let m = margins[ObjectIdentifier(v)] ?? NSEdgeInsets()
            let w = width - padding.left - padding.right - m.left - m.right
            let h = (v as? Sized)?.height(for: w) ?? v.fittingSize.height
            v.frame = NSRect(x: padding.left + m.left, y: y + m.top, width: w, height: h)
            (v as? Flipped)?.place()
            y += m.top + h + m.bottom
        }
        return y + padding.bottom
    }

    func height(for width: CGFloat) -> CGFloat { arrange(width) }
    override func place() { arrange(bounds.width) }
}

// What an expanded row shows its items in.
class Card: Column {
    override func draw(_ dirtyRect: NSRect) { fillRounded(bounds, 10, tint(0.05)) }
}

// A view that lights up under the mouse and does something when clicked.
class Control: Flipped {
    var onClick: (() -> Void)? { didSet { updateHover() } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4; updateHover() } }
    var radius: CGFloat = 7
    var hovered = false { didSet { needsDisplay = true } }
    var pressed = false { didSet { needsDisplay = true } }
    private var mouseInside = false

    var clickable: Bool { isEnabled && onClick != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    func updateHover() { hovered = mouseInside && clickable }
    override func mouseEntered(with event: NSEvent) { mouseInside = true; updateHover() }
    override func mouseExited(with event: NSEvent) { mouseInside = false; updateHover() }

    func inside(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        guard clickable else { return super.mouseDown(with: event) }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        if clickable { pressed = inside(event) }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && inside(event)
        pressed = false
        if fire { onClick?() }
    }

    // The fill behind it, if any.
    func background() -> NSColor? {
        pressed ? tint(0.16) : hovered ? tint(0.09) : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if let color = background() { fillRounded(bounds, radius, color) }
    }
}

// Novacore's icon and status, at the top. Clicking it opens the dashboard.
class Header: Control, Sized {
    var status = ""
    var color = NSColor.systemGray

    func height(for width: CGFloat) -> CGFloat { 52 }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let icon = NSRect(x: 8, y: ((bounds.height - 34) / 2).rounded(), width: 34, height: 34)
        // The icon as the system draws it, in the style you've chosen. Like
        // other app icons, its tile is inset on the canvas, so draw it larger
        // to make up for that.
        let grow = icon.width * (1 / 0.8047 - 1) / 2
        NSApp.applicationIconImage.draw(in: icon.insetBy(dx: -grow, dy: -grow), from: .zero, operation: .sourceOver,
                                        fraction: 1, respectFlipped: true, hints: nil)
        let x = icon.maxX + 10, w = bounds.width - x - 32
        drawText("Novacore", .systemFont(ofSize: 13, weight: .semibold), .labelColor,
                 in: NSRect(x: x, y: bounds.midY - 17, width: w, height: 17))
        let line = NSRect(x: x, y: bounds.midY + 1, width: w, height: 15)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: line.midY - 3.5, width: 7, height: 7)).fill()
        drawText(status, .systemFont(ofSize: 11), .secondaryLabelColor,
                 in: NSRect(x: x + 12, y: line.minY, width: w - 12, height: line.height))
        if hovered {
            drawSymbol(symbol("open", 11, .semibold), .secondaryLabelColor,
                       in: NSRect(x: bounds.width - 30, y: 0, width: 22, height: bounds.height))
        }
    }
}

// What's wrong, under the header.
class Banner: Flipped, Sized {
    let message: String
    let font = NSFont.systemFont(ofSize: 11)

    init(_ message: String) {
        self.message = message
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        let r = (message as NSString).boundingRect(with: NSSize(width: width - 40, height: 1000),
                                                   options: .usesLineFragmentOrigin, attributes: [.font: font])
        return ceil(r.height) + 16
    }

    override func draw(_ dirtyRect: NSRect) {
        fillRounded(bounds, 8, NSColor.systemRed.withAlphaComponent(0.14))
        drawSymbol(symbol("error", 11), .systemRed, in: NSRect(x: 8, y: 8, width: 20, height: 14))
        (message as NSString).draw(with: NSRect(x: 32, y: 8, width: bounds.width - 40, height: bounds.height - 16),
                                   options: .usesLineFragmentOrigin,
                                   attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}

// A bar that moves while a command runs.
class Progress: Flipped, Sized {
    let bar = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .small
        addSubview(bar)
        bar.startAnimation(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat { 12 }
    override func place() { bar.frame = bounds }
}

// The heading of a section.
class Heading: Flipped, Sized {
    var label = ""
    func height(for width: CGFloat) -> CGFloat { 26 }

    override func draw(_ dirtyRect: NSRect) {
        drawText(label, .systemFont(ofSize: 11, weight: .semibold), .secondaryLabelColor,
                 in: NSRect(x: 8, y: 9, width: bounds.width - 16, height: 15))
    }
}

// A line between sections without a heading.
class Divider: Flipped, Sized {
    func height(for width: CGFloat) -> CGFloat { 11 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 8, y: 5, width: bounds.width - 16, height: 1).fill()
    }
}

// A small button with only a picture, such as a site's Open or Quit.
class IconButton: Control {
    var icon = ""
    var badge: NSColor?   // a dot in the corner

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSymbol(symbol(icon, 13), hovered ? .labelColor : .secondaryLabelColor, in: bounds)
        if let badge {
            badge.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: 3, width: 7, height: 7)).fill()
        }
    }
}

// A row for an item: a picture in a circle, or a site's initials, its label
// and detail, and for a submenu, a chevron.
class Row: Control, Sized {
    var title = ""
    var detail = ""
    var strong = false
    var avatar: String?
    var avatarColor = NSColor.systemBlue
    var icon: String?
    var chevron: String?   // "right", which turns down when expanded, or "updown"
    var expanded = false { didSet { needsDisplay = true } }
    weak var card: NSView?
    var buttons: [IconButton] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            buttons.forEach(addSubview)
        }
    }

    func height(for width: CGFloat) -> CGFloat { detail.isEmpty ? 36 : 46 }

    var trailing: CGFloat { chevron == nil ? bounds.width - 8 : bounds.width - 30 }

    override func place() {
        var x = trailing
        for b in buttons.reversed() {
            x -= 26
            b.frame = NSRect(x: x, y: ((bounds.height - 26) / 2).rounded(), width: 26, height: 26)
            x -= 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = NSRect(x: 8, y: ((bounds.height - 28) / 2).rounded(), width: 28, height: 28)
        if let avatar {
            avatarColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            drawText(avatar, .systemFont(ofSize: 11, weight: .semibold), .white, in: circle, align: .center)
        } else if let icon {
            tint(0.08).setFill()
            NSBezierPath(ovalIn: circle).fill()
            drawSymbol(symbol(icon, 12), .labelColor, in: circle)
        }
        let x = circle.maxX + 10
        let w = trailing - CGFloat(buttons.count) * 28 - x - 4
        let font = NSFont.systemFont(ofSize: 13, weight: strong ? .semibold : .regular)
        if detail.isEmpty {
            drawText(title, font, .labelColor, in: NSRect(x: x, y: 0, width: w, height: bounds.height))
        } else {
            drawText(title, font, .labelColor, in: NSRect(x: x, y: bounds.midY - 16, width: w, height: 16))
            drawText(detail, .systemFont(ofSize: 11), .secondaryLabelColor,
                     in: NSRect(x: x, y: bounds.midY, width: w, height: 15))
        }
        if let chevron {
            drawSymbol(symbol(chevron == "right" && expanded ? "down" : chevron, 10, .semibold), .tertiaryLabelColor,
                       in: NSRect(x: bounds.width - 28, y: 0, width: 20, height: bounds.height))
        }
    }
}

// A button with a picture and a label, such as Stop or a site's Remove.
class Chip: Control {
    var title = ""
    var icon: String?
    var primary = false     // the one to press, in the accent colour
    var checked = false
    var danger = false      // one to think twice about, in red
    var strong = false

    var font: NSFont { .systemFont(ofSize: 12, weight: strong ? .semibold : .regular) }

    var preferredWidth: CGFloat { textWidth(title, font) + (icon == nil ? 0 : 20) + 24 }

    var filled: Bool { primary || checked }

    override func background() -> NSColor? {
        if filled {
            let accent = NSColor.controlAccentColor
            return pressed ? accent.withSystemEffect(.pressed) : hovered ? accent.withSystemEffect(.rollover) : accent
        }
        if danger { return NSColor.systemRed.withAlphaComponent(pressed ? 0.26 : hovered ? 0.19 : 0.12) }
        return tint(pressed ? 0.18 : hovered ? 0.13 : 0.08)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text: NSColor = filled ? .white : danger ? .systemRed : .labelColor
        let iconWidth: CGFloat = icon == nil ? 0 : 20
        let tw = min(textWidth(title, font), bounds.width - 20 - iconWidth)
        var x = ((bounds.width - iconWidth - tw) / 2).rounded()
        if let icon {
            drawSymbol(symbol(icon, 12), text, in: NSRect(x: x, y: 0, width: 14, height: bounds.height))
            x += iconWidth
        }
        drawText(title, font, text, in: NSRect(x: x, y: 0, width: tw + 1, height: bounds.height))
    }
}

// Chips side by side, sharing the width, such as Stop and Restart.
class Bar: Flipped, Sized {
    var chips: [Chip] { subviews.compactMap { $0 as? Chip } }

    func height(for width: CGFloat) -> CGFloat { 30 }

    override func place() {
        let chips = self.chips, gap: CGFloat = 6
        guard !chips.isEmpty else { return }
        let w = (bounds.width - gap * CGFloat(chips.count - 1)) / CGFloat(chips.count)
        for (i, chip) in chips.enumerated() {
            chip.frame = NSRect(x: (CGFloat(i) * (w + gap)).rounded(), y: 0, width: w.rounded(), height: bounds.height)
        }
    }
}

// A small link to an action: its picture, and its label in the accent
// colour, underlined under the mouse.
class Link: Control {
    var title = ""
    var icon: String?

    override func background() -> NSColor? { nil }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        if let icon {
            drawSymbol(symbol(icon, 11), .secondaryLabelColor, in: NSRect(x: 0, y: 0, width: 16, height: bounds.height))
            x = 22
        }
        let font = NSFont.systemFont(ofSize: 12)
        let w = min(textWidth(title, font) + 1, bounds.width - x)
        drawText(title, font, .linkColor, in: NSRect(x: x, y: 0, width: w, height: bounds.height))
        if hovered || pressed {
            NSColor.linkColor.setFill()
            let line = ceil(NSAttributedString(string: title, attributes: [.font: font]).size().height)
            let baseline = bounds.midY - line / 2 + font.ascender
            NSRect(x: x, y: (baseline + 1.5).rounded(), width: w - 1, height: 1).fill()
        }
    }
}

// Links two to a line, each group of them starting a new line.
class Grid: Flipped, Sized {
    private var groupStarts: Set<ObjectIdentifier> = []

    func add(_ link: Link, startsGroup: Bool) {
        addSubview(link)
        if startsGroup { groupStarts.insert(ObjectIdentifier(link)) }
    }

    @discardableResult func arrange(_ width: CGFloat) -> CGFloat {
        let height: CGFloat = 24, gap: CGFloat = 8
        let column = ((width - gap) / 2).rounded(.down)
        var col = 0, y: CGFloat = 0
        for (i, link) in subviews.enumerated() {
            if i > 0 && groupStarts.contains(ObjectIdentifier(link)) {
                if col != 0 { y += height }
                col = 0
            }
            link.frame = NSRect(x: CGFloat(col) * (column + gap), y: y, width: column, height: height)
            col += 1
            if col == 2 {
                col = 0
                y += height
            }
        }
        return col == 0 ? y : y + height
    }

    func height(for width: CGFloat) -> CGFloat { arrange(width) }
    override func place() { arrange(bounds.width) }
}

// Chips in lines, wrapping as they need to.
class Flow: Flipped, Sized {
    @discardableResult func arrange(_ width: CGFloat) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0
        let chips = subviews.compactMap { $0 as? Chip }
        for chip in chips {
            let w = min(chip.preferredWidth, width)
            var gap: CGFloat = x > 0 ? 6 : 0
            if x > 0 && x + gap + w > width {
                x = 0
                y += 34
                gap = 0
            }
            chip.frame = NSRect(x: x + gap, y: y, width: w, height: 28)
            x += gap + w
        }
        return chips.isEmpty ? 0 : y + 28
    }

    func height(for width: CGFloat) -> CGFloat { arrange(width) }
    override func place() { arrange(bounds.width) }
}

// Options to pick one of, such as PHP versions, as a pop-up button.
class Field: Flipped, Sized {
    let caption: String
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(_ caption: String) {
        self.caption = caption
        super.init(frame: .zero)
        popup.autoenablesItems = false
        addSubview(popup)
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat { 28 }

    override func place() {
        let size = popup.fittingSize
        let w = min(max(size.width, 90), bounds.width / 2)
        popup.frame = NSRect(x: bounds.width - w, y: ((bounds.height - size.height) / 2).rounded(),
                             width: w, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawText(caption, .systemFont(ofSize: 12), .labelColor,
                 in: NSRect(x: 2, y: 0, width: popup.frame.minX - 10, height: bounds.height))
    }
}

// The bottom of the panel: when the status was checked, and the icon's own
// commands.
class Footer: Flipped {
    var note = "" { didSet { if note != oldValue { needsDisplay = true } } }
    var buttons: [IconButton] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            buttons.forEach(addSubview)
            place()
        }
    }

    override func place() {
        var x = bounds.width - 10
        for b in buttons.reversed() {
            x -= 28
            b.frame = NSRect(x: x, y: ((bounds.height - 28) / 2).rounded(), width: 28, height: 28)
            x -= 2
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let end = buttons.first?.frame.minX ?? bounds.width - 10
        drawText(note, .systemFont(ofSize: 11), .secondaryLabelColor,
                 in: NSRect(x: 16, y: 0, width: end - 24, height: bounds.height))
    }
}

// The rim around the panel, as menus have.
class Border: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        tint(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// A mask that rounds a visual effect view's corners.
func roundedMask(_ radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

// The panel itself: a window under the icon, with the header at the top, the
// items in a list that scrolls, and the footer.
class Panel: NSPanel {
    let head = Column()
    let body = Column()
    let foot = Footer()
    let scroll = NSScrollView()
    var top: CGFloat = 0
    var onHide: () -> Void = {}
    var hiddenAt = Date.distantPast
    private var hiding = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(12)
        contentView = effect

        let root = Flipped(frame: effect.bounds)
        root.autoresizingMask = [.width, .height]
        effect.addSubview(root)
        head.padding = NSEdgeInsets(top: 6, left: 6, bottom: 4, right: 6)
        body.padding = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = body
        [head, scroll, foot].forEach(root.addSubview)

        let border = Border(frame: effect.bounds)
        border.autoresizingMask = [.width, .height]
        effect.addSubview(border)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { hide() } else { super.keyDown(with: event) }  // Escape
    }

    // Clicking another app's window, or switching to it, closes it.
    override func resignKey() {
        super.resignKey()
        hide()
    }

    func clear() {
        head.clear()
        body.clear()
        foot.buttons = []
    }

    // Size it to its contents, at most three quarters of the screen high, with
    // its top where it is.
    func reflow() {
        let w = panelWidth
        let headHeight = head.arrange(w), bodyHeight = body.arrange(w), footHeight: CGFloat = 44
        let screenHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let shown = min(bodyHeight, max(80, screenHeight * 0.75 - headHeight - footHeight))
        let total = headHeight + shown + footHeight
        setFrame(NSRect(x: frame.minX, y: top - total, width: w, height: total), display: false)
        head.frame = NSRect(x: 0, y: 0, width: w, height: headHeight)
        body.frame = NSRect(x: 0, y: 0, width: w, height: bodyHeight)
        scroll.frame = NSRect(x: 0, y: headHeight, width: w, height: shown)
        foot.frame = NSRect(x: 0, y: headHeight + shown, width: w, height: footHeight)
        foot.place()
        contentView?.needsDisplay = true
        invalidateShadow()
    }

    // Show it under ITEM, the icon's frame on the screen.
    func show(below item: NSRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        top = min(item.minY, visible.maxY) - 6
        let x = max(visible.minX + 8, min(item.midX - panelWidth / 2, visible.maxX - panelWidth - 8))
        setFrameOrigin(NSPoint(x: x, y: top))
        reflow()
        body.scroll(.zero)
        orderFrontRegardless()
        makeKey()
    }

    func hide() {
        guard isVisible, !hiding else { return }
        hiding = true
        orderOut(nil)
        hiding = false
        hiddenAt = Date()
        onHide()
    }
}

// MARK: - The tray

class Tray: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var panel: Panel!
    var panelSignature: String?
    var expanded = ""              // the title of the panel's expanded row
    var clickMonitor: Any?         // for clicks outside the panel
    var checkedAt: Date?           // when novacore last said how it is
    var unseen = ""                // output you haven't looked at: done or failed
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
        // A click opens the panel, and a right click or Control-click the menu.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // On mouse up, as the button unhighlights itself when the mouse
            // comes up, which would hide that the panel is open.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panel = Panel()
        panel.onHide = { [weak self] in self?.panelDidHide() }
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
                self.checkedAt = Date()
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
        let signature = "\(busy)|\(busyLabel)|\(problem)|\(output.isEmpty)|\(unseen)|\(modelJSON)"
        if signature != menuSignature {
            menuSignature = signature
            buildMenu()
            if panel.isVisible { buildPanel() }
        }
        if panel.isVisible { panel.foot.note = footerNote }
        updateOutputWindow()
    }

    // Why novacore can't run, or what's wrong with it, if anything.
    var problemText: String {
        problem.isEmpty ? (model?["problem"] as? String ?? "") : problem
    }

    // MARK: Menu

    func buildMenu() {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Novacore \(middleDot) \(statusText)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var detail = problemText
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
            if !isShown(spec) { continue }
            let action = spec["action"] as? JSON
            let title = spec["label"] as? String ?? ""
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = isEnabled(spec)
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

    // Whether to show an item: not one for an editor that isn't installed.
    func isShown(_ spec: JSON) -> Bool {
        guard let action = spec["action"] as? JSON, action["editor"] != nil else { return true }
        return editor(for: action) != nil
    }

    // Whether an item can be used now.
    func isEnabled(_ spec: JSON) -> Bool {
        if spec["enabled"] as? Bool == false { return false }
        if busy && spec["idle"] as? Bool == true { return false }
        let action = spec["action"] as? JSON
        return !(action?["tray"] as? String == "output" && output.isEmpty)
    }

    // Opening the menu is a good time to check.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            menuOpen = true
            refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuOpen = false }
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            panel.hide()
            // Setting the menu just for this click makes the button show it.
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else if panel.isVisible {
            panel.hide()
        } else if Date().timeIntervalSince(panel.hiddenAt) > 0.4 {
            // Pressing the icon takes the focus from the panel, which closes
            // it, so this click was to close it, not to open it again.
            showPanel()
        }
        // Show that the panel is open, as a menu's icon does.
        sender.highlight(panel.isVisible)
    }

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
        // Most actions take you elsewhere, so the panel closes, but it stays
        // to show a command's progress.
        if action["run"] == nil && action["tray"] as? String != "refresh" { panel.hide() }
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
        unseen = ""
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
            if self.outputWindow == nil { self.unseen = exit == "0" ? "done" : "failed" }
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
        if menuOpen || panel.isVisible || NSApp.modalWindow != nil || !infoWindows.isEmpty || outputWindow != nil { return }
        lastUpdateCheck = Date()
        // The same files as mac_tray_hash in bin/novacore, in the same order.
        let dir = repo.appendingPathComponent("tray/macos")
        guard let source = try? Data(contentsOf: dir.appendingPathComponent("NovacoreTray.swift")),
              let icon = try? Data(contentsOf: dir.appendingPathComponent("novacore.icns")),
              let sheet = try? Data(contentsOf: repo.appendingPathComponent("tray/status-icons.png")) else { return }
        let car = (try? Data(contentsOf: dir.appendingPathComponent("Assets.car"))) ?? Data()
        let hash = SHA256.hash(data: source + icon + sheet + car).map { String(format: "%02x", $0) }.joined()
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
        if !unseen.isEmpty {
            unseen = ""
            updateView()
        }
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

// MARK: - The panel's contents
//
// Drawn from the layout novacore gives (see "The panel" in tray/PROTOCOL.md),
// so what goes where is decided there, not here. The status goes at the top,
// with any problem under it, and the icon's own commands (Show Output,
// Refresh, Quit) along the bottom.

extension Tray {
    func showPanel() {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        if panelSignature != menuSignature { buildPanel() }
        panel.foot.note = footerNote
        panel.show(below: window.convertToScreen(button.convert(button.bounds, to: nil)), on: screen)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in self?.panel.hide()
        }
        // Opening it is a good time to check.
        refresh()
    }

    func panelDidHide() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        statusItem.button?.highlight(false)
    }

    // The line at the bottom of the panel: when we last checked.
    var footerNote: String {
        guard let checkedAt else { return "Checking\(ellipsis)" }
        return "Updated \(DateFormatter.localizedString(from: checkedAt, dateStyle: .none, timeStyle: .short))"
    }

    // A spec's picture, as tray/PROTOCOL.md names them, if it has one.
    func icon(of spec: JSON) -> String? {
        let icon = spec["icon"] as? String ?? ""
        return icon.isEmpty ? nil : icon
    }

    // ITEMS as a menu under VIEW.
    func popUpMenu(_ items: [JSON], under view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addItems(items, to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // Lay the panel out afresh from the layout novacore gives (see "The
    // panel" in tray/PROTOCOL.md). Where everything goes is decided there.
    func buildPanel() {
        panelSignature = menuSignature
        let scrolled = panel.scroll.contentView.bounds.origin
        panel.clear()

        let header = Header()
        header.status = statusText
        header.color = statusColor(iconState)
        panel.head.add(header)
        if !problemText.isEmpty { panel.head.add(Banner(problemText), top: 2, side: 6, bottom: 4) }
        if busy { panel.head.add(Progress(), top: 2, side: 10, bottom: 4) }

        let fallback: [JSON] = [
            ["label": "Refresh", "action": ["tray": "refresh"], "icon": "refresh"],
            ["label": "Quit", "action": ["tray": "quit"], "icon": "quit"],
        ]
        let layout = model?["panel"] as? JSON ?? ["footer": fallback]
        // Clicking the header does the main item, such as Open Dashboard.
        if let main = layout["header"] as? JSON, let action = main["action"] as? JSON {
            header.toolTip = (main["label"] as? String ?? "").withoutLabelEllipsis
            header.isEnabled = isEnabled(main)
            header.onClick = { [weak self] in self?.perform(action) }
        }

        let body = panel.body
        for block in layout["blocks"] as? [JSON] ?? [] {
            if let label = block["heading"] as? String {
                let heading = Heading()
                heading.label = label
                body.add(heading)
            } else if block["divider"] as? Bool == true {
                body.add(Divider())
            } else if let specs = block["buttons"] as? [JSON] {
                let bar = Bar()
                for spec in specs where isShown(spec) {
                    let button = chip(spec)
                    button.primary = spec["primary"] as? Bool == true
                    bar.addSubview(button)
                }
                body.add(bar, top: 2, side: 8, bottom: 4)
            } else if block["row"] is JSON {
                addRow(block)
            }
        }

        panel.foot.buttons = (layout["footer"] as? [JSON] ?? []).filter(isShown).map { spec in
            let button = IconButton()
            let action = spec["action"] as? JSON ?? [:]
            button.icon = icon(of: spec) ?? ""
            button.toolTip = (spec["label"] as? String ?? "").withoutLabelEllipsis
            button.isEnabled = isEnabled(spec)
            if action["tray"] as? String == "output" && !unseen.isEmpty {
                // The last command's output, not yet seen: red if it failed.
                button.badge = unseen == "failed" ? .systemRed : .controlAccentColor
                button.toolTip! += unseen == "failed" ? " (the last command failed)" : " (new)"
            }
            button.onClick = { [weak self] in self?.perform(action) }
            return button
        }
        panel.foot.note = footerNote

        if panel.isVisible {
            panel.reflow()
            panel.body.scroll(scrolled)
        }
    }

    // A button for an item, for a row of buttons or a card.
    func chip(_ spec: JSON) -> Chip {
        let chip = Chip()
        chip.title = spec["label"] as? String ?? ""
        chip.icon = icon(of: spec)
        chip.danger = spec["danger"] as? Bool == true
        chip.checked = spec["checked"] as? Bool == true
        chip.strong = spec["bold"] as? Bool == true
        chip.isEnabled = isEnabled(spec)
        if let items = spec["items"] as? [JSON] {
            chip.onClick = { [weak self, weak chip] in if let chip { self?.popUpMenu(items, under: chip) } }
        } else if let action = spec["action"] as? JSON {
            chip.onClick = { [weak self] in self?.perform(action) }
        }
        return chip
    }

    // Add a row, from a block of the panel: one that does its item, opens a
    // menu, or expands into a card, with a button for the card's main item,
    // such as a site's Open.
    func addRow(_ block: JSON) {
        let body = panel.body
        let spec = block["row"] as? JSON ?? [:]
        let row = Row()
        row.title = spec["label"] as? String ?? ""
        row.detail = spec["detail"] as? String ?? ""
        row.strong = spec["bold"] as? Bool == true
        row.isEnabled = isEnabled(spec)
        if let avatar = block["avatar"] as? String {
            row.avatar = avatar
            row.avatarColor = avatarColor(row.title)
        } else {
            row.icon = icon(of: spec)
        }
        body.add(row)

        if let items = block["menu"] as? [JSON] {
            row.chevron = "updown"
            row.onClick = { [weak self, weak row] in if let row { self?.popUpMenu(items, under: row) } }
            return
        }
        guard let content = block["card"] as? JSON else {
            if let action = spec["action"] as? JSON { row.onClick = { [weak self] in self?.perform(action) } }
            return
        }
        row.chevron = "right"
        if let main = block["button"] as? JSON, isShown(main), let action = main["action"] as? JSON {
            let button = IconButton()
            button.icon = icon(of: main) ?? ""
            button.toolTip = (main["label"] as? String ?? "").withoutLabelEllipsis
            button.isEnabled = isEnabled(main)
            button.onClick = { [weak self] in self?.perform(action) }
            row.buttons = [button]
        }
        let card = makeCard(content)
        body.add(card, top: 2, side: 8, bottom: 6)
        row.card = card
        row.expanded = expanded == row.title
        card.isHidden = !row.expanded
        row.onClick = { [weak self, weak row] in if let row { self?.toggle(row) } }
    }

    // A link for an item, for a card.
    func link(_ spec: JSON) -> Link {
        let link = Link()
        link.title = spec["label"] as? String ?? ""
        link.icon = icon(of: spec)
        link.toolTip = link.title.withoutLabelEllipsis
        link.isEnabled = isEnabled(spec)
        if let items = spec["items"] as? [JSON] {
            link.onClick = { [weak self, weak link] in if let link { self?.popUpMenu(items, under: link) } }
        } else if let action = spec["action"] as? JSON {
            link.onClick = { [weak self] in self?.perform(action) }
        }
        return link
    }

    // What an expanded row shows: its links, two to a line, each group
    // starting a new one, its options as pop-up buttons, captioned, and its
    // buttons, such as Remove, at the bottom.
    func makeCard(_ content: JSON) -> Card {
        let card = Card()
        card.padding = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)

        var grid: Grid?
        for group in content["links"] as? [[JSON]] ?? [] {
            var first = true
            for spec in group where isShown(spec) {
                let g = grid ?? Grid()
                if grid == nil {
                    grid = g
                    card.add(g)
                }
                g.add(link(spec), startsGroup: first)
                first = false
            }
        }
        for group in content["choices"] as? [JSON] ?? [] {
            let items = group["items"] as? [JSON] ?? []
            let field = Field(group["label"] as? String ?? "")
            let popup = field.popup
            for spec in items {
                let item = NSMenuItem(title: spec["label"] as? String ?? "", action: nil, keyEquivalent: "")
                let action = spec["action"] as? JSON
                item.representedObject = action
                item.isEnabled = spec["checked"] as? Bool == true || (action != nil && isEnabled(spec))
                popup.menu?.addItem(item)
                if spec["checked"] as? Bool == true { popup.select(item) }
            }
            popup.isEnabled = items.contains { $0["action"] != nil && isEnabled($0) }
            popup.target = self
            popup.action = #selector(choicePicked(_:))
            card.add(field, top: card.subviews.isEmpty ? 0 : 8)
        }
        let buttons = (content["buttons"] as? [JSON] ?? []).filter(isShown)
        if !buttons.isEmpty {
            let flow = Flow()
            buttons.forEach { flow.addSubview(chip($0)) }
            card.add(flow, top: card.subviews.isEmpty ? 0 : 10)
        }
        return card
    }

    @objc func choicePicked(_ sender: NSPopUpButton) {
        if let action = sender.selectedItem?.representedObject as? JSON { perform(action) }
    }

    // Expand ROW, closing any other, or close it.
    func toggle(_ row: Row) {
        let open = !row.expanded
        for case let other as Row in panel.body.subviews where other.expanded {
            other.expanded = false
            other.card?.isHidden = true
        }
        if open {
            row.expanded = true
            row.card?.isHidden = false
        }
        expanded = open ? row.title : ""
        panel.reflow()
        if open, let card = row.card { panel.body.scrollToVisible(row.frame.union(card.frame)) }
    }
}

let app = NSApplication.shared
let tray = Tray()
app.delegate = tray
app.setActivationPolicy(.accessory)
app.run()

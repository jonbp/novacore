import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

// Novacore's Plasma widget. In the system tray it's Novacore's tray icon on
// KDE, in place of tray/linux/novacore-tray.py, and its popup is the panel the
// macOS and Windows tray icons open. It can also sit on a panel or the desktop.
//
// Like the tray icons, it draws what the CLI describes: `novacore tray menu`
// gives every item, what it does and where it goes in the panel (see
// tray/PROTOCOL.md), so new features belong in the CLI, not here. Commands that change something run through
// `novacore tray run`, detached from plasmashell so a long build survives a
// Plasma restart, and `novacore tray poll` says how one is doing.
PlasmoidItem {
    id: root

    // metadata.json can only name a theme icon, so set Novacore's own here.
    Plasmoid.icon: Qt.resolvedUrl("../icons/novacore.svg")
    // Shown in the tray, not tucked away with the inactive icons.
    Plasmoid.status: PlasmaCore.Types.ActiveStatus

    // The system tray draws its widgets' headings and keeps their icons square.
    readonly property bool inTray: (Plasmoid.containmentDisplayHints
        & (PlasmaCore.Types.ContainmentDrawsPlasmoidHeading | PlasmaCore.Types.ContainmentForcesSquarePlasmoids)) !== 0

    property var model: null          // novacore tray menu, parsed
    property string modelJson: ""
    property string problem: ""       // why novacore tray menu failed
    property bool refreshing: false
    property bool polling: false
    property var checkedAt: null      // when the menu last came in
    property bool busy: false         // a command such as novacore up is running
    property bool watching: false     // it has started, so poll it
    property string busyLabel: ""
    property string actionUrl: ""
    property var output: []           // the last command's output, as lines
    property string unseen: ""        // output not yet looked at: done or failed
    property string actionError: ""   // why the last command failed, while the popup's open
    property var editors: ({})        // vscode and zed: the command for each, if installed

    // What the popup shows: the panel, or a page in front of it.
    property string page: "main"      // main, form, info or output
    property var pageSpec: null
    property string expandedRow: ""   // the title of the row that's open

    // Shown under the title on a horizontal panel, and in the popup's header.
    readonly property string statusText: busy ? busyLabel
        : problem ? i18n("Can't run novacore")
        : model === null ? i18n("Checking…")
        : (model.status || "")
    readonly property string problemText: problem || (model && model.problem) || ""
    readonly property string iconState: busy ? "busy"
        : problem ? "error"
        : ["running", "stopped", "busy", "error"].includes(model && model.state) ? model.state : "stopped"

    // plasmashell's PATH often lacks ~/.local/bin, where the README links the CLI.
    readonly property string env: 'PATH="$HOME/.local/bin:$PATH"; export PATH; '
    readonly property string cli: Plasmoid.configuration.command || "novacore"
    readonly property string novacore: env + cli

    // Runs in a terminal: set its title, go to the folder, then run the
    // command, keeping the window open if it fails so its error can be read.
    readonly property string terminalScript: `
printf '\\033]0;%s\\007' "$1"
cd -- "$2" || exit
shift 2
if [ $# -eq 0 ]; then exec "\${SHELL:-bash}"; fi
"$@" || { echo; read -rp "Press Enter to close. "; }
`

    // --- Running commands ------------------------------------------------

    property var pending: ({})
    property int serial: 0

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    function clean(text) {
        return text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r/g, "")
    }

    function withoutSymbols(line) {
        return line.replace(/^[^\p{L}\p{N}]+/u, "").trim()
    }

    function withoutEllipsis(label) {
        return label.endsWith("…") ? label.slice(0, -1) : label
    }

    // Run CMD in a shell, then call DONE(code, stdout, stderr). Each call gets
    // its own source, so the same command can run twice.
    function exec(cmd, done) {
        serial += 1
        const source = cmd + " #" + serial
        pending[source] = done || null
        executable.connectSource(source)
    }

    // The line that best explains a failure: the first on stderr, where
    // novacore's errors go, else the first on stdout.
    function errorLine(code, out, err) {
        for (const text of [err, out]) {
            const line = clean(text).split("\n").find(l => l.trim() !== "")
            if (line) return withoutSymbols(line)
        }
        return i18n("novacore exited with code %1", code)
    }

    function refresh() {
        if (refreshing || busy) return
        refreshing = true
        exec(novacore + " tray menu", (code, out, err) => {
            refreshing = false
            if (code !== 0) {
                problem = errorLine(code, out, err)
                return
            }
            try {
                const parsed = JSON.parse(out)
                problem = ""
                checkedAt = new Date()
                // A new model rebuilds the panel, so only on a change.
                if (out !== modelJson) {
                    modelJson = out
                    model = parsed
                }
            } catch (e) {
                problem = i18n("Couldn't read novacore's output. Is the CLI up to date?")
            }
        })
    }

    // Run a novacore command that changes something, such as up or php,
    // through `novacore tray run`, and follow it with poll().
    function startAction(args, label, done, url) {
        if (busy) return
        busy = true
        watching = false
        busyLabel = label
        actionUrl = url || ""
        actionError = ""
        output = []
        unseen = ""
        exec(novacore + " tray run " + [label, done || ""].concat(args).map(shellQuote).join(" "), (code, out, err) => {
            if (code === 0) {
                watching = true
                return
            }
            // It didn't start, e.g. as another command is still running.
            busy = false
            notify(i18n("Couldn't start: %1", withoutEllipsis(label)), errorLine(code, out, err), "", false)
        })
    }

    // Check on the running command: its output so far, or how it ended.
    function poll() {
        if (polling) return
        polling = true
        exec(novacore + " tray poll", (code, out) => {
            polling = false
            if (code !== 0) return  // Try again on the next tick.
            const lines = clean(out).split("\n")
            while (lines.length < 4) lines.push("")
            const exit = lines[0].trim(), alive = lines[1] === "alive", label = lines[2], doneText = lines[3]
            const log = lines.slice(4)
            while (log.length && log[log.length - 1].trim() === "") log.pop()

            if (exit === "" && alive) {
                // Running, perhaps started before Plasma was.
                busy = true
                watching = true
                if (label) busyLabel = label
                output = log
                return
            }
            // Finished. Only report it if we saw it running; otherwise it's an old one.
            if (!busy) return
            busy = false
            watching = false
            output = log
            const looking = root.expanded && page === "output"
            if (exit === "0") {
                if (!looking) unseen = "done"
                notify(i18n("Novacore"), doneText || i18n("Done: %1", withoutEllipsis(label)), actionUrl, false)
            } else {
                if (!looking) unseen = "failed"
                let message = log.slice().reverse().find(l => l.trim().startsWith("✖"))
                    || log.slice().reverse().find(l => l.trim() !== "")
                if (exit === "") message = i18n("novacore stopped before it finished.")
                notify(i18n("Couldn't finish: %1", withoutEllipsis(label)),
                       message ? withoutSymbols(message) : i18n("novacore exited with code %1", exit), "", true)
            }
            refresh()
        })
    }

    // A notification. Clicking one that SHOWS_OUTPUT shows the output, and
    // one with a URL opens it. While the popup's open, a failure shows in it
    // instead.
    function notify(title, body, url, showsOutput) {
        if (root.expanded) {
            if (showsOutput) actionError = title + ": " + body
            return
        }
        const icon = Qt.resolvedUrl("../icons/novacore.svg").toString().replace(/^file:\/\//, "")
        let cmd = "notify-send --app-name=Novacore " + shellQuote("--icon=" + decodeURIComponent(icon))
        if (url || showsOutput) cmd += " " + shellQuote("--action=default=" + (showsOutput ? i18n("Show Output") : i18n("Open")))
        exec(cmd + " -- " + shellQuote(title) + " " + shellQuote(body), (code, out) => {
            if (out.trim() === "default") {
                if (showsOutput) showOutput()
                else if (url) Qt.openUrlExternally(url)
            } else if (code !== 0 && showsOutput) {
                // No notifications, so don't let the failure go unseen.
                actionError = title + ": " + body
            }
        })
    }

    // --- Actions (see "Actions" in tray/PROTOCOL.md) ---------------------

    // Breeze icons for the names in tray/PROTOCOL.md, and the panel's own.
    readonly property var iconNames: ({
        dashboard: "go-home", site: "globe", open: "open-link-symbolic", git: "vcs-branch",
        info: "help-about", folder: "document-open-folder", code: "document-edit",
        terminal: "utilities-terminal", log: "view-list-text", remove: "edit-delete", add: "list-add",
        start: "media-playback-start", stop: "media-playback-stop", restart: "view-refresh",
        bug: "tools-report-bug", tools: "tools", database: "server-database", output: "dialog-scripts",
        refresh: "view-refresh", update: "system-software-update", quit: "application-exit",
    })

    function themeIcon(name) {
        return iconNames[name || ""] || ""
    }

    function isShown(spec) {
        const a = spec.action
        if (a && a.editor !== undefined && !editors[a.app || "vscode"]) return false
        // The widget lives in Plasma, so there's nothing to quit.
        if (a && a.tray === "quit") return false
        return true
    }

    function isEnabled(spec) {
        if (spec.enabled === false) return false
        if (busy && spec.idle) return false
        if (spec.action && spec.action.tray === "output" && output.length === 0) return false
        return true
    }

    function perform(action) {
        if (!action) return
        const title = action.title || "Novacore"
        if (action.open !== undefined) {
            Qt.openUrlExternally(action.open)
            root.expanded = false
        } else if (action.folder !== undefined) {
            Qt.openUrlExternally("file://" + encodeURI(action.folder))
            root.expanded = false
        } else if (action.editor !== undefined) {
            const editor = editors[action.app || "vscode"]
            if (editor) launch([editor, action.editor])
        } else if (action.terminal !== undefined) {
            openTerminal(title, action.terminal, [])
        } else if (action.console !== undefined) {
            openTerminal(title, "$HOME", [cli].concat(action.console))
        } else if (action.run !== undefined) {
            startAction(action.run, action.label || i18n("Working…"), action.done || "", action.url || "")
        } else if (action.dialog === "form" || action.dialog === "info") {
            openPage(action.dialog, action)
        } else if (action.tray === "output") {
            showOutput()
        } else if (action.tray === "refresh") {
            refresh()
        }
    }

    // Start ARGS on their own, so they outlive plasmashell.
    function launch(args) {
        exec(env + "setsid -f " + args.map(shellQuote).join(" ") + " </dev/null >/dev/null 2>&1", code => {
            if (code !== 0) notify(i18n("Couldn't open %1", args[0].split("/").pop()), args.join(" "), "", false)
        })
        root.expanded = false
    }

    // A terminal in FOLDER, running ARGS if there are any: Konsole, or the
    // one xdg-terminal-exec picks. FOLDER is $HOME for that.
    function openTerminal(title, folder, args) {
        const dir = folder === "$HOME" ? '"$HOME"' : shellQuote(folder)
        exec(env + 't=$(command -v konsole || command -v xdg-terminal-exec || command -v x-terminal-emulator) || exit 3; '
             + 'case $t in */konsole) set -- "$t" --workdir ' + dir + ' -e ;; */xdg-terminal-exec) set -- "$t" ;; *) set -- "$t" -e ;; esac; '
             + 'setsid -f "$@" bash -c ' + shellQuote(terminalScript) + ' novacore ' + shellQuote(title) + ' ' + dir + ' '
             + args.map(shellQuote).join(" ") + ' </dev/null >/dev/null 2>&1', code => {
            if (code !== 0) notify(i18n("Couldn't open a terminal"), i18n("Install one, such as Konsole."), "", false)
        })
        root.expanded = false
    }

    // Find the editors the editor actions can name, as the tray icons do:
    // on the PATH, or installed as a Flatpak.
    function findEditors() {
        exec(env + 'f() { for n; do case $n in *.*) for d in /var/lib/flatpak/exports/bin "$HOME/.local/share/flatpak/exports/bin"; do '
             + '[ -x "$d/$n" ] && { echo "$d/$n"; return; }; done ;; *) p=$(command -v "$n") && case $p in */sbin/*) ;; '
             + '*) echo "$p"; return ;; esac ;; esac; done; }; '
             + 'echo "vscode=$(f code com.visualstudio.code)"; echo "zed=$(f zeditor zed dev.zed.Zed)"', (code, out) => {
            const found = {}
            for (const line of out.split("\n")) {
                const at = line.indexOf("=")
                if (at > 0 && line.slice(at + 1)) found[line.slice(0, at)] = line.slice(at + 1)
            }
            editors = found
        })
    }

    function openPage(name, spec) {
        pageSpec = spec
        page = name
        root.expanded = true
    }

    function showOutput() {
        unseen = ""
        openPage("output", null)
    }

    function closePage() {
        page = "main"
        pageSpec = null
    }

    // The first of the menu's items with ICON that's shown, for the
    // right-click menu.
    function findItem(icon) {
        const items = (model && model.items) || []
        return items.find(i => i.icon === icon && i.action && isShown(i)) || null
    }

    Component.onCompleted: {
        findEditors()
        poll()
    }

    onExpandedChanged: () => {
        if (expanded) {
            refresh()
            if (page === "output") unseen = ""
        } else {
            // Start afresh next time, unless a command's output is up.
            if (page !== "output") closePage()
            actionError = ""
        }
    }

    toolTipMainText: "Novacore"
    toolTipSubText: problemText ? statusText + "\n" + problemText : statusText

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            readonly property var spec: root.findItem("start")
            text: spec ? spec.label : ""
            icon.name: "media-playback-start"
            visible: spec !== null
            enabled: spec !== null && root.isEnabled(spec)
            onTriggered: root.perform(spec.action)
        },
        PlasmaCore.Action {
            readonly property var spec: root.findItem("stop")
            text: spec ? spec.label : ""
            icon.name: "media-playback-stop"
            visible: spec !== null
            enabled: spec !== null && root.isEnabled(spec)
            onTriggered: root.perform(spec.action)
        },
        PlasmaCore.Action {
            readonly property var spec: root.findItem("restart")
            text: spec ? spec.label : ""
            icon.name: "view-refresh"
            visible: spec !== null
            enabled: spec !== null && root.isEnabled(spec)
            onTriggered: root.perform(spec.action)
        },
        PlasmaCore.Action {
            readonly property var spec: root.findItem("dashboard")
            text: spec ? spec.label : ""
            icon.name: "go-home"
            visible: spec !== null
            enabled: spec !== null && root.isEnabled(spec)
            onTriggered: root.perform(spec.action)
        }
    ]

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: (source, data) => {
            disconnectSource(source)
            const done = root.pending[source]
            delete root.pending[source]
            if (done) done(data["exit code"], data["stdout"] || "", data["stderr"] || "")
        }
    }

    Timer {
        interval: Math.max(5, Plasmoid.configuration.refreshInterval) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 1000
        running: root.busy && root.watching
        repeat: true
        onTriggered: root.poll()
    }

    // In the tray, the status icon the other tray icons show. On a horizontal
    // panel, the title with the status under it, too.
    compactRepresentation: MouseArea {
        id: compact

        readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal && !root.inTray
        property bool wasExpanded: false

        Layout.minimumWidth: horizontal ? row.implicitWidth
            : Plasmoid.formFactor === PlasmaCore.Types.Vertical || root.inTray ? 0 : Kirigami.Units.gridUnit * 3
        Layout.minimumHeight: Plasmoid.formFactor === PlasmaCore.Types.Vertical ? width
            : horizontal || root.inTray ? 0 : Kirigami.Units.gridUnit * 3

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onPressed: wasExpanded = root.expanded
        onClicked: mouse => {
            // A middle click opens the dashboard, as on other tray icons.
            if (mouse.button === Qt.MiddleButton) {
                const dashboard = root.findItem("dashboard")
                if (dashboard && root.isEnabled(dashboard)) root.perform(dashboard.action)
                return
            }
            root.expanded = !wasExpanded
        }

        RowLayout {
            id: row
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            StatusIcon {
                status: root.iconState
                // On a panel or the desktop there's room for it to be bigger.
                fill: root.inTray || compact.horizontal ? 16 / 22 : 0.8
                Layout.fillHeight: true
                Layout.fillWidth: !compact.horizontal
                Layout.preferredWidth: compact.horizontal ? compact.height : -1
            }

            ColumnLayout {
                visible: compact.horizontal
                spacing: 0
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.maximumWidth: Kirigami.Units.gridUnit * 12

                PlasmaComponents3.Label {
                    text: "Novacore"
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                PlasmaComponents3.Label {
                    visible: text !== ""
                    text: root.statusText
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }
    }

    fullRepresentation: FullRepresentation {
        tray: root
    }
}

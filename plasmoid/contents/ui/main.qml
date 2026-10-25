import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // metadata.json can only name a theme icon, so set Novacore's own here.
    Plasmoid.icon: Qt.resolvedUrl("../icons/novacore.svg")

    property bool loaded: false
    property bool running: false
    property bool busy: false
    property bool watching: false
    property string busyLabel: ""
    property bool showLog: false
    property bool logExpanded: false
    property var logLines: []
    property string error: ""
    property string actionError: ""
    property string dashboard: "https://localhost"
    property var sites: []
    property var phpVersions: []
    property var builtPhp: []

    // Shown under the panel icon's title and in the popup's header.
    readonly property string statusText: busy ? busyLabel
        : error ? i18n("Can't run novacore")
        : !loaded ? ""
        : running ? i18n("Running") : i18n("Stopped")
    readonly property color statusColor: busy ? Kirigami.Theme.textColor
        : error ? Kirigami.Theme.negativeTextColor
        : running ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor

    // plasmashell's PATH often lacks ~/.local/bin, where the README links the CLI.
    readonly property string novacore: 'PATH="$HOME/.local/bin:$PATH" ' + (Plasmoid.configuration.command || "novacore")
    readonly property string statusCommand: novacore + " status --json"

    // Actions run detached from plasmashell, so a long build survives a Plasma
    // restart. They write their output to $L.log, their PID to $L.pid, a label
    // to $L.label and finally their exit code to $L.exit.
    readonly property string files: 'L="${XDG_RUNTIME_DIR:-/tmp}/novacore-widget"; '
    readonly property string pollCommand: files
        + 'cat "$L.exit" 2>/dev/null || echo; '
        // Check the PID isn't empty: `kill -0 ""` signals our own process group.
        + 'p=$(cat "$L.pid" 2>/dev/null); ([ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo alive) || echo dead; '
        + 'cat "$L.label" 2>/dev/null; echo; '
        + 'tail -n 200 "$L.log" 2>/dev/null'

    function shellQuote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'"
    }

    function refresh() {
        executable.exec(statusCommand)
    }

    // Run a novacore command that changes something, showing its output as it goes.
    function run(args, label) {
        busy = true
        watching = false
        busyLabel = label
        actionError = ""
        logLines = []
        showLog = true
        const job = 'echo $$ > "$1.pid"; ' + novacore + " " + args + ' > "$1.log" 2>&1; echo $? > "$1.exit"'
        executable.exec(files + 'rm -f "$L.exit"; printf %s ' + shellQuote(label) + ' > "$L.label"; '
            + "setsid sh -c " + shellQuote(job) + ' sh "$L" < /dev/null > /dev/null 2>&1 &')
    }

    function setRunning(up) {
        run(up ? "up" : "down", up ? i18n("Starting Novacore…") : i18n("Stopping Novacore…"))
    }

    function setPhp(site, version) {
        run("php " + site + " " + version, builtPhp.includes(version)
            ? i18n("Switching %1 to PHP %2…", site, version)
            : i18n("Building PHP %1…", version))
    }

    function onPoll(out) {
        const lines = out.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").split("\n")
        const exit = lines[0].trim()
        const alive = lines[1] === "alive"
        const label = lines[2]
        const log = lines.slice(3)
        while (log.length && log[log.length - 1].trim() === "") log.pop()

        if (exit === "" && alive) {
            // Running, perhaps started before Plasma restarted.
            busy = true
            watching = true
            busyLabel = label
            showLog = true
            logLines = log
            return
        }
        if (!busy || !watching) return

        busy = false
        watching = false
        logLines = log
        if (exit === "0") {
            showLog = false
        } else {
            logExpanded = true
            actionError = exit === "" ? i18n("novacore stopped before it finished.")
                : (log.length ? log[log.length - 1] : i18n("novacore exited with code %1", exit))
        }
        refresh()
    }

    Component.onCompleted: executable.exec(pollCommand)

    toolTipMainText: "Novacore"
    toolTipSubText: {
        if (busy) return busyLabel
        if (error) return i18n("Can't run novacore")
        if (!loaded) return ""
        if (!running) return i18n("Stopped")
        return i18np("Running, %1 site", "Running, %1 sites", sites.length)
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: root.running ? i18n("Stop Novacore") : i18n("Start Novacore")
            icon.name: root.running ? "media-playback-stop" : "media-playback-start"
            enabled: root.loaded && !root.busy
            onTriggered: root.setRunning(!root.running)
        },
        PlasmaCore.Action {
            text: i18n("Open Dashboard")
            icon.name: "internet-web-browser"
            enabled: root.running
            onTriggered: Qt.openUrlExternally(root.dashboard)
        }
    ]

    onExpandedChanged: if (root.expanded) refresh()

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        function exec(cmd) {
            connectSource(cmd)
        }

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            const out = data["stdout"] || ""
            const failed = data["exit code"] !== 0

            if (sourceName === root.pollCommand) {
                root.onPoll(out)
                return
            }
            if (sourceName !== root.statusCommand) {
                // run() has started its job; follow it from here.
                root.watching = true
                return
            }

            if (failed) {
                root.error = (data["stderr"] || out).trim() || i18n("novacore exited with code %1", data["exit code"])
                return
            }
            try {
                const status = JSON.parse(out)
                root.running = status.running
                root.dashboard = status.dashboard
                root.phpVersions = status.phpVersions || []
                root.builtPhp = status.builtPhp || []
                root.sites = status.sites
                root.error = ""
                root.loaded = true
            } catch (e) {
                root.error = i18n("Couldn't read novacore's output. Is the CLI up to date?")
            }
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
        onTriggered: executable.exec(root.pollCommand)
    }

    // Novacore's icon. A horizontal panel also shows the title with the status
    // (or the running action) under it; elsewhere there's no room for text, so
    // a spinner sits in the icon's corner while an action runs.
    compactRepresentation: MouseArea {
        id: compact

        readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
        property bool wasExpanded: false

        Layout.minimumWidth: horizontal ? row.implicitWidth
            : Plasmoid.formFactor === PlasmaCore.Types.Vertical ? 0 : Kirigami.Units.gridUnit * 3
        Layout.minimumHeight: Plasmoid.formFactor === PlasmaCore.Types.Vertical ? width
            : horizontal ? 0 : Kirigami.Units.gridUnit * 3

        hoverEnabled: true
        onPressed: wasExpanded = root.expanded
        onClicked: root.expanded = !wasExpanded

        RowLayout {
            id: row
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: Plasmoid.icon
                active: compact.containsMouse
                Layout.fillHeight: true
                Layout.fillWidth: !compact.horizontal
                Layout.preferredWidth: compact.horizontal ? compact.height : -1

                PlasmaComponents3.BusyIndicator {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    width: Math.round(parent.width * 0.6)
                    height: width
                    padding: 0
                    visible: root.busy && !compact.horizontal
                    running: visible
                }
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
                    color: root.statusColor
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 20
        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: Plasmoid.icon
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                }

                Kirigami.Heading {
                    level: 2
                    text: "Novacore"
                }

                PlasmaComponents3.Label {
                    visible: root.loaded && !root.error
                    text: root.statusText
                    color: root.statusColor
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                }

                PlasmaComponents3.BusyIndicator {
                    visible: root.busy
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "internet-web-browser"
                    enabled: root.running
                    onClicked: Qt.openUrlExternally(root.dashboard)
                    PlasmaComponents3.ToolTip { text: i18n("Open dashboard") }
                }

                PlasmaComponents3.ToolButton {
                    icon.name: root.running ? "media-playback-stop" : "media-playback-start"
                    enabled: root.loaded && !root.busy
                    onClicked: root.setRunning(!root.running)
                    PlasmaComponents3.ToolTip { text: root.running ? i18n("Stop Novacore") : i18n("Start Novacore") }
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    enabled: !root.busy
                    onClicked: root.refresh()
                    PlasmaComponents3.ToolTip { text: i18n("Refresh") }
                }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: root.actionError !== ""
                type: Kirigami.MessageType.Error
                text: root.actionError
                showCloseButton: true
                onVisibleChanged: if (!visible) root.actionError = ""
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: list
                    model: root.error ? [] : root.sites
                    clip: true
                    spacing: Kirigami.Units.smallSpacing
                    topMargin: Kirigami.Units.smallSpacing
                    bottomMargin: Kirigami.Units.smallSpacing

                    delegate: PlasmaComponents3.ItemDelegate {
                        id: row
                        required property var modelData
                        width: ListView.view.width
                        onClicked: Qt.openUrlExternally(modelData.url)

                        PlasmaComponents3.ToolTip { text: i18n("Open %1", row.modelData.url) }

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing

                            Kirigami.Icon {
                                source: "applications-internet"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                            }

                            ColumnLayout {
                                spacing: 0
                                Layout.fillWidth: true

                                PlasmaComponents3.Label {
                                    text: row.modelData.name
                                    font.weight: Font.Bold
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                PlasmaComponents3.Label {
                                    text: row.modelData.url.replace("https://", "")
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }

                            PlasmaComponents3.ComboBox {
                                model: root.phpVersions
                                currentIndex: root.phpVersions.indexOf(row.modelData.php)
                                displayText: "PHP " + currentText
                                enabled: !root.busy && root.phpVersions.length > 0
                                onActivated: index => {
                                    const version = root.phpVersions[index]
                                    if (version !== row.modelData.php) root.setPhp(row.modelData.name, version)
                                }
                                PlasmaComponents3.ToolTip { text: i18n("PHP version") }
                            }

                            PlasmaComponents3.ToolButton {
                                icon.name: "folder-open"
                                onClicked: Qt.openUrlExternally("file://" + row.modelData.path)
                                PlasmaComponents3.ToolTip { text: i18n("Open site folder") }
                            }
                        }
                    }

                    PlasmaExtras.PlaceholderMessage {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.gridUnit * 4
                        visible: list.count === 0 && (root.loaded || root.error)
                        iconName: root.error ? "dialog-error" : Plasmoid.icon
                        text: root.error ? i18n("Can't run novacore") : i18n("No sites yet")
                        explanation: root.error
                            ? root.error + "\n\n" + i18n("Check the command in the widget's settings.")
                            : i18n("Add one with: novacore site add <name>")
                    }
                }
            }

            // Live output of the running action, like a small terminal. Collapsed,
            // it shows just the latest line.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.logExpanded ? Kirigami.Units.gridUnit * 10
                    : output.implicitHeight + Kirigami.Units.smallSpacing * 2
                Layout.margins: Kirigami.Units.smallSpacing
                visible: root.showLog
                color: "#1b1e20"
                radius: Kirigami.Units.cornerRadius

                ColumnLayout {
                    id: output
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true

                        ColumnLayout {
                            spacing: 0
                            Layout.fillWidth: true

                            PlasmaComponents3.Label {
                                text: root.busy ? root.busyLabel : i18n("Output")
                                color: "#fcfcfc"
                                font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Text {
                                visible: !root.logExpanded
                                text: root.logLines.length ? root.logLines[root.logLines.length - 1] : i18n("Waiting for output…")
                                color: "#a0a4a7"
                                font.family: Kirigami.Theme.fixedWidthFont.family
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            TapHandler {
                                onTapped: root.logExpanded = !root.logExpanded
                            }
                        }

                        PlasmaComponents3.ToolButton {
                            icon.name: root.logExpanded ? "arrow-down" : "arrow-up"
                            icon.color: "#fcfcfc"
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 2
                            Layout.preferredWidth: Layout.preferredHeight
                            onClicked: root.logExpanded = !root.logExpanded
                            PlasmaComponents3.ToolTip { text: root.logExpanded ? i18n("Collapse output") : i18n("Expand output") }
                        }

                        PlasmaComponents3.ToolButton {
                            visible: !root.busy
                            icon.name: "window-close"
                            icon.color: "#fcfcfc"
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 2
                            Layout.preferredWidth: Layout.preferredHeight
                            onClicked: root.showLog = false
                            PlasmaComponents3.ToolTip { text: i18n("Hide output") }
                        }
                    }

                    ListView {
                        id: log
                        visible: root.logExpanded
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: root.logLines
                        onModelChanged: Qt.callLater(positionViewAtEnd)
                        onVisibleChanged: if (visible) Qt.callLater(positionViewAtEnd)

                        delegate: Text {
                            required property string modelData
                            width: ListView.view.width
                            text: modelData
                            color: "#d0d4d7"
                            font.family: Kirigami.Theme.fixedWidthFont.family
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            wrapMode: Text.WrapAnywhere
                        }

                        PlasmaComponents3.Label {
                            anchors.centerIn: parent
                            visible: log.count === 0
                            text: i18n("Waiting for output…")
                            color: "#a0a4a7"
                            font: Kirigami.Theme.smallFont
                        }
                    }
                }
            }
        }
    }
}

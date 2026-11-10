import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

// The popup: the panel the macOS and Windows tray icons open, laid out from
// the same items as their menu (see "The menu" in tray/PROTOCOL.md). The
// status goes at the top, with any problem under it, and clicking it opens the
// dashboard. Separators with a label start sections. A submenu's row expands
// into a card of its items as links, with destructive ones, such as Remove,
// as buttons, and groups of options, such as PHP versions, as a box to pick
// from; a submenu of only options, such as Xdebug's, opens them as a menu.
// Commands to run that sit together, such as Stop and Restart, share a row of
// buttons, and the widget's own (Show Output, Refresh) go along the bottom.
// Dialogs, and the output of the last command, are pages in front of it.
PlasmaExtras.Representation {
    id: full

    property var tray

    readonly property var layout: buildLayout(tray.model, tray.editors)

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
    Layout.minimumHeight: Kirigami.Units.gridUnit * 12
    Layout.preferredHeight: Math.min(pages.item ? pages.item.implicitHeight : 0, Kirigami.Units.gridUnit * 34)
    collapseMarginsHint: true

    // A faint fill of the text colour: dark on light, light on dark.
    function tint(alpha) {
        const c = Kirigami.Theme.textColor
        return Qt.rgba(c.r, c.g, c.b, alpha)
    }

    function statusColor(state) {
        return state === "running" ? Kirigami.Theme.positiveTextColor
            : state === "busy" ? Kirigami.Theme.neutralTextColor
            : state === "error" ? Kirigami.Theme.negativeTextColor
            : Kirigami.Theme.disabledTextColor
    }

    // One or two letters for NAME's avatar: blog -> B, my-site -> MS.
    function initials(name) {
        const parts = name.split(/[-_. ]+/).filter(p => p)
        if (!parts.length) return "?"
        return (parts[0][0] + (parts.length > 1 ? parts[1][0] : "")).toUpperCase()
    }

    // A colour for NAME's avatar, the same each time, as on macOS.
    readonly property var avatarColors: ["#3daee9", "#9b59b6", "#1abc9c", "#f67400", "#27ae60",
                                         "#e93a9a", "#2c5fd5", "#da4453", "#a0785a"]
    function avatarColor(name) {
        let h = 0
        for (let i = 0; i < name.length; i++) h = (Math.imul(h, 31) + name.charCodeAt(i)) | 0
        return avatarColors[(h & 0x7FFFFFFF) % avatarColors.length]
    }

    // The panel's parts, from the menu's items: the main item, which the
    // header does, the blocks of the body (headings, dividers, rows and bars
    // of buttons), and the widget's own commands for the footer.
    function buildLayout(model, editors) {
        let items = (model && model.items) || [{label: i18n("Refresh"), action: {tray: "refresh"}}]
        let main = null
        const first = items[0]
        if (first && first.bold && !first.items && first.action && !first.action.tray) {
            main = first
            items = items.slice(1)
        }
        const blocks = [], own = []
        let bar = null
        const trim = () => {
            while (blocks.length && ["heading", "divider"].includes(blocks[blocks.length - 1].kind)) blocks.pop()
        }
        for (const spec of items) {
            if (spec.separator) {
                bar = null
                trim()
                if (spec.label) blocks.push({kind: "heading", label: spec.label})
                else if (blocks.length) blocks.push({kind: "divider"})
                continue
            }
            if (!tray.isShown(spec)) continue
            const a = spec.action, isSubmenu = !!spec.items
            if (a && a.tray && !isSubmenu) {
                own.push(spec)
            } else if (a && a.run && !isSubmenu) {
                if (!bar) {
                    bar = {kind: "bar", specs: []}
                    blocks.push(bar)
                }
                bar.specs.push(spec)
            } else {
                bar = null
                blocks.push({kind: "row", spec: spec})
            }
        }
        trim()
        return {main: main, blocks: blocks, own: own}
    }

    // Whether SPECS are options to pick one of, such as PHP versions: one is
    // checked, and none has a picture.
    function isChoices(specs) {
        const items = specs.filter(s => !s.separator)
        return items.some(s => s.checked) && !items.some(s => tray.itemIcon(s) !== "")
    }

    // What a submenu's card shows: its main item, which gets a button on the
    // row, its other items as lines of up to two links, each group its
    // separators make starting a new line, its groups of options, and its
    // destructive items as buttons.
    function cardFor(items) {
        const main = items.findIndex(s => s.bold && s.action && s.enabled !== false && tray.isShown(s))
        const groups = []
        let group = {label: "", specs: []}
        items.forEach((spec, i) => {
            if (spec.separator) {
                if (group.specs.length) groups.push(group)
                group = {label: spec.label || "", specs: []}
            } else if (tray.isShown(spec) && i !== main) {
                group.specs.push(spec)
            }
        })
        if (group.specs.length) groups.push(group)

        const lines = [], choices = [], buttons = []
        for (const g of groups) {
            if (isChoices(g.specs)) {
                choices.push(g)
                continue
            }
            let starts = true
            for (const spec of g.specs) {
                if (tray.isDestructive(spec)) {
                    buttons.push(spec)
                    continue
                }
                if (starts || !lines.length || lines[lines.length - 1].length === 2) lines.push([spec])
                else lines[lines.length - 1].push(spec)
                starts = false
            }
        }
        return {main: main >= 0 ? items[main] : null, lines: lines, choices: choices, buttons: buttons}
    }

    Keys.onEscapePressed: event => {
        if (tray.page !== "main") {
            tray.closePage()
            event.accepted = true
        } else {
            event.accepted = false
        }
    }

    Loader {
        id: pages
        anchors.fill: parent
        sourceComponent: tray.page === "form" ? formPage
            : tray.page === "info" ? infoPage
            : tray.page === "output" ? outputPage
            : mainPage
    }

    Component {
        id: formPage
        FormPage { tray: full.tray; spec: full.tray.pageSpec }
    }

    Component {
        id: infoPage
        InfoPage { tray: full.tray; spec: full.tray.pageSpec }
    }

    Component {
        id: outputPage
        OutputPage { tray: full.tray }
    }

    // A menu of a submenu's items, such as Xdebug's modes.
    PlasmaComponents3.Menu {
        id: itemsMenu

        function show(items, under) {
            while (count) removeItem(itemAt(0))
            for (const spec of items) {
                if (spec.separator) {
                    addItem(separatorComponent.createObject(itemsMenu))
                } else if (full.tray.isShown(spec)) {
                    addItem(menuItemComponent.createObject(itemsMenu, {spec: spec}))
                }
            }
            popup(under, 0, under.height)
        }
    }

    Component {
        id: separatorComponent
        PlasmaComponents3.MenuSeparator {}
    }

    Component {
        id: menuItemComponent
        PlasmaComponents3.MenuItem {
            property var spec
            text: spec.label
            checkable: !!spec.checked
            checked: !!spec.checked
            enabled: full.tray.isEnabled(spec) && (!!spec.action || !!spec.checked)
            onTriggered: if (!spec.checked) full.tray.perform(spec.action)
        }
    }

    // --- The panel --------------------------------------------------------

    Component {
        id: mainPage

        ColumnLayout {
            spacing: 0

            // Novacore's icon and status. Clicking it does the main item,
            // opening the dashboard.
            Hoverable {
                id: header
                readonly property var spec: full.layout.main
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                implicitHeight: Kirigami.Units.gridUnit * 3
                active: spec !== null && full.tray.isEnabled(spec)
                onClicked: full.tray.perform(spec.action)

                PlasmaComponents3.ToolTip.text: spec ? full.tray.withoutEllipsis(spec.label) : ""
                PlasmaComponents3.ToolTip.visible: containsMouse && spec !== null
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Kirigami.Units.smallSpacing
                    anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: Plasmoid.icon
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    }

                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true

                        PlasmaComponents3.Label {
                            text: "Novacore"
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Layout.fillWidth: true

                            Rectangle {
                                implicitWidth: Math.round(Kirigami.Units.gridUnit * 0.4)
                                implicitHeight: implicitWidth
                                radius: width / 2
                                color: full.statusColor(full.tray.iconState)
                            }

                            PlasmaComponents3.Label {
                                text: full.tray.statusText
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                    }

                    Kirigami.Icon {
                        source: "open-link-symbolic"
                        visible: header.hovered
                        opacity: 0.7
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                visible: full.tray.problemText !== ""
                type: Kirigami.MessageType.Error
                text: full.tray.problemText
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                visible: full.tray.actionError !== ""
                type: Kirigami.MessageType.Error
                text: full.tray.actionError
                showCloseButton: true
                onVisibleChanged: if (!visible) full.tray.actionError = ""
                actions: [
                    Kirigami.Action {
                        text: i18n("Show Output")
                        icon.name: "dialog-scripts"
                        onTriggered: full.tray.showOutput()
                    }
                ]
            }

            PlasmaComponents3.ProgressBar {
                visible: full.tray.busy
                indeterminate: true
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing * 2
                Layout.rightMargin: Kirigami.Units.largeSpacing * 2
                Layout.bottomMargin: Kirigami.Units.smallSpacing
            }

            PlasmaComponents3.ScrollView {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: body.implicitHeight
                contentWidth: availableWidth

                ColumnLayout {
                    id: body
                    width: scroll.availableWidth
                    spacing: 0

                    Repeater {
                        model: full.layout.blocks

                        delegate: Loader {
                            required property var modelData
                            Layout.fillWidth: true
                            onLoaded: item.block = Qt.binding(() => modelData)
                            sourceComponent: modelData.kind === "heading" ? headingBlock
                                : modelData.kind === "divider" ? dividerBlock
                                : modelData.kind === "bar" ? barBlock
                                : rowBlock
                        }
                    }

                    Item { implicitHeight: Kirigami.Units.smallSpacing }
                }
            }

            // When the menu was last checked, and the widget's own commands.
            Kirigami.Separator { Layout.fillWidth: true }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                Layout.leftMargin: Kirigami.Units.largeSpacing * 2
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: full.tray.checkedAt
                        ? i18n("Updated %1", full.tray.checkedAt.toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
                        : i18n("Checking…")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Repeater {
                    model: full.layout.own

                    delegate: PlasmaComponents3.ToolButton {
                        id: ownButton
                        required property var modelData
                        readonly property bool badged: modelData.action.tray === "output" && full.tray.unseen !== ""
                        icon.name: full.tray.themeIcon(full.tray.itemIcon(modelData))
                        enabled: full.tray.isEnabled(modelData)
                        display: PlasmaComponents3.AbstractButton.IconOnly
                        text: full.tray.withoutEllipsis(modelData.label)
                        onClicked: full.tray.perform(modelData.action)

                        PlasmaComponents3.ToolTip.text: text + (!badged ? ""
                            : full.tray.unseen === "failed" ? i18n(" (the last command failed)") : i18n(" (new)"))
                        PlasmaComponents3.ToolTip.visible: hovered
                        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay

                        // The last command's output, not yet seen: red if it failed.
                        Rectangle {
                            visible: ownButton.badged
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Kirigami.Units.smallSpacing
                            width: Math.round(Kirigami.Units.gridUnit * 0.4)
                            height: width
                            radius: width / 2
                            color: full.tray.unseen === "failed" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.highlightColor
                        }
                    }
                }
            }
        }
    }

    // The heading of a section.
    Component {
        id: headingBlock

        PlasmaComponents3.Label {
            property var block: ({})
            text: block.label || ""
            font.weight: Font.DemiBold
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.7
            elide: Text.ElideRight
            leftPadding: Kirigami.Units.largeSpacing * 2
            rightPadding: Kirigami.Units.largeSpacing * 2
            topPadding: Kirigami.Units.largeSpacing
            bottomPadding: Kirigami.Units.smallSpacing
        }
    }

    // A line between sections without a heading.
    Component {
        id: dividerBlock

        Item {
            property var block
            implicitHeight: Kirigami.Units.largeSpacing * 2
            Kirigami.Separator {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Kirigami.Units.largeSpacing * 2
                anchors.rightMargin: Kirigami.Units.largeSpacing * 2
            }
        }
    }

    // Commands side by side, sharing the width, such as Stop and Restart. One
    // that stands alone, such as Start, is the one to press.
    Component {
        id: barBlock

        Item {
            property var block: ({specs: []})
            readonly property var specs: block.specs
            implicitHeight: bar.implicitHeight + Kirigami.Units.smallSpacing * 2

            RowLayout {
                id: bar
                anchors.fill: parent
                anchors.leftMargin: Kirigami.Units.largeSpacing * 2
                anchors.rightMargin: Kirigami.Units.largeSpacing * 2
                anchors.topMargin: Kirigami.Units.smallSpacing
                anchors.bottomMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: parent.parent.specs

                    delegate: Chip {
                        required property var modelData
                        spec: modelData
                        primary: parent.parent.specs.length === 1
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                    }
                }
            }
        }
    }

    // A row for an item: a picture in a circle, or a site's initials, its
    // label and detail. A submenu's row expands into a card of its items.
    Component {
        id: rowBlock

        ColumnLayout {
            id: rowBox
            property var block: ({spec: {label: ""}})
            readonly property var spec: block.spec
            readonly property var items: spec.items || null
            readonly property bool choicesOnly: items !== null && full.isChoices(items)
            readonly property var card: items !== null && !choicesOnly ? full.cardFor(items) : null
            readonly property bool expanded: card !== null && full.tray.expandedRow === spec.label
            readonly property string icon: full.tray.itemIcon(spec)
            spacing: 0

            Hoverable {
                id: row
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                implicitHeight: Kirigami.Units.gridUnit * (rowBox.spec.detail ? 2.6 : 2.1)
                active: full.tray.isEnabled(rowBox.spec) && (rowBox.items !== null || !!rowBox.spec.action)
                opacity: full.tray.isEnabled(rowBox.spec) ? 1 : 0.5
                onClicked: {
                    if (rowBox.choicesOnly) itemsMenu.show(rowBox.items, row)
                    else if (rowBox.card) full.tray.expandedRow = rowBox.expanded ? "" : rowBox.spec.label
                    else full.tray.perform(rowBox.spec.action)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                    anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                    spacing: Kirigami.Units.largeSpacing

                    Rectangle {
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 1.55)
                        implicitHeight: implicitWidth
                        radius: width / 2
                        readonly property bool avatar: rowBox.icon === "site" && rowBox.items !== null
                        color: avatar ? full.avatarColor(rowBox.spec.label) : full.tint(0.08)
                        visible: avatar || rowBox.icon !== ""

                        PlasmaComponents3.Label {
                            anchors.centerIn: parent
                            visible: parent.avatar
                            text: full.initials(rowBox.spec.label)
                            color: "white"
                            font.weight: Font.DemiBold
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }

                        Kirigami.Icon {
                            anchors.centerIn: parent
                            visible: !parent.avatar
                            source: full.tray.themeIcon(rowBox.icon)
                            width: Kirigami.Units.iconSizes.small
                            height: width
                        }
                    }

                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true

                        PlasmaComponents3.Label {
                            text: rowBox.spec.label
                            font.weight: rowBox.spec.bold ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        PlasmaComponents3.Label {
                            visible: !!rowBox.spec.detail
                            text: rowBox.spec.detail || ""
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    // A submenu's main item, such as a site's Open.
                    PlasmaComponents3.ToolButton {
                        readonly property var main: rowBox.card ? rowBox.card.main : null
                        visible: main !== null
                        icon.name: main && main.action.open !== undefined ? "open-link-symbolic"
                            : main ? full.tray.themeIcon(full.tray.itemIcon(main)) : ""
                        display: PlasmaComponents3.AbstractButton.IconOnly
                        text: main ? full.tray.withoutEllipsis(main.label) : ""
                        onClicked: full.tray.perform(main.action)
                        PlasmaComponents3.ToolTip.text: text
                        PlasmaComponents3.ToolTip.visible: hovered
                        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }

                    Kirigami.Icon {
                        visible: rowBox.items !== null
                        source: rowBox.choicesOnly ? "arrow-down" : "arrow-right"
                        rotation: rowBox.expanded ? 90 : 0
                        opacity: 0.5
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        Behavior on rotation { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                    }
                }
            }

            Loader {
                active: rowBox.expanded
                visible: active
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing * 2
                Layout.rightMargin: Kirigami.Units.largeSpacing * 2
                Layout.topMargin: Kirigami.Units.smallSpacing / 2
                Layout.bottomMargin: Kirigami.Units.smallSpacing * 2
                sourceComponent: cardComponent
                onLoaded: item.card = Qt.binding(() => rowBox.card)
            }
        }
    }

    // An expanded row's items.
    Component {
        id: cardComponent

        Rectangle {
            property var card: null
            radius: Kirigami.Units.cornerRadius * 2
            color: full.tint(0.05)
            implicitHeight: cardColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: cardColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                // Links, two to a line.
                Repeater {
                    model: parent.parent.card ? parent.parent.card.lines : []

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        LinkItem {
                            spec: parent.modelData[0]
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            implicitHeight: 1

                            LinkItem {
                                visible: parent.parent.modelData.length > 1
                                spec: parent.parent.modelData.length > 1 ? parent.parent.modelData[1] : null
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                // Options to pick one of, such as PHP versions.
                Repeater {
                    model: parent.parent.card ? parent.parent.card.choices : []

                    delegate: RowLayout {
                        required property var modelData
                        readonly property var specs: modelData.specs
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.largeSpacing

                        PlasmaComponents3.Label {
                            text: parent.modelData.label
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        PlasmaComponents3.ComboBox {
                            model: parent.specs.map(s => s.label)
                            currentIndex: parent.specs.findIndex(s => s.checked)
                            enabled: parent.specs.some(s => s.action && full.tray.isEnabled(s))
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                            onActivated: index => {
                                const spec = parent.specs[index]
                                if (spec.action && !spec.checked && full.tray.isEnabled(spec)) {
                                    full.tray.perform(spec.action)
                                } else {
                                    currentIndex = parent.specs.findIndex(s => s.checked)
                                }
                            }
                        }
                    }
                }

                // Destructive items, such as Remove.
                Flow {
                    visible: parent.parent.card !== null && parent.parent.card.buttons.length > 0
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: parent.parent.parent.card ? parent.parent.parent.card.buttons : []
                        delegate: Chip {
                            required property var modelData
                            spec: modelData
                        }
                    }
                }
            }
        }
    }

    // --- Pieces -------------------------------------------------------------

    // Something that lights up under the mouse and does something when
    // clicked, while it's active.
    component Hoverable: MouseArea {
        property bool active: true
        property bool highlight: true
        readonly property bool hovered: containsMouse && active
        hoverEnabled: true
        enabled: active
        cursorShape: active ? Qt.PointingHandCursor : Qt.ArrowCursor

        Rectangle {
            anchors.fill: parent
            visible: parent.highlight
            radius: Kirigami.Units.cornerRadius * 1.5
            color: parent.pressed && parent.active ? full.tint(0.16) : parent.hovered ? full.tint(0.09) : "transparent"
        }
    }

    // A button with a picture and a label, such as Stop or a site's Remove.
    component Chip: Hoverable {
        id: chip
        property var spec
        property bool primary: false
        readonly property bool danger: full.tray.isDestructive(spec)
        readonly property color textColor: primary ? Kirigami.Theme.highlightedTextColor
            : danger ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
        highlight: false
        active: full.tray.isEnabled(spec)
        opacity: active ? 1 : 0.5
        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.7)
        implicitWidth: chipRow.implicitWidth + Kirigami.Units.largeSpacing * 3
        onClicked: {
            if (spec.items) itemsMenu.show(spec.items, chip)
            else full.tray.perform(spec.action)
        }

        Rectangle {
            anchors.fill: parent
            radius: Kirigami.Units.cornerRadius * 1.5
            color: chip.primary ? (chip.pressed ? Qt.darker(Kirigami.Theme.highlightColor, 1.2)
                                   : chip.hovered ? Qt.lighter(Kirigami.Theme.highlightColor, 1.1)
                                   : Kirigami.Theme.highlightColor)
                : chip.danger ? Qt.rgba(Kirigami.Theme.negativeTextColor.r, Kirigami.Theme.negativeTextColor.g,
                                        Kirigami.Theme.negativeTextColor.b, chip.pressed ? 0.26 : chip.hovered ? 0.19 : 0.12)
                : full.tint(chip.pressed ? 0.18 : chip.hovered ? 0.13 : 0.08)
        }

        RowLayout {
            id: chipRow
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - Kirigami.Units.largeSpacing * 2)
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                readonly property string name: full.tray.themeIcon(full.tray.itemIcon(chip.spec))
                visible: name !== ""
                source: name
                color: chip.textColor
                isMask: chip.primary || chip.danger
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }

            PlasmaComponents3.Label {
                text: chip.spec.label
                color: chip.textColor
                font.weight: chip.spec.bold ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }

    // A small link to an action: its picture, and its label in the link
    // colour, underlined under the mouse.
    component LinkItem: MouseArea {
        id: link
        property var spec: null
        readonly property bool active: spec !== null && full.tray.isEnabled(spec)
        hoverEnabled: true
        enabled: active
        opacity: active ? 1 : 0.5
        cursorShape: Qt.PointingHandCursor
        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.4)
        implicitWidth: linkRow.implicitWidth
        onClicked: {
            if (spec.items) itemsMenu.show(spec.items, link)
            else full.tray.perform(spec.action)
        }

        PlasmaComponents3.ToolTip.text: spec ? full.tray.withoutEllipsis(spec.label) : ""
        PlasmaComponents3.ToolTip.visible: containsMouse && linkLabel.truncated
        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay

        RowLayout {
            id: linkRow
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                readonly property string name: link.spec ? full.tray.themeIcon(full.tray.itemIcon(link.spec)) : ""
                visible: name !== ""
                source: name
                opacity: 0.7
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }

            PlasmaComponents3.Label {
                id: linkLabel
                text: link.spec ? link.spec.label : ""
                color: Kirigami.Theme.linkColor
                font.underline: link.containsMouse
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }
}

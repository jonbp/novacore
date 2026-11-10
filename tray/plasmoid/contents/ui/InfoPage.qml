import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

// Details to copy, such as a site's Info, each with a Copy button. See "Info
// dialogs" in tray/PROTOCOL.md.
SubPage {
    id: info

    property var spec: null

    title: (spec && spec.title) || "Novacore"

    function copy(text) {
        clipboard.text = text
        clipboard.selectAll()
        clipboard.copy()
        copied.text = i18n("Copied")
        copiedTimer.restart()
    }

    TextEdit {
        id: clipboard
        visible: false
    }

    Timer {
        id: copiedTimer
        interval: 1500
        onTriggered: copied.text = ""
    }

    Repeater {
        model: (info.spec && info.spec.sections) || []

        delegate: ColumnLayout {
            required property var modelData
            required property int index
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing * 2
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            spacing: 0

            PlasmaComponents3.Label {
                text: parent.modelData.heading || ""
                font.weight: Font.DemiBold
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.7
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                Layout.bottomMargin: Kirigami.Units.smallSpacing
            }

            Repeater {
                model: (parent.modelData.rows || []).filter(r => r.length === 2)

                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true

                        PlasmaComponents3.Label {
                            text: parent.parent.modelData[0]
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        PlasmaComponents3.Label {
                            text: parent.parent.modelData[1]
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAnywhere
                            Layout.fillWidth: true
                        }
                    }

                    PlasmaComponents3.ToolButton {
                        icon.name: "edit-copy"
                        display: PlasmaComponents3.AbstractButton.IconOnly
                        text: i18n("Copy %1", parent.modelData[0])
                        onClicked: info.copy(parent.modelData[1])
                        PlasmaComponents3.ToolTip.text: text
                        PlasmaComponents3.ToolTip.visible: hovered
                        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }
                }
            }
        }
    }

    Item { implicitHeight: Kirigami.Units.largeSpacing }

    footer: [
        Kirigami.Separator { Layout.fillWidth: true },
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing * 2
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                id: copied
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                Layout.fillWidth: true
            }

            Repeater {
                model: (info.spec && info.spec.buttons) || []
                delegate: PlasmaComponents3.Button {
                    required property var modelData
                    text: modelData.label || ""
                    enabled: !!modelData.action
                    onClicked: info.tray.perform(modelData.action)
                }
            }
        }
    ]
}

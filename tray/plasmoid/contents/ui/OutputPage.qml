import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

// The output of the running or last command, like a small terminal.
SubPage {
    id: page

    title: tray.busy ? tray.busyLabel : i18n("Output")

    Rectangle {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.smallSpacing
        implicitHeight: Kirigami.Units.gridUnit * 18
        color: "#1b1e20"
        radius: Kirigami.Units.cornerRadius

        ListView {
            id: log
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            clip: true
            model: page.tray.output
            onCountChanged: Qt.callLater(positionViewAtEnd)
            Component.onCompleted: Qt.callLater(positionViewAtEnd)

            PlasmaComponents3.ScrollBar.vertical: PlasmaComponents3.ScrollBar {}

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

    footer: [
        PlasmaComponents3.ProgressBar {
            visible: page.tray.busy
            indeterminate: true
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
        }
    ]
}

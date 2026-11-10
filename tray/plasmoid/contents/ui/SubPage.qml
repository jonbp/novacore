import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

// A page in front of the panel, such as a dialog: a bar with a back button
// and its title, then its contents, which scroll.
ColumnLayout {
    id: page

    property var tray
    property string title: ""
    default property alias contents: body.data
    // Under the contents, outside the scrolling part.
    property alias footer: footerSlot.data

    spacing: 0
    focus: true
    implicitHeight: bar.implicitHeight + Math.max(body.implicitHeight, Kirigami.Units.gridUnit * 6)
        + footerSlot.implicitHeight + Kirigami.Units.smallSpacing

    RowLayout {
        id: bar
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.ToolButton {
            icon.name: "go-previous"
            display: PlasmaComponents3.AbstractButton.IconOnly
            text: i18n("Back")
            onClicked: page.tray.closePage()
            PlasmaComponents3.ToolTip.text: text
            PlasmaComponents3.ToolTip.visible: hovered
            PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
        }

        Kirigami.Heading {
            level: 4
            text: page.title
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }

    Kirigami.Separator { Layout.fillWidth: true }

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
        }
    }

    ColumnLayout {
        id: footerSlot
        Layout.fillWidth: true
        spacing: 0
    }
}

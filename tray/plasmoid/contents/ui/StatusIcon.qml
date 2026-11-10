import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

// The status icon the tray icons on Linux, macOS and Windows show: the globe,
// with a pill whose colour shows the status. It comes from
// tray/status-icons.png (images/ links to it, and installing the widget copies
// it in), which tray/build-icons.sh renders at each size so it stays sharp: a
// 64px cell per theme and status, dark then light, each running, stopped,
// busy then error, with a column per size and the icon in the cell's top left.
Item {
    id: icon

    property string status: "stopped"
    // How much of the space the globe takes. Panel icons are drawn on a 22px
    // canvas with a 16px glyph, so tray icons look alike at 16/22.
    property real fill: 16 / 22

    readonly property var statuses: ["running", "stopped", "busy", "error"]
    readonly property var sizes: [16, 20, 24, 28, 32, 36, 40, 48, 64]
    // White on a dark panel, black on a light one.
    readonly property bool dark: Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.textColor) === Kirigami.ColorUtils.Light
    readonly property real side: Math.max(1, Math.floor(Math.min(width, height) * fill))
    readonly property int pixels: Math.round(side * Screen.devicePixelRatio)
    // The smallest size that's big enough, so it's only ever shrunk a little.
    readonly property int column: {
        for (let i = 0; i < sizes.length; i++) {
            if (sizes[i] >= pixels) return i
        }
        return sizes.length - 1
    }
    readonly property int row: (dark ? 0 : statuses.length) + Math.max(0, statuses.indexOf(status))

    Image {
        anchors.centerIn: parent
        width: icon.side
        height: icon.side
        source: Qt.resolvedUrl("../images/status-icons.png")
        sourceClipRect: Qt.rect(icon.column * 64, icon.row * 64, icon.sizes[icon.column], icon.sizes[icon.column])
        smooth: true
        mipmap: true
    }
}

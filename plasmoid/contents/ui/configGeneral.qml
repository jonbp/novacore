import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_command: command.text
    property alias cfg_refreshInterval: refreshInterval.value

    Kirigami.FormLayout {
        QQC2.TextField {
            id: command
            Kirigami.FormData.label: i18n("Novacore command:")
            placeholderText: "novacore"
        }
        QQC2.Label {
            text: i18n("A command on your PATH, or the full path to bin/novacore. ~/.local/bin is searched too.")
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            opacity: 0.7
        }
        QQC2.SpinBox {
            id: refreshInterval
            Kirigami.FormData.label: i18n("Refresh every (seconds):")
            from: 5
            to: 3600
        }
    }
}

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

// A dialog from the CLI that asks for something, such as Add Site, then runs
// its action with the answers. See "Form dialogs" in tray/PROTOCOL.md.
SubPage {
    id: form

    property var spec: null
    readonly property var fields: (spec && spec.fields) || []
    property bool ok: false

    title: (spec && spec.title) || "Novacore"

    // Whether every field is filled in and keeps its rules.
    function validate() {
        let valid = true
        for (let i = 0; i < fieldRepeater.count; i++) {
            const field = fieldRepeater.itemAt(i)
            if (field && !field.valid) valid = false
        }
        ok = valid
    }

    function submit() {
        validate()
        if (!ok) return
        const values = []
        for (let i = 0; i < fieldRepeater.count; i++) {
            const field = fieldRepeater.itemAt(i)
            values.push([field.fieldSpec.id || "", field.value])
        }
        const fill = text => values.reduce((t, [id, v]) => t.split("{" + id + "}").join(v), text || "")
        const action = spec.action || {}
        tray.closePage()
        if (action.run === undefined) return
        tray.startAction(action.run.concat(values.map(([id, v]) => id + "=" + v)),
                         fill(action.label || i18n("Working…")), fill(action.done), fill(action.url))
    }

    Component.onCompleted: Qt.callLater(validate)

    Keys.onReturnPressed: event => {
        // Return cancels a destructive form, such as Remove, rather than submitting it.
        if (spec && spec.destructive) tray.closePage()
        else submit()
    }
    Keys.onEnterPressed: event => {
        if (spec && spec.destructive) tray.closePage()
        else submit()
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.largeSpacing * 2
        spacing: Kirigami.Units.largeSpacing

        PlasmaComponents3.Label {
            visible: !!(form.spec && form.spec.heading)
            text: (form.spec && form.spec.heading) || ""
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        PlasmaComponents3.Label {
            visible: !!(form.spec && form.spec.message)
            text: (form.spec && form.spec.message) || ""
            wrapMode: Text.Wrap
            opacity: 0.8
            Layout.fillWidth: true
        }

        Repeater {
            id: fieldRepeater
            model: form.fields

            delegate: ColumnLayout {
                id: field
                required property var modelData
                required property int index
                readonly property var fieldSpec: modelData
                readonly property string type: modelData.type || "text"
                property string value: ""
                property bool valid: true
                property string hint: ""
                property bool hintIsError: false

                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                // Check VALUE against the field's rules, and say what's wrong
                // or show its hint.
                function check() {
                    if (type === "text") {
                        const v = value
                        let problem = ""
                        if (v !== "") {
                            for (const rule of fieldSpec.rules || []) {
                                const error = (rule.error || i18n("Not allowed")).split("{value}").join(v)
                                if (rule.match !== undefined && !new RegExp(rule.match).test(v)) problem = error
                                else if (rule.notIn !== undefined && rule.notIn.includes(v)) problem = error
                                if (problem) break
                            }
                        }
                        valid = v !== "" && problem === ""
                        hintIsError = problem !== ""
                        hint = problem || (v && fieldSpec.hint ? fieldSpec.hint.split("{value}").join(v) : "")
                    } else if (type === "choice") {
                        hint = (fieldSpec.hints || {})[value] || ""
                    } else if (type === "combo") {
                        hint = fieldSpec.note || ""
                    }
                    form.validate()
                }

                PlasmaComponents3.Label {
                    visible: field.type !== "check"
                    text: (field.fieldSpec.label || "") + ":"
                    Layout.fillWidth: true
                }

                PlasmaComponents3.TextField {
                    id: textField
                    visible: field.type === "text"
                    enabled: field.fieldSpec.enabled !== false
                    text: typeof field.fieldSpec.value === "string" ? field.fieldSpec.value : ""
                    Layout.fillWidth: true
                    onTextEdited: {
                        if (field.fieldSpec.lowercase && text !== text.toLowerCase()) {
                            const at = cursorPosition
                            text = text.toLowerCase()
                            cursorPosition = at
                        }
                    }
                    onTextChanged: if (field.type === "text") {
                        field.value = text.trim()
                        field.check()
                    }
                    Component.onCompleted: if (field.type === "text") {
                        field.value = text.trim()
                        field.check()
                        if (form.fields.findIndex(f => (f.type || "text") === "text") === field.index) forceActiveFocus()
                    }
                }

                PlasmaComponents3.ComboBox {
                    id: combo
                    visible: field.type === "choice" || field.type === "combo"
                    enabled: field.fieldSpec.enabled !== false
                    editable: field.type === "combo"
                    model: field.fieldSpec.options || []
                    Layout.fillWidth: true
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                    Component.onCompleted: {
                        if (!visible) return
                        const v = typeof field.fieldSpec.value === "string" ? field.fieldSpec.value : ""
                        const at = (field.fieldSpec.options || []).indexOf(v)
                        if (at >= 0) currentIndex = at
                        if (editable) editText = v
                        field.value = (editable ? editText : currentText).trim()
                        field.check()
                    }
                    onActivated: if (visible) {
                        field.value = currentText.trim()
                        field.check()
                    }
                    onEditTextChanged: if (visible && editable) {
                        field.value = editText.trim()
                        field.check()
                    }
                }

                PlasmaComponents3.CheckBox {
                    visible: field.type === "check"
                    enabled: field.fieldSpec.enabled !== false
                    text: field.fieldSpec.label || ""
                    checked: !!field.fieldSpec.value
                    Layout.fillWidth: true
                    onCheckedChanged: field.value = checked ? "1" : "0"
                    Component.onCompleted: field.value = checked ? "1" : "0"
                }

                PlasmaComponents3.Label {
                    visible: field.hint !== ""
                    text: field.hint
                    color: field.hintIsError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                    opacity: field.hintIsError ? 1 : 0.7
                    font: Kirigami.Theme.smallFont
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            Item { Layout.fillWidth: true }

            PlasmaComponents3.Button {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onClicked: form.tray.closePage()
            }

            PlasmaComponents3.Button {
                text: (form.spec && form.spec.submit) || i18n("OK")
                icon.name: form.spec && form.spec.destructive ? "edit-delete" : "dialog-ok"
                enabled: form.ok
                onClicked: form.submit()
            }
        }
    }
}

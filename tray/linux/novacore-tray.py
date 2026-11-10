#!/usr/bin/env python3
# Novacore's tray icon on Linux, the counterpart of the macOS menu bar icon in
# tray/macos/ and the Windows tray icon in tray/windows/.
#
# It draws what the CLI describes. `novacore tray menu` gives the menu as JSON,
# with each item's action, and the dialogs to show (see tray/PROTOCOL.md), so
# new features belong in the CLI, not here. Commands that change something run
# through `novacore tray run`, detached, and this follows them with
# `novacore tray poll`.
#
# It's Python with Qt (PySide6, or PyQt6), whose tray icon is a
# StatusNotifierItem: KDE Plasma, XFCE, Cinnamon and others show it, and GNOME
# does with the AppIndicator extension. In KDE Plasma, the Plasma widget in
# tray/plasmoid/ sits in the system tray instead, and this steps aside
# (widget_in_tray). `novacore tray install` starts it from
# an autostart entry, straight from the repo, so there's nothing to build. It
# restarts itself when this file changes, e.g. after a git pull
# (check_for_update).

import hashlib
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import time

try:
    from PySide6 import QtCore, QtGui, QtWidgets
except ImportError:
    from PyQt6 import QtCore, QtGui, QtWidgets

Qt = QtCore.Qt
QIcon, QImage, QPainter, QColor = QtGui.QIcon, QtGui.QImage, QtGui.QPainter, QtGui.QColor

APP_ID = "novacore-tray"  # also the name of its .desktop file
ELLIPSIS = "…"
MIDDLE_DOT = "·"

SCRIPT = os.path.realpath(__file__)
# The CLI: the first argument, else the one in the repo this is in, at
# <repo>/tray/linux/novacore-tray.py.
COMMAND = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(SCRIPT))), "bin", "novacore")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(COMMAND)))
APP_ICON = os.path.join(REPO, "tray", "novacore.svg")

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "novacore")
LOG_FILE = os.path.join(STATE_DIR, "tray.log")
HASH_FILE = os.path.join(STATE_DIR, "tray.hash")  # the version that ran last
PID_FILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or STATE_DIR, "novacore-tray.pid")

log = logging.getLogger("novacore-tray")


def file_hash(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def sheet_hash():
    try:
        return file_hash(STATUS_SHEET)
    except OSError:
        return ""


# --- Running novacore -------------------------------------------------------

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
LEADING_SYMBOLS = re.compile(r"^[\W_]+")


def clean(data):
    return ANSI.sub("", bytes(data).decode("utf-8", "replace")).replace("\r", "")


def without_symbols(line):
    """LINE without novacore's ✖ or ✔ and the spaces before them."""
    return LEADING_SYMBOLS.sub("", line).strip()


def without_ellipsis(label):
    return label[:-1] if label.endswith(ELLIPSIS) else label


def failure_in(lines):
    """novacore's own error message among LINES, which starts with a heavy
    cross, if it wrote one."""
    return next((line for line in reversed(lines) if line.strip().startswith("✖")), None)


class Output:
    def __init__(self, code=-1, out="", err=""):
        self.code, self.out, self.err = code, out, err

    @property
    def lines(self):
        return (self.out + self.err).split("\n")

    @property
    def error_line(self):
        """The line that best explains a failure: the first novacore wrote to
        stderr, where its error messages go, else the first it wrote at all."""
        for text in (self.err, self.out):
            line = next((l for l in text.split("\n") if l.strip()), None)
            if line:
                return without_symbols(line)
        return f"novacore exited with code {self.code}"


_processes = set()  # keeps running QProcesses from being collected


def run_novacore(args, done):
    """Run novacore with ARGS, and call DONE with its Output after."""
    process = QtCore.QProcess()
    process.setWorkingDirectory(REPO)
    process.setStandardInputFile(QtCore.QProcess.nullDevice())
    _processes.add(process)

    def finished(*_):
        _processes.discard(process)
        done(Output(process.exitCode(), clean(process.readAllStandardOutput().data()),
                    clean(process.readAllStandardError().data())))

    def failed(error):
        if error == QtCore.QProcess.ProcessError.FailedToStart:
            _processes.discard(process)
            done(Output(-1, "", f"Couldn't run {COMMAND}: {process.errorString()}"))

    process.finished.connect(finished)
    process.errorOccurred.connect(failed)
    process.start(COMMAND, args)


def fill(text, values):
    """Replace {key} in TEXT with each value."""
    for key, value in values:
        text = text.replace("{" + key + "}", value)
    return text


# --- Finding apps -----------------------------------------------------------

FLATPAK_BINS = ["/var/lib/flatpak/exports/bin", os.path.expanduser("~/.local/share/flatpak/exports/bin")]


def find_app(*names):
    """The first of NAMES on the PATH, or installed as a Flatpak (a name with
    dots, its app ID)."""
    for name in names:
        if "." in name:
            for d in FLATPAK_BINS:
                path = os.path.join(d, name)
                if os.access(path, os.X_OK):
                    return path
        else:
            path = shutil.which(name)
            # /usr/sbin/zed is the ZFS event daemon, not the editor.
            if path and "/sbin/" not in path:
                return path
    return None


# The editors an editor action's app can name.
EDITORS = {
    "vscode": ["code", "com.visualstudio.code"],
    "zed": ["zeditor", "zed", "dev.zed.Zed"],
}

# Terminals, and the arguments that come before the command to run in one.
# xdg-terminal-exec runs the one you've chosen, where there's a way to choose.
TERMINALS = {
    "xdg-terminal-exec": [],
    "konsole": ["-e"],
    "ptyxis": ["--new-window", "--"],
    "kgx": ["--"],
    "gnome-terminal": ["--"],
    "xfce4-terminal": ["-x"],
    "mate-terminal": ["-x"],
    "qterminal": ["-e"],
    "x-terminal-emulator": ["-e"],
    "ghostty": ["-e"],
    "kitty": [],
    "alacritty": ["-e"],
    "foot": [],
    "wezterm": ["start", "--"],
    "xterm": ["-e"],
}
DESKTOP_TERMINALS = {"KDE": ["konsole"], "GNOME": ["ptyxis", "kgx", "gnome-terminal"],
                     "XFCE": ["xfce4-terminal"], "MATE": ["mate-terminal"], "LXQT": ["qterminal"]}


def find_terminal():
    """The terminal to use, and the arguments to run a command in it."""
    custom = os.environ.get("TERMINAL")
    if custom and shutil.which(custom):
        return [custom] + TERMINALS.get(os.path.basename(custom), ["-e"])
    order = ["xdg-terminal-exec"]
    for desktop in os.environ.get("XDG_CURRENT_DESKTOP", "").upper().split(":"):
        order += DESKTOP_TERMINALS.get(desktop, [])
    for name in order + list(TERMINALS):
        if shutil.which(name):
            return [name] + TERMINALS[name]
    return None


# Runs in a terminal: set its title, go to the folder, then run the command,
# keeping the window open if it fails so its error can be read.
TERMINAL_SCRIPT = r'''
printf '\033]0;%s\007' "$1"
cd -- "$2" || exit
shift 2
if [ $# -eq 0 ]; then exec "${SHELL:-bash}"; fi
"$@" || { echo; read -rp "Press Enter to close. "; }
'''


# --- Icon -------------------------------------------------------------------
#
# The status icons, like the other tray icons', come from tray/status-icons.png,
# which tray/build-icons.sh renders from tray/status.svg: the globe from
# Novacore's link on jonbp.co.uk, with a pill whose colour shows the status. The
# sheet has a 64px cell for each theme and status, dark then light, each
# running, stopped, busy then error, with a column per size and the icon in each
# cell's top left corner.

STATUS_SHEET = os.path.join(REPO, "tray", "status-icons.png")
STATES = ["running", "stopped", "busy", "error"]
STATUS_SIZES = [16, 20, 24, 28, 32, 36, 40, 48, 64]

# jonbp.co.uk's palette in its dark and light themes, as in the sheet: running
# is Novacore's neon teal, stopped the secondary text colour, busy and error
# neon yellow and red.
BADGE_COLORS = {
    True: {"running": "#17D4A4", "stopped": "#768087", "busy": "#FEC82C", "error": "#FE2C62"},
    False: {"running": "#009672", "stopped": "#58626A", "busy": "#C48C00", "error": "#DE184C"},
}


def status_icons(dark):
    """Each status's icon, for a dark or light panel."""
    sheet = QImage(STATUS_SHEET)
    if sheet.isNull():
        log.error("Couldn't read %s", STATUS_SHEET)
        return {state: QIcon(APP_ICON) for state in STATES}
    icons = {}
    for i, state in enumerate(STATES):
        row = (0 if dark else len(STATES)) + i
        icon = QIcon()
        for col, n in enumerate(STATUS_SIZES):
            # Panels scale tray icons to fill their slot, usually 22px, so
            # each is centred on a canvas 22/16 its size, to look like a 16px
            # icon there.
            side = round(n * 22 / 16)
            image = QImage(side, side, QImage.Format.Format_ARGB32_Premultiplied)
            image.fill(Qt.GlobalColor.transparent)
            painter = QPainter(image)
            painter.drawImage((side - n) // 2, (side - n) // 2, sheet, col * 64, row * 64, n, n)
            painter.end()
            icon.addPixmap(QtGui.QPixmap.fromImage(image))
        icons[state] = icon
    return icons


def is_dark():
    try:
        scheme = QtGui.QGuiApplication.styleHints().colorScheme()
        if scheme != Qt.ColorScheme.Unknown:
            return scheme == Qt.ColorScheme.Dark
    except AttributeError:  # Qt before 6.5
        pass
    return QtWidgets.QApplication.palette().color(QtGui.QPalette.ColorRole.Window).lightness() < 128


def escape_mnemonic(text):
    return text.replace("&", "&&")


# --- Forms ------------------------------------------------------------------

class Form:
    """The fields of a form dialog from the CLI, checked as you type. See "Form
    dialogs" in tray/PROTOCOL.md."""

    def __init__(self, specs, layout, submit):
        self.fields = []
        self.submit = submit
        for spec in specs:
            kind = spec.get("type", "text")
            label = spec.get("label", "")
            value = spec.get("value")
            hint = None
            if kind == "choice":
                control = QtWidgets.QComboBox()
                control.addItems(spec.get("options", []))
                if isinstance(value, str):
                    control.setCurrentText(value)
                control.currentTextChanged.connect(self.update)
                hint = self.hint_label()
            elif kind == "combo":
                control = QtWidgets.QComboBox()
                control.setEditable(True)
                control.addItems(spec.get("options", []))
                control.setCurrentText(value if isinstance(value, str) else "")
                if spec.get("note"):
                    hint = self.hint_label(spec["note"])
            elif kind == "check":
                control = QtWidgets.QCheckBox(label)
                control.setChecked(bool(value))
            else:
                control = QtWidgets.QLineEdit(value if isinstance(value, str) else "")
                control.setMinimumWidth(320)
                control.textEdited.connect(self.update)
                hint = self.hint_label()
            if spec.get("enabled") is False:
                control.setEnabled(False)
            if kind == "check":
                layout.addRow("", control)
            else:
                layout.addRow(label + ":", control)
            if hint is not None:
                layout.addRow("", hint)
            self.fields.append({"spec": spec, "id": spec.get("id", ""), "type": kind, "control": control, "hint": hint})
        self.update()

    @staticmethod
    def hint_label(text=" "):
        label = QtWidgets.QLabel(text)
        font = label.font()
        font.setPointSizeF(font.pointSizeF() * 0.9)
        label.setFont(font)
        label.setWordWrap(True)
        return label

    @staticmethod
    def set_hint(label, text, error=False):
        palette = label.palette()
        role = QtGui.QPalette.ColorRole.WindowText
        if error:
            palette.setColor(role, QColor(BADGE_COLORS[is_dark()]["error"]))
        else:
            palette.setColor(role, QtWidgets.QApplication.palette().color(QtGui.QPalette.ColorRole.PlaceholderText))
        label.setPalette(palette)
        label.setText(text)

    @property
    def first_field(self):
        return next((f["control"] for f in self.fields if f["type"] == "text"), None)

    def update(self, *_):
        ok = True
        for field in self.fields:
            spec, control, hint = field["spec"], field["control"], field["hint"]
            if field["type"] == "text":
                if spec.get("lowercase") and control.text() != control.text().lower():
                    pos = control.cursorPosition()
                    control.setText(control.text().lower())
                    control.setCursorPosition(pos)
                v = control.text().strip()
                problem = None
                if not v:
                    ok = False
                else:
                    for rule in spec.get("rules", []):
                        error = rule.get("error", "Not allowed").replace("{value}", v)
                        if "match" in rule and not QtCore.QRegularExpression(rule["match"]).match(v).hasMatch():
                            problem = error
                        elif "notIn" in rule and v in rule["notIn"]:
                            problem = error
                        if problem:
                            break
                if problem:
                    ok = False
                self.set_hint(hint, problem or (spec.get("hint", " ").replace("{value}", v) if v else " "),
                              error=bool(problem))
            elif field["type"] == "choice":
                self.set_hint(hint, spec.get("hints", {}).get(control.currentText(), " "))
            elif field["type"] == "combo" and hint is not None:
                self.set_hint(hint, hint.text())
        self.submit.setEnabled(ok)

    @property
    def values(self):
        """Each field's answer, as `tray submit` takes them."""
        out = []
        for field in self.fields:
            control = field["control"]
            if field["type"] == "check":
                value = "1" if control.isChecked() else "0"
            elif isinstance(control, QtWidgets.QComboBox):
                value = control.currentText().strip()
            else:
                value = control.text().strip()
            out.append((field["id"], value))
        return out


# --- Menu on left click -----------------------------------------------------
#
# The tray icon is a StatusNotifierItem on D-Bus (Qt's own, or KDE's when
# Plasma's platform theme is loaded), and it says ItemIsMenu is false, so on a
# left click the panel asks the app to activate it. On Wayland Qt can't then
# place a menu at the cursor. With ItemIsMenu true the panel shows the menu
# itself, as it does on a right click, but QSystemTrayIcon has no way to set
# it. So this moves the item object aside and puts a forwarder at its path,
# which answers ItemIsMenu with true and passes everything else on to it (the
# icon pixmaps go through untouched, as PySide can't build them itself).

SNI_PATH = "/StatusNotifierItem"
SNI_MOVED_PATH = "/WrappedStatusNotifierItem"
SNI_IFACE = "org.kde.StatusNotifierItem"
DBUS_PROPS = "org.freedesktop.DBus.Properties"

try:
    if not QtCore.__name__.startswith("PySide6"):
        raise ImportError("PyQt6")
    from PySide6 import QtDBus

    class SNIForwarder(QtDBus.QDBusVirtualObject):
        def __init__(self, conn, item, xml):
            super().__init__()
            self.conn, self.item, self.xml = conn, item, xml
            self.props = re.findall(r'<property\b[^>]*\bname="(\w+)"', xml)

        def call(self, iface, member, args):
            message = QtDBus.QDBusMessage.createMethodCall(
                self.conn.baseService(), SNI_MOVED_PATH, iface, member)
            message.setArguments(args)
            return self.conn.call(message)  # a local call, handled at once

        def introspect(self, path):
            return self.xml

        def handleMessage(self, message, connection):
            # The panel waits for a reply, so always send one.
            try:
                reply = self.answer(message)
            except Exception:
                log.exception("Couldn't answer %s for the tray icon", message.member())
                reply = message.createErrorReply("org.freedesktop.DBus.Error.Failed", "Novacore tray error")
            connection.send(reply)
            return True

        def answer(self, message):
            iface, member, args = message.interface(), message.member(), message.arguments()
            reply = message.createReply()
            if iface == DBUS_PROPS and member == "GetAll" and args == [SNI_IFACE]:
                # The item's own reply arrives as one opaque value, so gather
                # it a property at a time. Qt's lists some it doesn't have, such
                # as WindowId, so leave out any that fail, as its GetAll does.
                props = {}
                for name in self.props:
                    answer = self.call(DBUS_PROPS, "Get", [SNI_IFACE, name]).arguments()
                    if answer:
                        value = answer[0]
                        props[name] = value.variant() if isinstance(value, QtDBus.QDBusVariant) else value
                props["ItemIsMenu"] = True
                reply.setArguments([props])
            elif iface == DBUS_PROPS and member == "Get" and args == [SNI_IFACE, "ItemIsMenu"]:
                reply.setArguments([QtDBus.QDBusVariant(True)])
            else:
                answer = self.call(iface, member, args)
                if answer.type() == QtDBus.QDBusMessage.MessageType.ErrorMessage:
                    reply = message.createErrorReply(answer.errorName(), answer.errorMessage())
                else:
                    reply.setArguments(answer.arguments())
            return reply

        def relay(self, name, *args):
            signal = QtDBus.QDBusMessage.createSignal(SNI_PATH, SNI_IFACE, name)
            signal.setArguments(list(args))
            self.conn.send(signal)

    def open_menu_on_left_click():
        """Call once the tray icon is shown. Returns the forwarder, to keep."""
        # The item's own connection, named after it.
        name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        conn = QtDBus.QDBusConnection.connectToBus(QtDBus.QDBusConnection.BusType.SessionBus, name)
        item = conn.objectRegisteredAt(SNI_PATH) if conn.isConnected() else None
        adaptor = next((c for c in (item.children() if item else [])
                        if c.metaObject().className().endswith("StatusNotifierItemAdaptor")), None)
        if not adaptor:
            return None  # not a StatusNotifierItem, e.g. an X11 XEmbed tray
        introspect = QtDBus.QDBusMessage.createMethodCall(
            conn.baseService(), SNI_PATH, "org.freedesktop.DBus.Introspectable", "Introspect")
        xml = conn.call(introspect).arguments()[0]
        match = re.search(r'<interface name="%s">.*?</interface>' % re.escape(SNI_IFACE), xml, re.S)
        if not match:
            return None
        forwarder = SNIForwarder(conn, item, match.group(0))
        conn.unregisterObject(SNI_PATH)
        conn.registerObject(SNI_MOVED_PATH, item, QtDBus.QDBusConnection.RegisterOption.ExportAdaptors)
        if not conn.registerVirtualObject(SNI_PATH, forwarder):
            conn.unregisterObject(SNI_MOVED_PATH)
            conn.registerObject(SNI_PATH, item, QtDBus.QDBusConnection.RegisterOption.ExportAdaptors)
            return None
        # The item now sends its New* signals from the moved path, where the panel
        # isn't listening, so send them on from the usual one.
        meta = adaptor.metaObject()
        for i in range(meta.methodOffset(), meta.methodCount()):
            method = meta.method(i)
            if method.methodType() == QtCore.QMetaMethod.MethodType.Signal:
                signature = bytes(method.methodSignature()).decode()
                name = bytes(method.name()).decode()
                QtCore.QObject.connect(adaptor, QtCore.SIGNAL(signature),
                                       lambda *a, n=name: forwarder.relay(n, *a))
        return forwarder
except Exception:  # PyQt6, or a Qt without D-Bus: left click stays as it was
    def open_menu_on_left_click():
        return None


# --- The tray ---------------------------------------------------------------

class Tray(QtCore.QObject):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.model = None            # novacore tray menu, parsed
        self.model_json = ""
        self.problem = ""            # why novacore tray menu failed
        self.refreshing = False
        self.polling = False         # asking how the running command is doing
        self.checked_action = False
        self.busy = False            # a command such as novacore up is running
        self.busy_label = ""
        self.action_url = ""
        self.output = []
        self.menu_signature = ""
        self.menu_open = False
        self.updating = False
        self.last_update_check = 0.0
        self.skipped_update = ""     # the hash of a version that didn't compile
        self.info_windows = {}
        self.output_window = None
        self.form_open = False
        self.notices = set()
        self.notify_send = self.find_notify_send()
        self.built_hash = file_hash(SCRIPT)
        self.sheet_hash = sheet_hash()

        self.dark = is_dark()
        self.icons = status_icons(self.dark)
        try:
            QtGui.QGuiApplication.styleHints().colorSchemeChanged.connect(self.restyle)
        except AttributeError:  # Qt before 6.5; refresh checks instead
            pass

        self.menu = QtWidgets.QMenu()
        self.menu.aboutToShow.connect(self.menu_will_open)
        self.menu.aboutToHide.connect(self.menu_did_close)
        self.submenus = []
        self.tray = QtWidgets.QSystemTrayIcon(self.icons["stopped"])
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.activated)
        self.tray.messageClicked.connect(lambda: self.notice_clicked(self.last_message))
        self.last_message = ("", False)

        self.timer(30, self.refresh)
        # Follow a running command's progress.
        self.timer(1, lambda: self.busy and self.poll_action())

        self.update_view()
        self.tray.show()
        try:
            self.sni_forwarder = open_menu_on_left_click()
        except Exception:
            log.exception("Couldn't make a left click open the menu")
            self.sni_forwarder = None
        self.announce_update()
        self.refresh()

    def timer(self, seconds, block):
        t = QtCore.QTimer(self)
        t.timeout.connect(block)
        t.start(int(seconds * 1000))
        return t

    def restyle(self, *_):
        dark = is_dark()
        if dark != self.dark:
            self.dark = dark
            self.icons = status_icons(dark)
            self.update_view()

    def announce_update(self):
        try:
            with open(HASH_FILE) as f:
                last = f.read().strip()
        except OSError:
            last = ""
        if last and last != self.built_hash:
            self.notify("Novacore", "The tray icon has been updated.")
        try:
            with open(HASH_FILE, "w") as f:
                f.write(self.built_hash)
        except OSError:
            pass

    # Status

    def refresh(self):
        if self.refreshing or self.busy:
            return
        self.refreshing = True
        self.restyle()

        def done(result):
            self.refreshing = False
            if result.code != 0:
                self.problem = result.error_line
            else:
                try:
                    self.model = json.loads(result.out)
                    self.model_json = result.out
                    self.problem = ""
                    # See if a command from before we started is still running.
                    if not self.checked_action:
                        self.checked_action = True
                        self.poll_action()
                except ValueError:
                    self.problem = "Couldn't read novacore's output. Is the CLI up to date?"
            self.update_view()
            self.check_for_update()

        run_novacore(["tray", "menu"], done)

    @property
    def status_text(self):
        if self.busy:
            return self.busy_label
        if self.problem:
            return "Can't run novacore"
        if self.model is None:
            return "Checking" + ELLIPSIS
        return self.model.get("status", "")

    @property
    def icon_state(self):
        if self.busy:
            return "busy"
        if self.problem:
            return "error"
        state = (self.model or {}).get("state")
        return state if state in STATES else "stopped"

    def update_view(self):
        """Bring the icon, tooltip and menu up to date."""
        self.tray.setIcon(self.icons[self.icon_state])
        self.tray.setToolTip(f"Novacore\n{self.status_text}")
        # Rebuilding the menu closes its open submenus, so only do it on a change.
        signature = f"{self.busy}|{self.busy_label}|{self.problem}|{not self.output}|{self.model_json}"
        if signature != self.menu_signature:
            self.menu_signature = signature
            self.build_menu()
        self.update_output_window()

    # Menu

    def build_menu(self):
        self.menu.clear()
        for sub in self.submenus:
            sub.deleteLater()
        self.submenus = []
        header = self.menu.addAction(escape_mnemonic(f"Novacore {MIDDLE_DOT} {self.status_text}"))
        header.setEnabled(False)
        detail = self.problem or (self.model or {}).get("problem", "")
        if detail:
            if len(detail) > 80:
                detail = detail[:79] + ELLIPSIS
            self.menu.addAction(escape_mnemonic(detail)).setEnabled(False)
        self.menu.addSeparator()
        items = (self.model or {}).get("items")
        if items is None:
            # novacore couldn't say, so just what this can do on its own.
            items = [{"label": "Refresh", "action": {"tray": "refresh"}}, {"separator": True},
                     {"label": "Quit", "action": {"tray": "quit"}}]
        self.editors = {app: find_app(*names) for app, names in EDITORS.items()}
        self.add_items(items, self.menu)

    def add_items(self, items, menu):
        for spec in items:
            if spec.get("separator"):
                menu.addSeparator()
                continue
            action = spec.get("action")
            if action and "editor" in action and not self.editor_for(action):
                continue
            title = escape_mnemonic(spec.get("label", ""))
            if "items" in spec:
                sub = QtWidgets.QMenu(title, menu)
                self.submenus.append(sub)
                self.add_items(spec["items"], sub)
                item = menu.addMenu(sub)
            else:
                item = menu.addAction(title)
            enabled = spec.get("enabled", True)
            if self.busy and spec.get("idle"):
                enabled = False
            if action and action.get("tray") == "output" and not self.output:
                enabled = False
            item.setEnabled(enabled)
            if spec.get("checked"):
                item.setCheckable(True)
                item.setChecked(True)
                # Clicking it mustn't uncheck it.
                item.toggled.connect(lambda _, i=item: i.setChecked(True))
            if spec.get("bold"):
                font = item.font()
                font.setBold(True)
                item.setFont(font)
            if action:
                # Queued, so the menu closes first and dialogs come up in front.
                item.triggered.connect(lambda *_, a=action: QtCore.QTimer.singleShot(0, lambda: self.perform(a)))

    def menu_will_open(self):
        # Opening the menu is a good time to check.
        self.menu_open = True
        self.refresh()

    def menu_did_close(self):
        self.menu_open = False

    def activated(self, reason):
        # A left click, where the panel doesn't show the menu itself for one
        # (see open_menu_on_left_click). On Wayland, Qt can't place a popup
        # without a parent window, so there it's on right click only.
        if (reason == QtWidgets.QSystemTrayIcon.ActivationReason.Trigger
                and QtGui.QGuiApplication.platformName() != "wayland"):
            self.menu.popup(QtGui.QCursor.pos())

    def editor_for(self, action):
        return self.editors.get(action.get("app", "vscode"))

    def perform(self, action):
        """Carry out an action from the CLI. See "Actions" in tray/PROTOCOL.md."""
        title = action.get("title", "Novacore")
        if "open" in action:
            QtGui.QDesktopServices.openUrl(QtCore.QUrl(action["open"]))
        elif "folder" in action:
            QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(action["folder"]))
        elif "editor" in action:
            editor = self.editor_for(action)
            if editor:
                self.start_detached([editor, action["editor"]])
        elif "terminal" in action:
            self.open_terminal(title, action["terminal"], [])
        elif "console" in action:
            self.open_terminal(title, REPO, [COMMAND] + action["console"])
        elif "run" in action:
            self.start_action(action["run"], action.get("label", "Working" + ELLIPSIS),
                              action.get("done", ""), action.get("url", ""))
        elif action.get("dialog") == "form":
            self.show_form(action)
        elif action.get("dialog") == "info":
            self.show_info(action)
        elif action.get("tray") == "output":
            self.show_output()
        elif action.get("tray") == "refresh":
            self.refresh()
        elif action.get("tray") == "quit":
            self.app.quit()

    def start_detached(self, args, cwd=None):
        ok = QtCore.QProcess.startDetached(args[0], args[1:], cwd or REPO)
        ok = ok[0] if isinstance(ok, tuple) else ok
        if not ok:
            self.notify(f"Couldn't open {os.path.basename(args[0])}", " ".join(args))

    def open_terminal(self, title, folder, args):
        """A terminal in FOLDER, running novacore ARGS if there are any."""
        terminal = find_terminal()
        if not terminal:
            self.notify("Couldn't open a terminal", "Install one, such as Konsole or GNOME Terminal, or set $TERMINAL.")
            return
        self.start_detached(terminal + ["bash", "-c", TERMINAL_SCRIPT, "novacore", title, folder] + args, folder)

    # Commands

    def start_action(self, args, label, done, url):
        """Run a novacore command that changes something, such as up or php. It
        runs detached (see `novacore tray run`), so it finishes even if this
        quits meanwhile, and poll_action follows it from there."""
        if self.busy:
            return
        self.busy = True
        self.busy_label = label
        self.action_url = url
        self.output = []
        self.update_view()

        def started(result):
            if result.code == 0:
                return
            # It didn't start, e.g. as another command is still running.
            self.busy = False
            self.notify(f"Couldn't start: {without_ellipsis(label)}", result.error_line)
            self.update_view()

        run_novacore(["tray", "run", label, done] + args, started)

    def poll_action(self):
        """Check on the running command: its output so far, or how it ended."""
        if self.polling:
            return
        self.polling = True

        def done(result):
            self.polling = False
            if result.code != 0:
                return  # Try again on the next tick.
            lines = result.out.split("\n")
            lines += [""] * (4 - len(lines))
            code, alive, label, done_text = lines[0].strip(), lines[1] == "alive", lines[2], lines[3]
            output = lines[4:]
            while output and not output[-1].strip():
                output.pop()

            if not code and alive:
                # Running, perhaps started before this was.
                self.busy = True
                if label:
                    self.busy_label = label
                self.output = output
                self.update_view()
                return
            # Finished. Only report it if we saw it running; otherwise it's an old one.
            if not self.busy:
                return
            self.busy = False
            self.output = output
            if code == "0":
                self.notify("Novacore", done_text or f"Done: {without_ellipsis(label)}", url=self.action_url)
            else:
                message = failure_in(output) or next((l for l in reversed(output) if l.strip()), None)
                if not code:
                    message = "novacore stopped before it finished."
                self.notify(f"Couldn't finish: {without_ellipsis(label)}",
                            without_symbols(message) if message else f"novacore exited with code {code}",
                            shows_output=True)
            self.update_view()
            self.refresh()

        run_novacore(["tray", "poll"], done)

    def check_for_update(self):
        """Restart with the repo's copy of this file when it has changed, e.g.
        after a git pull, and reload the status icons when they have."""
        if self.updating or time.monotonic() - self.last_update_check < 60:
            return
        # Restarting would close the menu or a window in use, so wait for a
        # quiet moment. A running command is fine: it runs on its own.
        if self.menu_open or self.form_open or self.info_windows or self.output_window:
            return
        self.last_update_check = time.monotonic()
        # New status icons need no restart, just reading again.
        new_sheet = sheet_hash()
        if new_sheet != self.sheet_hash:
            self.sheet_hash = new_sheet
            self.icons = status_icons(self.dark)
            self.update_view()
        try:
            with open(SCRIPT, "rb") as f:
                source = f.read()
        except OSError:
            return
        new_hash = hashlib.sha256(source).hexdigest()
        if new_hash in (self.built_hash, self.skipped_update):
            return
        try:
            compile(source, SCRIPT, "exec")
        except SyntaxError as e:
            # Don't try that version again, e.g. one saved mid-edit.
            self.skipped_update = new_hash
            self.output = [f"{SCRIPT}:{e.lineno}: {e.msg}"]
            self.notify("Couldn't update the tray icon", f"{e.msg} on line {e.lineno}", shows_output=True)
            self.update_view()
            return
        log.info("Restarting for the updated %s", SCRIPT)
        self.updating = True
        self.tray.hide()
        os.execv(sys.executable, [sys.executable, SCRIPT] + sys.argv[1:])

    # Notifications

    @staticmethod
    def find_notify_send():
        """notify-send, if it can say which notification was clicked."""
        path = shutil.which("notify-send")
        if not path:
            return None
        try:
            help_text = subprocess.run([path, "--help"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        return path if "--action" in help_text else None

    def notify(self, title, body, url="", shows_output=False):
        """A notification. Clicking one with SHOWS_OUTPUT opens the output
        window, and one with a URL opens that. If notifications don't work,
        failures open the output window straight away, so they aren't missed."""
        if not self.notify_send:
            self.last_message = (url, shows_output)
            if QtWidgets.QSystemTrayIcon.supportsMessages():
                self.tray.showMessage(title, body, QIcon(APP_ICON))
            elif shows_output:
                self.show_output()
            return
        args = ["--app-name=Novacore", f"--icon={APP_ICON}", f"--hint=string:desktop-entry:{APP_ID}"]
        if url or shows_output:
            args.append("--action=default=" + ("Show Output" if shows_output else "Open"))
        process = QtCore.QProcess(self)
        self.notices.add(process)

        def finished(code, *_):
            self.notices.discard(process)
            if code != 0:
                if shows_output:
                    self.show_output()
            elif process.readAllStandardOutput().data().decode().strip() == "default":
                self.notice_clicked((url, shows_output))

        process.finished.connect(finished)
        process.start(self.notify_send, args + ["--", title, body])

    def notice_clicked(self, notice):
        url, shows_output = notice
        if shows_output:
            self.show_output()
        elif url:
            QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))

    # Windows

    def present(self, window):
        window.show()
        window.raise_()
        window.activateWindow()

    def show_output(self):
        """The output of the last command."""
        if self.output_window is None:
            view = QtWidgets.QPlainTextEdit()
            view.setReadOnly(True)
            view.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
            view.setFont(QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont))
            view.resize(760, 440)
            view.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
            view.destroyed.connect(lambda: setattr(self, "output_window", None))
            self.output_window = view
        self.update_output_window()
        self.present(self.output_window)

    def update_output_window(self):
        view = self.output_window
        if view is None:
            return
        view.setWindowTitle(f"Novacore {MIDDLE_DOT} {self.busy_label if self.busy else 'Output'}")
        text = "\n".join(self.output) if self.output else "Waiting for output" + ELLIPSIS
        if view.toPlainText() != text:
            view.setPlainText(text)
            view.verticalScrollBar().setValue(view.verticalScrollBar().maximum())

    def show_info(self, spec):
        """A dialog of details, each with a Copy button, e.g. a site's Info."""
        title = spec.get("title", "Novacore")
        if title in self.info_windows:
            self.present(self.info_windows[title])
            return
        dialog = QtWidgets.QDialog()
        dialog.setWindowTitle(title)
        dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        grid = QtWidgets.QGridLayout()
        grid.setColumnMinimumWidth(1, 460)
        row = 0
        for section in spec.get("sections", []):
            heading = QtWidgets.QLabel(section.get("heading", ""))
            font = heading.font()
            font.setBold(True)
            heading.setFont(font)
            if row:
                grid.setRowMinimumHeight(row, 12)
                row += 1
            grid.addWidget(heading, row, 0, 1, 3)
            row += 1
            for pair in section.get("rows", []):
                if len(pair) != 2:
                    continue
                label, value = pair
                field = QtWidgets.QLineEdit(value)
                field.setReadOnly(True)
                field.setCursorPosition(0)
                copy = QtWidgets.QPushButton("Copy")
                copy.setAutoDefault(False)
                copy.clicked.connect(lambda _=False, v=value: QtWidgets.QApplication.clipboard().setText(v))
                grid.addWidget(QtWidgets.QLabel(label + ":"), row, 0, Qt.AlignmentFlag.AlignRight)
                grid.addWidget(field, row, 1)
                grid.addWidget(copy, row, 2)
                row += 1

        buttons = QtWidgets.QHBoxLayout()
        buttons.addStretch()
        for button in spec.get("buttons", []):
            b = QtWidgets.QPushButton(escape_mnemonic(button.get("label", "")))
            b.setAutoDefault(False)
            if button.get("action"):
                b.clicked.connect(lambda _=False, a=button["action"]: self.perform(a))
            buttons.addWidget(b)
        close = QtWidgets.QPushButton("Close")
        close.setDefault(True)
        close.clicked.connect(dialog.close)
        buttons.addWidget(close)

        layout = QtWidgets.QVBoxLayout(dialog)
        layout.addLayout(grid)
        layout.addSpacing(8)
        layout.addLayout(buttons)
        dialog.destroyed.connect(lambda: self.info_windows.pop(title, None))
        self.info_windows[title] = dialog
        self.present(dialog)
        close.setFocus()

    def show_form(self, spec):
        """A dialog that asks for something, then runs its action with the
        answers, e.g. Add Site."""
        dialog = QtWidgets.QDialog()
        dialog.setWindowTitle(spec.get("title", "Novacore"))
        layout = QtWidgets.QVBoxLayout(dialog)
        if spec.get("heading"):
            heading = QtWidgets.QLabel(spec["heading"])
            font = heading.font()
            font.setBold(True)
            heading.setFont(font)
            layout.addWidget(heading)
        if spec.get("message"):
            message = QtWidgets.QLabel(spec["message"])
            message.setWordWrap(True)
            layout.addWidget(message)

        box = QtWidgets.QDialogButtonBox()
        submit = box.addButton(escape_mnemonic(spec.get("submit", "OK")), QtWidgets.QDialogButtonBox.ButtonRole.AcceptRole)
        cancel = box.addButton(QtWidgets.QDialogButtonBox.StandardButton.Cancel)
        box.accepted.connect(dialog.accept)
        box.rejected.connect(dialog.reject)
        if spec.get("destructive"):
            # Enter cancels rather than, say, removing a site.
            submit.setAutoDefault(False)
            cancel.setDefault(True)
        else:
            submit.setDefault(True)

        fields = spec.get("fields", [])
        form_layout = QtWidgets.QFormLayout()
        form = Form(fields, form_layout, submit)
        if fields:
            layout.addLayout(form_layout)
        layout.addSpacing(8)
        layout.addWidget(box)
        if spec.get("destructive"):
            cancel.setFocus()
        elif form.first_field is not None:
            form.first_field.setFocus()

        self.form_open = True
        dialog.show()
        dialog.raise_()
        dialog.activateWindow()
        accepted = dialog.exec() == QtWidgets.QDialog.DialogCode.Accepted
        self.form_open = False
        values = form.values
        dialog.deleteLater()
        action = spec.get("action") or {}
        if not accepted or "run" not in action:
            return
        self.start_action(action["run"] + [f"{k}={v}" for k, v in values],
                          fill(action.get("label", "Working" + ELLIPSIS), values),
                          fill(action.get("done", ""), values),
                          fill(action.get("url", ""), values))


# --- Starting up ------------------------------------------------------------

def replace_running():
    """One at a time: the newest wins, e.g. after `novacore tray install`."""
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        if pid != os.getpid():
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                if b"novacore-tray" in f.read():
                    os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


PLASMOID_ID = "com.github.jonbp.novacore"


def widget_in_tray():
    """Whether this is KDE Plasma with Novacore's widget in its system tray,
    as `novacore tray install` puts it there, so this would be a second icon."""
    if "KDE" not in os.environ.get("XDG_CURRENT_DESKTOP", "").upper().split(":"):
        return False
    config = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                          "plasma-org.kde.plasma.desktop-appletsrc")
    try:
        with open(config, encoding="utf-8", errors="replace") as f:
            return any(line.startswith("extraItems=") and PLASMOID_ID in line.split("=", 1)[1].split(",")
                       for line in f.read().splitlines())
    except OSError:
        return False


def forget_pid():
    try:
        with open(PID_FILE) as f:
            if f.read().strip() == str(os.getpid()):
                os.remove(PID_FILE)
    except OSError:
        pass


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s %(message)s")
    sys.excepthook = lambda *exc: log.error("Unexpected error", exc_info=exc)
    if widget_in_tray():
        log.info("Novacore's Plasma widget is in the system tray, so not showing another icon")
        return
    replace_running()

    QtGui.QGuiApplication.setDesktopFileName(APP_ID)
    app = QtWidgets.QApplication(sys.argv[:1])
    app.setApplicationName("Novacore")
    app.setApplicationDisplayName("Novacore")
    app.setWindowIcon(QIcon(APP_ICON))
    app.setQuitOnLastWindowClosed(False)
    app.aboutToQuit.connect(forget_pid)
    # Python handles signals between bytecodes, and the timers in Tray give it
    # some to run.
    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    signal.signal(signal.SIGINT, lambda *_: app.quit())

    # At login, the panel can come up after this does.
    for _ in range(30):
        if QtWidgets.QSystemTrayIcon.isSystemTrayAvailable():
            break
        app.processEvents()
        time.sleep(1)
    else:
        log.warning("No system tray found; showing the icon anyway in case one appears")

    tray = Tray(app)  # noqa: F841 (kept alive while the app runs)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

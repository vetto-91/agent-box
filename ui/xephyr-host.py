#!/usr/bin/python3
"""
Wrapper PyQt5 per il monitor virtuale Xephyr (:99):
- Incorpora Xephyr tramite -parent <winId> in una QMainWindow ridimensionabile
- Intercetta la chiusura della finestra (X) chiedendo conferma ("Sì, chiudi" / "Annulla")
- Supporta il toggle schermo intero (F11 / ./agent-box.sh fullscreen) tramite /run/agent-audio/toggle-fullscreen
"""
import ctypes
import os
import signal
import subprocess
import sys

from PyQt5 import QtCore, QtGui, QtWidgets


def resize_x11_children(display_name: str, parent_win: int, width: int, height: int):
    """Ridimensiona la finestra figlia di Xephyr quando la QMainWindow cambia dimensione."""
    if width <= 0 or height <= 0:
        return
    try:
        x11 = ctypes.CDLL("libX11.so.6")
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XQueryTree.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint),
        ]
        x11.XMoveResizeWindow.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong,
            ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
        ]
        x11.XFree.argtypes = [ctypes.c_void_p]
        x11.XFlush.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]

        dpy = x11.XOpenDisplay(display_name.encode())
        if not dpy:
            return
        r_ret = ctypes.c_ulong()
        p_ret = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        nchildren = ctypes.c_uint()
        if x11.XQueryTree(
            dpy, parent_win,
            ctypes.byref(r_ret), ctypes.byref(p_ret),
            ctypes.byref(children), ctypes.byref(nchildren),
        ):
            try:
                for i in range(nchildren.value):
                    x11.XMoveResizeWindow(dpy, children[i], 0, 0, width, height)
            finally:
                if children:
                    x11.XFree(children)
        x11.XFlush(dpy)
        x11.XCloseDisplay(dpy)
    except Exception:
        pass


class XephyrHostWindow(QtWidgets.QMainWindow):
    def __init__(self, xephyr_display: str, screen_size: str, start_fullscreen: bool):
        super().__init__()
        self.xephyr_display = xephyr_display
        self.screen_size = screen_size
        self.host_display = os.environ.get("DISPLAY", ":0")
        self.xephyr_proc = None
        self.force_close = False

        self.setWindowTitle(f"Agent-Box Virtual Monitor ({xephyr_display})")
        self.setStyleSheet("background-color: #1e1e2e;")

        w, h = 1600, 900
        if "x" in screen_size:
            try:
                parts = screen_size.lower().split("x", 1)
                w, h = int(parts[0]), int(parts[1])
            except ValueError:
                pass
        self.resize(w, h)

        self.container = QtWidgets.QWidget(self)
        self.container.setAttribute(QtCore.Qt.WA_NativeWindow, True)
        self.container.setStyleSheet("background-color: #1e1e2e;")
        self.setCentralWidget(self.container)

        if start_fullscreen:
            self.showFullScreen()
        else:
            self.show()

        # Avvia Xephyr una volta che la finestra nativa X11 è pronta
        QtCore.QTimer.singleShot(250, self._start_xephyr)

        # Polling per il toggle schermo intero (F11 da openbox o ./agent-box.sh fullscreen)
        self.fs_timer = QtCore.QTimer(self)
        self.fs_timer.timeout.connect(self._check_fullscreen_toggle)
        self.fs_timer.start(250)

        # Assicura che Xephyr si ridimensioni anche subito dopo l'avvio
        self.sync_timer = QtCore.QTimer(self)
        self.sync_timer.timeout.connect(self._sync_xephyr_size)
        self.sync_timer.start(1000)

    def _start_xephyr(self):
        parent_id = int(self.container.winId())
        disp_num = self.xephyr_display.lstrip(":")
        for f in (f"/tmp/.X11-unix/X{disp_num}", f"/tmp/.X{disp_num}-lock"):
            try:
                os.remove(f)
            except OSError:
                pass

        w = max(self.container.width(), 640)
        h = max(self.container.height(), 480)
        cmd = [
            "Xephyr",
            self.xephyr_display,
            "-parent", str(parent_id),
            "-screen", f"{w}x{h}",
            "-resizeable",
            "-host-cursor",
            "-ac",
            "-nolisten", "tcp",
            "+extension", "RANDR",
            "+extension", "GLX",
            "+extension", "RENDER",
        ]
        self.xephyr_proc = subprocess.Popen(cmd)

    def _sync_xephyr_size(self):
        if self.xephyr_proc is not None and self.xephyr_proc.poll() is None:
            parent_id = int(self.container.winId())
            resize_x11_children(
                self.host_display,
                parent_id,
                self.container.width(),
                self.container.height(),
            )

    def resizeEvent(self, event: QtGui.QResizeEvent):
        super().resizeEvent(event)
        QtCore.QTimer.singleShot(50, self._sync_xephyr_size)

    def _check_fullscreen_toggle(self):
        trigger = "/run/agent-audio/toggle-fullscreen"
        if os.path.exists(trigger):
            try:
                os.remove(trigger)
            except OSError:
                pass
            if self.isFullScreen():
                self.showNormal()
            else:
                self.showFullScreen()
            QtCore.QTimer.singleShot(150, self._sync_xephyr_size)

    def closeEvent(self, event: QtGui.QCloseEvent):
        if self.force_close:
            self._stop_xephyr()
            event.accept()
            return

        msg = QtWidgets.QMessageBox(self)
        msg.setIcon(QtWidgets.QMessageBox.Warning)
        msg.setWindowTitle("Chiusura Monitor Virtuale")
        msg.setText(
            f"Sei sicuro di voler chiudere il monitor virtuale ({self.xephyr_display})?"
        )
        msg.setInformativeText(
            "Chiudendo questa finestra verranno terminati tutti i processi grafici "
            "collegati al suo interno (es. Claude Desktop, applicazioni del progetto)."
        )
        btn_close = msg.addButton("Sì, chiudi", QtWidgets.QMessageBox.DestructiveRole)
        btn_cancel = msg.addButton("Annulla", QtWidgets.QMessageBox.RejectRole)
        msg.setDefaultButton(btn_cancel)
        msg.exec_()

        if msg.clickedButton() == btn_close:
            self._stop_xephyr()
            event.accept()
        else:
            event.ignore()

    def _stop_xephyr(self):
        if self.xephyr_proc is not None and self.xephyr_proc.poll() is None:
            try:
                self.xephyr_proc.terminate()
                self.xephyr_proc.wait(timeout=3)
            except Exception:
                try:
                    self.xephyr_proc.kill()
                except Exception:
                    pass


def main():
    os.environ["QT_QPA_PLATFORM"] = "xcb"
    os.environ["QT_XCB_GL_INTEGRATION"] = "none"
    os.environ["LIBGL_ALWAYS_SOFTWARE"] = "1"

    app = QtWidgets.QApplication(sys.argv)
    xephyr_display = os.environ.get("AGENT_XEPHYR_DISPLAY", ":99")
    screen_size = os.environ.get("AGENT_SCREEN_SIZE", "1600x900")
    start_fullscreen = os.environ.get("AGENT_FULLSCREEN", "0") == "1"

    win = XephyrHostWindow(xephyr_display, screen_size, start_fullscreen)

    def handle_sigterm(_signum, _frame):
        win.force_close = True
        win.close()
        app.quit()

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()

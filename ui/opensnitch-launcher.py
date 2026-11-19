#!/usr/bin/python3
import os
import runpy
import sys
from PyQt5 import QtCore

if os.environ.get("OPENSNITCH_SHOW_MAIN_WINDOW", "1") == "1":
    from opensnitch.service import UIService

    def _show_gui_immediately(self):
        gui = self._stats_dialog

        def __show():
            gui.show()
            gui.raise_()
            gui.activateWindow()

        QtCore.QTimer.singleShot(400, __show)

    UIService._show_gui_if_tray_not_available = _show_gui_immediately

sys.argv[0] = "/usr/bin/opensnitch-ui"
runpy.run_path("/usr/bin/opensnitch-ui", run_name="__main__")

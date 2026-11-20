#!/usr/bin/python3
"""Toggle EWMH _NET_WM_STATE_FULLSCREEN on the Agent-Box Xephyr window."""
import ctypes
import os
import sys

class XClientMessageData(ctypes.Union):
    _fields_ = [
        ("b", ctypes.c_char * 20),
        ("s", ctypes.c_short * 10),
        ("l", ctypes.c_long * 5),
    ]

class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("message_type", ctypes.c_ulong),
        ("format", ctypes.c_int),
        ("data", XClientMessageData),
    ]

class XEvent(ctypes.Union):
    _fields_ = [
        ("type", ctypes.c_int),
        ("xclient", XClientMessageEvent),
        ("pad", ctypes.c_long * 24),
    ]

def main():
    x11 = ctypes.CDLL("libX11.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XQueryTree.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
    x11.XGetWindowProperty.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
        ctypes.c_long, ctypes.c_long, ctypes.c_int, ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(XEvent)]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]

    disp_name = os.environ.get("DISPLAY", ":0").encode()
    dpy = x11.XOpenDisplay(disp_name)
    if not dpy:
        return 1

    root = x11.XDefaultRootWindow(dpy)
    atom_net_wm_name = x11.XInternAtom(dpy, b"_NET_WM_NAME", 0)
    atom_utf8 = x11.XInternAtom(dpy, b"UTF8_STRING", 0)
    atom_wm_state = x11.XInternAtom(dpy, b"_NET_WM_STATE", 0)
    atom_fullscreen = x11.XInternAtom(dpy, b"_NET_WM_STATE_FULLSCREEN", 0)

    def get_title(win):
        actual_type = ctypes.c_ulong()
        actual_fmt = ctypes.c_int()
        nitems = ctypes.c_ulong()
        bytes_after = ctypes.c_ulong()
        prop = ctypes.c_void_p()
        if x11.XGetWindowProperty(
            dpy, win, atom_net_wm_name, 0, 128, 0, atom_utf8,
            ctypes.byref(actual_type), ctypes.byref(actual_fmt),
            ctypes.byref(nitems), ctypes.byref(bytes_after), ctypes.byref(prop)
        ) == 0 and prop.value and nitems.value > 0:
            val = ctypes.string_at(prop.value, nitems.value).decode("utf-8", "ignore")
            x11.XFree(prop)
            return val
        name = ctypes.c_char_p()
        if x11.XFetchName(dpy, win, ctypes.byref(name)) and name.value:
            val = name.value.decode("utf-8", "ignore")
            x11.XFree(name)
            return val
        return ""

    def find_xephyr(win, depth=0):
        if depth > 4:
            return None
        title = get_title(win)
        if "Agent-Box Virtual Monitor" in title:
            return win
        r_ret = ctypes.c_ulong()
        p_ret = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        nchildren = ctypes.c_uint()
        if x11.XQueryTree(dpy, win, ctypes.byref(r_ret), ctypes.byref(p_ret), ctypes.byref(children), ctypes.byref(nchildren)):
            try:
                for i in range(nchildren.value):
                    found = find_xephyr(children[i], depth + 1)
                    if found:
                        return found
            finally:
                if children:
                    x11.XFree(children)
        return None

    target = find_xephyr(root)
    if not target:
        x11.XCloseDisplay(dpy)
        return 1

    ev = XEvent()
    ev.xclient.type = 33  # ClientMessage
    ev.xclient.window = target
    ev.xclient.message_type = atom_wm_state
    ev.xclient.format = 32
    ev.xclient.data.l[0] = 2  # _NET_WM_STATE_TOGGLE
    ev.xclient.data.l[1] = atom_fullscreen
    ev.xclient.data.l[2] = 0
    ev.xclient.data.l[3] = 1  # source indication: normal application
    ev.xclient.data.l[4] = 0

    mask = (1 << 20) | (1 << 19)  # SubstructureRedirectMask | SubstructureNotifyMask
    x11.XSendEvent(dpy, root, 0, mask, ctypes.byref(ev))
    x11.XFlush(dpy)
    x11.XCloseDisplay(dpy)
    return 0

if __name__ == "__main__":
    sys.exit(main())

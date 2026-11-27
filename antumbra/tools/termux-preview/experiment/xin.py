#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A minimal XTEST input driver through ctypes (libX11, libXtst): a pointer
click, a pointer drag or a key press on an X display.

usage: xin.py DISPLAY click X Y | drag X1 Y1 X2 Y2 [STEPS] | key KEYSYM
"""
import ctypes, sys, time
X = ctypes.CDLL("libX11.so.6"); T = ctypes.CDLL("libXtst.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
for f in ("XFlush","XSync","XKeysymToKeycode"):
    getattr(X, f).argtypes = [ctypes.c_void_p] + ([ctypes.c_int] if f=="XSync" else []) + ([ctypes.c_ulong] if f=="XKeysymToKeycode" else [])
X.XStringToKeysym.restype = ctypes.c_ulong; X.XStringToKeysym.argtypes=[ctypes.c_char_p]
T.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
T.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
T.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
d = X.XOpenDisplay(sys.argv[1].encode()); assert d
def mv(x,y): T.XTestFakeMotionEvent(d, -1, int(x), int(y), 0); X.XFlush(d)
cmd = sys.argv[2]; a = [int(v) if v.lstrip('-').isdigit() else v for v in sys.argv[3:]]
if cmd == "click":
    mv(a[0],a[1]); time.sleep(0.2); T.XTestFakeButtonEvent(d,1,1,0); X.XFlush(d); time.sleep(0.15); T.XTestFakeButtonEvent(d,1,0,0); X.XFlush(d)
elif cmd == "drag":
    x1,y1,x2,y2 = a[:4]; steps = a[4] if len(a)>4 else 20
    mv(x1,y1); time.sleep(0.2); T.XTestFakeButtonEvent(d,1,1,0); X.XFlush(d)
    for i in range(1,steps+1):
        time.sleep(0.05); mv(x1+(x2-x1)*i/steps, y1+(y2-y1)*i/steps)
    time.sleep(0.2); T.XTestFakeButtonEvent(d,1,0,0); X.XFlush(d)
elif cmd == "key":
    kc = X.XKeysymToKeycode(d, X.XStringToKeysym(a[0].encode()))
    T.XTestFakeKeyEvent(d,kc,1,0); X.XFlush(d); time.sleep(0.1); T.XTestFakeKeyEvent(d,kc,0,0); X.XFlush(d)
X.XSync(d, 0)

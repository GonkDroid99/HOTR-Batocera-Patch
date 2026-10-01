#!/usr/bin/env python3
"""Integration test for framed and coalesced MameOutputSender streams."""
import os
import socket
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SENDER = os.path.join(ROOT, "buildroot", "recipes", "package", "batocera",
                      "emulators", "pcsx2-lightgun", "MameOutputSender")
CTRL = "/tmp/CoreFxPipe_MameHookerProxyControl"
GUN = "/tmp/CoreFxPipe_MameHookerProxyRecoilGunA"


def connect(address, family):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        sock = socket.socket(family, socket.SOCK_STREAM)
        try:
            sock.connect(address)
            sock.settimeout(2)
            return sock
        except OSError:
            sock.close()
            time.sleep(0.05)
    raise RuntimeError(f"could not connect to {address}")


proc = subprocess.Popen([sys.executable, SENDER, "gamename=TEST-FRAMING"])
try:
    hotr = connect(("127.0.0.1", 8000), socket.AF_INET)
    ctrl = connect(CTRL, socket.AF_UNIX)
    gun = connect(GUN, socket.AF_UNIX)

    ctrl.sendall(b"P1_Ammo:8\nReloadPress_")
    ctrl.sendall(b"P1:1\nP1_Ammo:7\n")
    gun.sendall(b"1\n1\n")

    received = b""
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and received.count(b"\r\n") < 6:
        received += hotr.recv(4096)

    text = received.decode("ascii", errors="replace")
    expected = [
        "mame_start = TEST-FRAMING\r\n",
        "P1_Ammo = 8\r\n",
        "ReloadPress_P1 = 1\r\n",
        "P1_Ammo = 7\r\n",
    ]
    for item in expected:
        if item not in text:
            raise AssertionError(f"missing {item!r} in {text!r}")
    if text.count("GunRecoil_P1 = 1\r\n") != 2:
        raise AssertionError(f"expected two recoil events in {text!r}")
    print("MameOutputSender framing test passed")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()

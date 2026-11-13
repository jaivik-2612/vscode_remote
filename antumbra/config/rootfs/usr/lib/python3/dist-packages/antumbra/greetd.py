# SPDX-License-Identifier: GPL-3.0-or-later
"""Minimal greetd IPC client (greetd-ipc(7)): length-prefixed JSON over the
Unix socket named by $GREETD_SOCK."""
import json
import os
import socket
import struct


class GreetdError(Exception):
    pass


class Greetd:
    def __init__(self, path=None):
        self.path = path or os.environ.get("GREETD_SOCK")
        if not self.path:
            raise GreetdError("GREETD_SOCK is not set: not running under greetd")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)

    def _send(self, msg):
        data = json.dumps(msg).encode()
        self.sock.sendall(struct.pack("=I", len(data)) + data)
        header = self._recv_exact(4)
        (length,) = struct.unpack("=I", header)
        return json.loads(self._recv_exact(length).decode())

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise GreetdError("greetd closed the connection")
            buf += chunk
        return buf

    def start_user_session(self, username, cmd, env):
        """Create a session for username (answering PAM prompts with empty
        responses: the greeter PAM stack lets the live user in without a
        password) and start cmd with env."""
        resp = self._send({"type": "create_session", "username": username})
        while resp.get("type") == "auth_message":
            resp = self._send({"type": "post_auth_message_response", "response": ""})
        if resp.get("type") != "success":
            self._send({"type": "cancel_session"})
            raise GreetdError(f"greetd refused the session: {resp}")
        resp = self._send({"type": "start_session", "cmd": cmd, "env": env})
        if resp.get("type") != "success":
            raise GreetdError(f"greetd could not start the session: {resp}")

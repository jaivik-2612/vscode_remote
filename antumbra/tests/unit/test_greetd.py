# SPDX-License-Identifier: GPL-3.0-or-later
"""The greetd IPC client against a fake greetd socket."""
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "config", "rootfs", "usr", "lib", "python3", "dist-packages"))
from antumbra.greetd import Greetd, GreetdError  # noqa: E402


def fake_greetd(path, script, received):
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    conn, _ = srv.accept()
    for reply in script:
        (length,) = struct.unpack("=I", conn.recv(4))
        received.append(json.loads(conn.recv(length)))
        data = json.dumps(reply).encode()
        conn.sendall(struct.pack("=I", len(data)) + data)
    conn.close()
    srv.close()


class GreetdTest(unittest.TestCase):
    def run_with(self, script):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "greetd.sock")
        received = []
        t = threading.Thread(target=fake_greetd, args=(path, script, received))
        t.start()
        try:
            while not os.path.exists(path):
                pass
            os.environ["GREETD_SOCK"] = path
            Greetd().start_user_session("amnesia", ["/usr/libexec/antumbra-session"], ["A=1"])
        finally:
            t.join(timeout=5)
        return received

    def test_happy_path_with_auth_prompt(self):
        received = self.run_with([
            {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password:"},
            {"type": "success"},
            {"type": "success"},
        ])
        self.assertEqual(received[0], {"type": "create_session", "username": "amnesia"})
        self.assertEqual(received[1], {"type": "post_auth_message_response", "response": ""})
        self.assertEqual(received[2]["type"], "start_session")
        self.assertEqual(received[2]["cmd"], ["/usr/libexec/antumbra-session"])

    def test_refusal_raises(self):
        with self.assertRaises(GreetdError):
            self.run_with([{"type": "error", "error_type": "auth_error", "description": "no"}, {"type": "success"}])


if __name__ == "__main__":
    unittest.main()

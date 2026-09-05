"""Private real-daemon regression tests; always stop and wait for its socket."""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

binary, scenario = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="zmx-boundary-", dir="/tmp") as root:
    env = dict(os.environ, ZMX_DIR=root)
    endpoint = os.path.join(root, "session")

    def run(*args):
        return subprocess.run([binary, *args], cwd=root, env=env,
                              capture_output=True, text=True, timeout=8)

    def send(tag, payload):
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(3)
            peer.connect(endpoint)
            def exact(length):
                parts = bytearray()
                while len(parts) < length:
                    chunk = peer.recv(length - len(parts))
                    assert chunk, "early EOF"
                    parts.extend(chunk)
                return parts
            hello = struct.pack("<HHI", 1, 1, 0) + b"regression"
            peer.sendall(struct.pack("<BI3x", 19, len(hello)) + hello)
            welcome_tag, length = struct.unpack("<BI3x", exact(8))
            assert welcome_tag == 20
            exact(length)
            peer.sendall(struct.pack("<BI3x", tag, len(payload)) + payload)
            try:
                return peer.recv(4096)
            except ConnectionResetError:
                return b""

    try:
        command = ["/bin/sh"] if scenario == "quoted" else ["/bin/sh", "-c", "sleep 60"]
        created = run("create", "--json", "session", "--", *command)
        assert created.returncode == 0, created.stderr
        pid = json.loads(created.stdout)["pid"]
        if scenario == "malformed":
            cases = [(12, b""), (12, struct.pack("<I", 0xffffffff)),
                     (8, bytes([255])), (7, struct.pack("<HHHH", 0, 80, 0, 0)),
                     (2, struct.pack("<HHHH", 65535, 65535, 0, 0)),
                     (12, struct.pack("<I", 1) + bytes([21])),
                     (29, b""), (29, struct.pack("<BI3x", 255, 0))]
            for tag, payload in cases:
                # With no PTY output, a refused request closes with no response.
                assert send(tag, payload) == b"", "malformed request was not refused"
            status = json.loads(run("inspect", "--json", "session").stdout)
            assert status["state"] == "live" and status["pid"] == pid, status
        else:
            name = "agent's notes.txt"
            path = name.encode()
            content = b"literal destination\n"
            send(12, struct.pack("<I", len(path)) + path + content)
            destination = os.path.join(root, name)
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                if os.path.exists(destination):
                    with open(destination, "rb") as file:
                        if file.read() == content:
                            break
                time.sleep(.03)
            else:
                raise AssertionError("Write did not create the literal destination")
    finally:
        run("kill", "--force", "session")
        deadline = time.monotonic() + 5
        while os.path.exists(endpoint) and time.monotonic() < deadline:
            time.sleep(.03)
        assert not os.path.exists(endpoint), "test daemon did not finish"

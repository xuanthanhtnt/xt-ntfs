#!/usr/bin/env python3
"""Talks to the XT NTFS helper over its UNIX socket (diagnostics, CI).

usage: xtctl.py '{"command": "status"}'
       xtctl.py status
Prints the JSON reply; exits 0 if the reply has "ok": true.
"""
import json
import socket
import sys

SOCKET = "/var/run/com.xuanthanhtnt.xtntfs.sock"


def call(request, timeout=900):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCKET)
    s.sendall(json.dumps(request).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data.decode())


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "status"
    request = json.loads(arg) if arg.startswith("{") else {"command": arg}
    reply = call(request)
    print(json.dumps(reply, indent=2, ensure_ascii=False))
    return 0 if reply.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

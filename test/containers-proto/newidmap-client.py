#!/usr/bin/env python3
"""newuidmap / newgidmap stand-in for mode "helper": asks uidmap-helper.py (root) to write the map.

Same arguments as newuidmap: <pid> <inner> <outer> <count> [...]. Installed under both names;
the name it runs as picks uid or gid.
"""
import os
import socket
import sys

SOCK = os.environ.get("CONTAINERS_PROTO_UIDMAP_SOCK", "/run/containers-proto/uidmap.sock")
kind = "gid" if os.path.basename(sys.argv[0]) == "newgidmap" else "uid"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(SOCK)
s.sendall(" ".join([kind] + sys.argv[1:]).encode())
s.shutdown(socket.SHUT_WR)
reply = s.recv(4096).decode()
if reply != "ok":
    sys.stderr.write("new%smap (helper): %s\n" % (kind, reply))
    sys.exit(1)

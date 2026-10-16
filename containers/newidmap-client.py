#!/usr/bin/python3 -I
"""newuidmap / newgidmap for a --containers session: asks the root uid-map helper to write the map.

Same arguments as newuidmap: <pid> <inner> <outer> <count> [...]. Installed under both names in
/usr/local/bin (the image ships no real newuidmap: under no-new-privileges its setuid bit gains
nothing); the name it runs as picks uid or gid. The helper is containers/uidmap-helper.py,
started by the entrypoint (§2d).
"""
import os
import socket
import sys

SOCK = "/run/claude-containers/uidmap.sock"
kind = "gid" if os.path.basename(sys.argv[0]) == "newgidmap" else "uid"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(SOCK)
except OSError as e:
    sys.stderr.write("new%smap: no uid-map helper at %s (%s): containers need a session "
                     "launched with --containers\n" % (kind, SOCK, e.strerror))
    sys.exit(1)
s.sendall(" ".join([kind] + sys.argv[1:]).encode())
s.shutdown(socket.SHUT_WR)
reply = s.recv(4096).decode()
if reply != "ok":
    sys.stderr.write("new%smap (helper): %s\n" % (kind, reply))
    sys.exit(1)

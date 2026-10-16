#!/usr/bin/python3 -I
"""The uid-map helper of a --containers session: a root daemon that writes the map for the caller.

newuidmap/newgidmap are setuid (or file-capability) binaries, and under no-new-privileges
neither kind gains anything, so rootless podman cannot map its subordinate ids. This daemon
runs as root (started by the entrypoint, §2d) and does what newuidmap does: it reads the
caller's uid from SO_PEERCRED, refuses a pid the caller does not own, refuses any range outside
the caller's own id plus its /etc/subuid (/etc/subgid) lines, then writes /proc/<pid>/uid_map
(gid_map). The client on PATH is newidmap-client.py. The pid's /proc directory is opened once
and both the owner check and the write go through that handle, so a pid reused in between
cannot redirect the write.

The kernel lets a map be written only by a process with CAP_SYS_ADMIN over the new namespace,
which its owner has and root outside it (a session has no CAP_SYS_ADMIN) does not. So, as
newuidmap does, the write is made from a child that takes the caller's uid and keeps only
CAP_SETUID and CAP_SETGID.
"""
import ctypes
import os
import pwd
import socket
import struct
import sys

SOCK = sys.argv[1] if len(sys.argv) > 1 else "/run/claude-containers/uidmap.sock"


def allowed_ranges(uid, kind):
    """[(start, count)]: the caller's own id, then its subordinate ranges."""
    name = pwd.getpwuid(uid).pw_name
    own = uid if kind == "uid" else pwd.getpwuid(uid).pw_gid
    out = [(own, 1)]
    with open("/etc/sub" + kind) as f:
        for line in f:
            parts = line.strip().split(":")
            if len(parts) == 3 and parts[0] in (name, str(uid)):
                out.append((int(parts[1]), int(parts[2])))
    return out


LIBC = ctypes.CDLL(None, use_errno=True)
PR_SET_KEEPCAPS = 8
CAP_SETGID, CAP_SETUID = 6, 7


def write_as(uid, dirfd, name, text):
    """Write name under dirfd from a child running as uid with CAP_SETUID and CAP_SETGID."""
    r, w = os.pipe()
    child = os.fork()
    if child == 0:
        try:
            os.close(r)
            if LIBC.prctl(PR_SET_KEEPCAPS, 1, 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "prctl")
            gid = pwd.getpwuid(uid).pw_gid
            os.setgroups([])
            os.setresgid(gid, gid, gid)
            os.setresuid(uid, uid, uid)
            caps = (1 << CAP_SETGID) | (1 << CAP_SETUID)
            hdr = (ctypes.c_uint32 * 2)(0x20080522, 0)
            data = (ctypes.c_uint32 * 6)(caps, caps, 0, 0, 0, 0)
            if LIBC.capset(hdr, data) != 0:
                raise OSError(ctypes.get_errno(), "capset")
            fd = os.open(name, os.O_WRONLY, dir_fd=dirfd)
            try:
                os.write(fd, text.encode())
            finally:
                os.close(fd)
            os.write(w, b"ok")
        except Exception as e:  # noqa: BLE001 - reported to the parent
            os.write(w, ("error: %s" % e).encode())
        finally:
            os._exit(0)
    os.close(w)
    reply = os.read(r, 4096).decode() or "error: no reply"
    os.close(r)
    os.waitpid(child, 0)
    return reply


def handle(conn):
    pid_, uid, _gid = struct.unpack("3i", conn.getsockopt(
        socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    data = b""
    while len(data) < 65536:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    words = data.decode().split()
    if len(words) < 5 or words[0] not in ("uid", "gid") or (len(words) - 2) % 3:
        return "bad request"
    kind, pid = words[0], int(words[1])
    ranges = allowed_ranges(uid, kind)
    lines = []
    nums = [int(w) for w in words[2:]]
    for i in range(0, len(nums), 3):
        inner, outer, count = nums[i:i + 3]
        if count < 1 or not any(s <= outer and outer + count <= s + c for s, c in ranges):
            return "range %d %d %d is not uid %d's" % (inner, outer, count, uid)
        lines.append("%d %d %d" % (inner, outer, count))
    dirfd = os.open("/proc/%d" % pid, os.O_RDONLY | os.O_DIRECTORY)
    try:
        if os.fstat(dirfd).st_uid != uid:
            return "pid %d is not owned by uid %d" % (pid, uid)
        return write_as(uid, dirfd, "%s_map" % kind, "\n".join(lines) + "\n")
    finally:
        os.close(dirfd)


def main():
    os.makedirs(os.path.dirname(SOCK), exist_ok=True)
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    os.chmod(SOCK, 0o666)
    srv.listen(16)
    while True:
        conn, _ = srv.accept()
        # One request at a time: a client that connects and sends nothing must not stall the rest.
        conn.settimeout(5)
        with conn:
            try:
                reply = handle(conn)
            except Exception as e:  # noqa: BLE001 - every failure goes back to the caller
                reply = "error: %s" % e
            conn.sendall(reply.encode())


if __name__ == "__main__":
    main()

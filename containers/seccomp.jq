# containers/seccomp.json is containers/seccomp-upstream.json (containers/common
# pkg/seccomp/seccomp.json at 82146f3, tag v0.64.2, unmodified) through this filter;
# test/launch-unit.sh rebuilds it and fails on any difference.
#
# Docker resolves a profile's includes.caps once, against the session's own cap set, and a
# session has no CAP_SYS_ADMIN, so sethostname, setdomainname and setns would stay refused even
# inside the namespaces podman creates (crun: sethostname: Operation not permitted). They move
# to the unconditional allow list, as moby's default already does for the first two; the kernel
# still checks CAP_SYS_ADMIN in the owning user namespace, so in the session's own namespaces
# they still fail.
(.syscalls[] | select(.includes.caps == ["CAP_SYS_ADMIN"] or .excludes.caps == ["CAP_SYS_ADMIN"])
    | .names) -= ["sethostname", "setdomainname", "setns"]
| .syscalls += [{"names": ["sethostname", "setdomainname", "setns"], "action": "SCMP_ACT_ALLOW"}]

# Drop keyctl and syslog from the unconditional allow list. containers/common allows both
# outright, where moby's default profile gates them behind CAP_SYS_ADMIN (and CAP_SYSLOG for
# syslog). A session holds no capability, so moby would already refuse them; removing them here
# matches that. Kernel keyrings are not namespaced, so a session that can call keyctl reaches the
# keyring of its own host uid, shared with the host user and every other session; syslog reads
# the host kernel ring buffer when dmesg_restrict is 0. Rootless podman builds and composes do
# not need either: keyring = false in containers/containers.conf keeps crun from asking for a
# session keyring, and nothing in a build reads the kernel log. add_key and request_key are not
# in this profile at all, so they stay blocked.
| (.syscalls[] | select((.names // []) | index("keyctl") or index("syslog")) | .names)
    -= ["keyctl", "syslog"]

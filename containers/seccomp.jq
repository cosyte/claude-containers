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

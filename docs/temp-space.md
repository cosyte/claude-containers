## Temp space: `/scratch`, not `/tmp`

`/tmp` is a **tmpfs**: it lives in RAM, is capped at 1 GB, and every page is charged to the
container's memory cgroup. With `TMPDIR` unset, everything large defaults there: `pip`/`uv`
building wheels, `docker save`/`load` tarballs, and (in a `--docker` session) the inner
containerd's mount dirs. The result is an install that dies at 1 GiB with a confusing
`ENOSPC` while the host has terabytes free, or, worse, a session that OOM-kills itself
because a build filled RAM it was accounted for.

So every container gets a **disk-backed `claude-scratch-<name>` volume mounted at
`/scratch`, and `TMPDIR` points at it**. Temp writes land on disk, where the space actually
is; `/tmp` stays a small, fast tmpfs for what a tmpfs is good at. `dockerd` and `containerd`
inherit `TMPDIR` from the entrypoint, and `bash_profile` re-exports it, so an SSH login gets
the same behaviour as the agent (sshd builds a fresh environment and would otherwise fall
back to `/tmp`).

It is scratch, not state: the entrypoint **clears it on every boot**. A volume: unlike a
tmpfs: survives restarts, so without that it would accumulate abandoned wheel builds and
half-written tarballs until the pool filled. `claude-rm --purge` deletes it.

Raising the `/tmp` tmpfs instead would have been the wrong fix: it is RAM, so a 10 GB `/tmp`
would simply move the failure from `ENOSPC` to an OOM kill inside the session's own cgroup.

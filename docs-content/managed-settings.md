---
id: managed-settings
title: Managed settings
sidebar_label: Managed settings
description: "Why the settings that are policy are written to a root-owned managed file that a session cannot rewrite."
---

# Managed settings

Everything this image asserts about a session used to land in one place:
`/home/claude/.claude/settings.json`. That file is owned by the agent user, it
lives on a per-project volume that outlives the container, and the entrypoint's
merge lets the file that is already there win on conflict. In other words the
process being policed owned the file the policy was written in. For an image
whose whole premise is an unattended agent running with
`--dangerously-skip-permissions`, that is the wrong owner.

Claude Code reads `/etc/claude-code/managed-settings.json` on Linux and applies
it **above every other settings level**, including `~/.claude` and a project's
`.claude/` ([managed settings](https://code.claude.com/docs/en/managed-settings)).
Root owns `/etc`. The entrypoint writes the policy there, as root, before the
agent process exists.

## What the image delivers as policy

| Setting | Why it is policy |
|---|---|
| `permissions.defaultMode` | The containment posture the operator chose (`CLAUDE_PERMISSION_MODE`). It is what the container IS. |
| `skipDangerousModePermissionPrompt` | Meaningless apart from the mode above; they are one decision. |
| `requiredMinimumVersion` | `2.1.295`: the oldest Claude Code a session may start on. An older CLI exits at startup and says to update (`claude update` itself still runs). 2.1.295 is where a hook's `"onFailure": "block"` arrived, which a fail-closed `PreToolUse` guard needs: on an older CLI such a guard fails open. Claude Code reads this key only from managed settings. Each start brings the CLI to npm's latest first (entrypoint §7d), so the floor bites only when that update could not run and the installed CLI is older. |

`includeCoAuthoredBy` is deliberately **not** here. It is a commit-message
preference: nothing about the container depends on it, and a session that wants
it off should be free to turn it off. The entrypoint still sets it in
`~/.claude/settings.json`, where a session can still change it.

`env.DISABLE_AUTOUPDATER` is deliberately **not** here either, since the
bump to Claude Code 2.1.258: auto-update is now this image's default
posture (neither the Dockerfile `ENV` nor `~/.claude/settings.json` sets it),
and each start also installs npm's latest (entrypoint §7d), so there is no "the
pin stops meaning anything" case left to root-enforce against. An operator who
wants a fleet to stay pinned, non-overridable from inside, sets
`DISABLE_AUTOUPDATER=1` in their own file at the managed path below (the image
never overwrites one it did not write); the start-time update reads that file's
`env` too and skips.

The Remote-Control-breaking telemetry kills (`DISABLE_TELEMETRY`,
`DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) are in neither file,
for the reason in
[Architecture and design decisions](./architecture.md#decision-telemetry-stays-on-remote-control-depends-on-it).
Putting one in the managed file would be worse than before, because no session
could strip it back out.

## Not overridable from inside

The file is mode `644` owned by `root`, in a `755` directory owned by `root`, so
a session running as `claude` cannot write it, replace it, chmod it, or unlink
it. `test/smoke.sh` proves that against a live container rather than asserting
it. One thing voids it, and it is not a defect in this mechanism:

- **Anyone with host access.** That is the point: the operator can always change
  the policy from outside, which is what the next section is about.

## Changing the policy, and turning bypass mode off

The operator changes the policy from the host, by one of three routes: set the value the image
delivers (`CLAUDE_PERMISSION_MODE`), mount a managed file of their own, or turn this image's
delivery off with `CLAUDE_MANAGED_POLICY=0`. The same path is where bypass mode would be turned
off outright (`permissions.disableBypassPermissionsMode`), which the image deliberately does not
do: which posture a fleet runs is the operator's call about their own risk, and this mechanism
exists to make such a call enforceable, not to make it. The steps are in
[Change the managed settings from the host](./change-the-managed-settings.md).

## Reading the boot log

`claude-logs <name>` carries a `Managed policy` line per boot, in the same
plain-language style as `Egress lockdown` and `Deploy key readable`. It states
the posture, and it is truthful in both directions: it never claims a control is
active when it is not, and it never denies one that is. Which line you get is
decided by the file on disk, not by what the entrypoint tried to do, so a policy
this image did not deliver is reported exactly like one it did.

```
[entrypoint] Managed policy       : ENFORCED from /etc/claude-code/managed-settings.json (image-supplied, owned by uid 0 and not by the agent user claude (uid 1000), file mode 644 in a mode-755 directory, not writable by claude). Managed settings, NOT overridable from inside the container: permissions.defaultMode, skipDangerousModePermissionPrompt
```

The owning uid is printed rather than the word "root" because the uid is what the
entrypoint compared against; it is `0` in this image.

```
[entrypoint] Managed policy       : NOT ENFORCED (the file at /etc/claude-code/managed-settings.json is UNREADABLE as policy: it is not parseable as JSON, so it was left exactly as it is and none of its settings are enforced). NO setting is managed: everything stays overridable from inside the container, exactly as it was before this image delivered any policy.
```

Setting **names** appear there, never their values: an operator's own managed
file can legitimately carry a token under `.env`, and the boot log is readable by
anyone who can run `claude-logs`.

## Fail-safe

Managed policy is **additive**. The entrypoint still composes the same
`~/.claude/settings.json` it always did, still strips the telemetry kills, still
self-heals the stale `claude-md-fragments` hook, and still merges the plugin
sets. A container whose managed file is missing, unparseable, or impossible to
write therefore behaves exactly as it did before this existed: it logs `NOT
ENFORCED` with the reason and starts the agent anyway. Nothing here can refuse a
boot, because a container that bricked over a policy file it could not write
would be a worse regression than the gap this closes.

## Guides that apply this

- [Change the managed settings from the host](./change-the-managed-settings.md)
- [Customize the baked-in config](./customize-the-baked-in-config.md)

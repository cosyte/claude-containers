---
id: change-the-managed-settings
title: Change the managed settings from the host
sidebar_label: Change the managed settings
description: "Change the policy a session cannot rewrite: set the value the image delivers, mount your own managed file, or turn the mechanism off."
---

# Change the managed settings from the host

The image writes the settings it treats as policy to the root-owned
`/etc/claude-code/managed-settings.json`, which a session cannot change. Why, and which settings
count as policy, is in [Managed settings](./managed-settings.md). This page is how the operator
changes them, from outside the container.

## Pick a route

Three routes, in increasing order of bluntness.

**1. Change the value the image delivers.** `CLAUDE_PERMISSION_MODE` in `.env`,
`claude-launch --model`-style per-container env, or
`claude-compose-gen`: whatever you already use to set it. The operator's value
is what becomes policy; the image only supplies the default.

```
CLAUDE_PERMISSION_MODE=acceptEdits ./bin/claude-launch myproj --workspace /srv/x
```

**2. Deliver your own managed file.** Mount it onto the vendor path and the
entrypoint leaves it exactly as it is: it never overwrites, chmods, or merges
into a file it did not write.

```
docker run … -v /srv/claude/policy.json:/etc/claude-code/managed-settings.json:ro …
```

Your file **replaces** the image's policy set rather than layering over it, so
carry `permissions.defaultMode` yourself if you want it managed. Whatever you
leave out is still applied through `~/.claude/settings.json` as before, where a
session can change it. The boot log names exactly which settings ended up
managed, so read it after the first boot.

**3. Turn the mechanism off.** `CLAUDE_MANAGED_POLICY=0` (or `false`/`no`/`off`)
makes the image establish no managed file of its own, and a container that has
none behaves exactly as it did before this existed. This is the escape hatch for
the risk the mechanism introduces: a setting that genuinely cannot be overridden
from inside is also no longer loosenable by a session that needs it loosened.
Only those four spellings turn it off; anything else leaves policy on and is
reported in the boot log, so a typo cannot read as a deliberate "off".

```
CLAUDE_MANAGED_POLICY=0 ./bin/claude-launch myproj --workspace /srv/x
```

What it cannot do is unsay a file that is already at the vendor path. The flag
governs what this image DELIVERS, not what Claude Code READS: if you also took
route 2 and mounted your own policy, that file is still there and still applied
above every other settings level, and the boot log says so rather than claiming
nothing is managed. Turning route 2 off means dropping the mount, from the host.
Combine the two and you get both lines:

```
[entrypoint] Managed policy       : ENFORCED from /etc/claude-code/managed-settings.json (operator-supplied, …). Managed settings, NOT overridable from inside the container: permissions.defaultMode, permissions.disableBypassPermissionsMode
[entrypoint] Managed policy       : NOTE, CLAUDE_MANAGED_POLICY=0 turned it off, so this image established no managed settings file, but a managed file was ALREADY at /etc/claude-code/managed-settings.json and Claude Code reads it above every other settings level, so the settings named above ARE in force and are not overridable from inside this container. …
```

## Turn bypass mode off, which the image does not do

`permissions.disableBypassPermissionsMode` is the managed-only key that stops
`--dangerously-skip-permissions` working at all. This path is where you would set
it:

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "disableBypassPermissionsMode": "disable"
  }
}
```

The image deliberately does **not** set it. Which posture a fleet runs is the
operator's call about their own risk, not this image's, and the image's default
is unattended full autonomy for a reason. This mechanism exists to make such a
call enforceable, not to make it. Note that the session launches with
`--dangerously-skip-permissions` on the command line, so disabling bypass mode
changes what that flag can do, not whether it is passed.

## Reference

- [Environment variables](./environment-variables.md)
- [The security model](./security-model.md)

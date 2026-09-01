# Managed settings: policy the session cannot rewrite

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
| `env.DISABLE_AUTOUPDATER` | A session that updates itself leaves the CLI version this image pins and verifies its flags against, so the pin stops meaning anything. |

`includeCoAuthoredBy` is deliberately **not** here. It is a commit-message
preference: nothing about the container depends on it, and a session that wants
it off should be free to turn it off. The entrypoint still sets it in
`~/.claude/settings.json`, where a session can still change it.

The Remote-Control-breaking telemetry kills (`DISABLE_TELEMETRY`,
`DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) are in neither file,
for the reason in
[architecture.md](architecture.md#decision-telemetry-stays-on-remote-control-depends-on-it).
Putting one in the managed file would be worse than before, because no session
could strip it back out.

## Not overridable from inside

The file is mode `644` owned by `root`, in a `755` directory owned by `root`, so
a session running as `claude` cannot write it, replace it, chmod it, or unlink
it. `test/smoke.sh` proves that against a live container rather than asserting
it. Two things void it, and neither is a defect in this mechanism:

- **`--docker` sessions.** An inner Docker daemon gives the session a route to
  root inside its own container, so it can rewrite the file. The boot log says so
  on those containers. This is the same caveat `CLAUDE_BROKER_GIT_KEY` and
  `CLAUDE_EGRESS_LOCKDOWN` carry.
- **Anyone with host access.** That is the point: the operator can always change
  the policy from outside, which is what the next section is about.

## Changing the policy from the host

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

## Turning bypass mode off, which this image does not do

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

## Reading the boot log

`claude-logs <name>` carries a `Managed policy` line per boot, in the same
plain-language style as `Egress lockdown` and `Deploy key readable`. It states
the posture, and it is truthful in both directions: it never claims a control is
active when it is not, and it never denies one that is. Which line you get is
decided by the file on disk, not by what the entrypoint tried to do, so a policy
this image did not deliver is reported exactly like one it did.

```
[entrypoint] Managed policy       : ENFORCED from /etc/claude-code/managed-settings.json (image-supplied, owned by uid 0 and not by the agent user claude (uid 1000), file mode 644 in a mode-755 directory, not writable by claude). Managed settings, NOT overridable from inside the container: permissions.defaultMode, skipDangerousModePermissionPrompt, env.DISABLE_AUTOUPDATER
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

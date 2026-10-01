---
name: record-step
description: Record a physical step Noah reports for one of his devices (bought, printed, picked, measured, flashed, mounted, tested, a fault, paired, an HA export live) so the devices program's parked goals can start. Use whenever Noah says in any session that he did such a step for proto42, glide6, node-v1, the house sensors, canlog-v1 or a chorus speaker build, even when the session is working in another repo.
---

# Record a device step

The devices program parks each goal that needs Noah's physical result until a file on
`NSchatz/devices` `origin/main` shows the step is done (`.claude/goals/*.lanes.toml`,
`parked_until`). Noah tells any session in chat (decided 2026-10-01 by Noah: "Tell any
session in chat"), and that session writes the record.

1. Work from `/workspace/devices` (clone `NSchatz/devices` there if it is missing) and
   `git pull --rebase`.
2. Read devices' own skill, `/workspace/devices/.claude/skills/record-step/SKILL.md`, and
   follow it exactly: it owns the steps-file format, the allowed step ids per device, the
   glide6 pick and look-approval commands, the validator, and the git flow (worktree, PR,
   gate, `/cache/locks/devices-merge.lock`). If that skill is already loaded because this
   session runs in devices, it wins over this one.
3. Quote Noah's words in the record. Never invent a step, an id, a date or a measurement;
   if what he said does not map to one allowed id, ask him which one he means.
4. When the record is on `origin/main`, tell Noah in one line which goal it unparks
   (`claude-goal-chain lanes /workspace/devices` shows the states).

If devices' skill does not exist yet (the program's goal 1 creates it), say so and leave
the step for a devices session; do not write the file by hand.

# shellcheck shell=bash
# --- 0b. Refuse the retired CLAUDE_CONTROLLER mode ------------------
# The substrate strip deleted the broker-dispatch tier this mode existed to drive, leaving
# bin/claude-controller a byte-identical pass-through to claude-autopilot: a mode whose only
# job was selecting another mode, so it was removed.
#
# This DIES where §0 merely WARNS, and the difference is the point. Those vars are inert
# leftovers in a .env: nothing reads them, so warning is enough and refusing to boot on a stale
# line would be the worse bug. CLAUDE_CONTROLLER=1 is not inert: it is an ACTIVE request for
# UNATTENDED operation. Warn-and-ignore would fall through to interactive mode and boot a fleet
# container into a Remote-Control session that nobody is watching and that never runs the loop:
# a container that looks alive and does nothing, which is the worst state this image can be in.
# So refuse, and name the replacement. It costs the operator one character.
#
# Fails FAST: here, not at mode selection in §12, so a `--restart unless-stopped`
# container doesn't crashloop through sshd, volume chown and a repo clone before saying why.
# (CLAUDE_CONTROLLER=0, which every older .env.example carries, matches nothing and boots
# clean: a stale line must never brick a container.)
case "${CLAUDE_CONTROLLER:-0}" in
    1|true|yes|on)
        die "CLAUDE_CONTROLLER was REMOVED. It had been a byte-identical pass-through
       to CLAUDE_AUTOPILOT=1 ever since the strip retired the Sysbox nested-worker-broker
       dispatch tier it existed to drive (see docs/legacy-sysbox-broker.md). Set
       CLAUDE_AUTOPILOT=1 instead: it is the same loop, and always was." ;;
esac

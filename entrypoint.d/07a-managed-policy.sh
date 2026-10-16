# shellcheck shell=bash
# --- 7a. Managed settings: operator policy the session cannot rewrite --------
# WHY THIS EXISTS. Everything section 8b composes lands in
# $CLAUDE_CONFIG_DIR/settings.json, a file owned by the agent user on a
# per-project volume that outlives the container, merged so that the EXISTING
# file wins on conflict. The process being policed therefore owns the file the
# policy is written in, which for an image whose premise is an unattended agent
# running with --dangerously-skip-permissions is the wrong owner. Claude Code
# reads /etc/claude-code/managed-settings.json on Linux ABOVE every other
# settings level, including ~/.claude and a project's .claude/
# (https://code.claude.com/docs/en/managed-settings), and root owns /etc.
# Writing the policy there, as root, before the agent process starts, is what
# makes an operator's choice survive a session that rewrites its own settings.
#
# ADDITIVE, NEVER A REPLACEMENT. Section 8b still runs and still writes every one
# of these keys into settings.json, so a container whose managed file is missing
# or unparseable behaves exactly as it did before this block existed. Nothing
# here can subtract from that; the worst case is a boot log saying policy is NOT
# enforced and a container that behaves as it always has.
#
# WHAT IS POLICY AND WHAT IS A PREFERENCE. Only settings whose loss changes what
# the container IS are delivered here:
#   permissions.defaultMode            the containment posture the operator chose
#   skipDangerousModePermissionPrompt  meaningless apart from the mode above
# includeCoAuthoredBy is deliberately NOT here. It is a commit-message
# preference: nothing about the container depends on it, and a session that
# wants it off should be free to turn it off. Section 8b still sets it.
# The telemetry kills stay out of BOTH files for the reason in 8b's own note.
#
# env.DISABLE_AUTOUPDATER is deliberately NOT here either: auto-update is the image's
# default posture (see the note above ARG CLAUDE_CODE_VERSION in the Dockerfile), and
# root-enforcing it here would remove the one lever (env, or a mounted settings/managed
# file) an operator has to opt back INTO staying pinned. An operator who wants that
# posture fleet-wide and non-overridable should set DISABLE_AUTOUPDATER=1 in their own
# file at $MANAGED_FILE below (never overwritten).
#
# NOT SET, DELIBERATELY: permissions.disableBypassPermissionsMode. This path is
# where an operator turns --dangerously-skip-permissions off outright, and the
# vendor documents it as a managed-only key. Which posture a fleet runs is the
# operator's call, not this image's; see docs/managed-settings.md for how to make
# it from the host. This block only makes such a call enforceable.
#
# NEVER FATAL. Every failure below is a log line and a boot that carries on to
# the agent, because a container that refused to start over a policy file it
# could not write would be a worse regression than the gap it closes. The hard
# rule is that the log tells the truth in BOTH directions: a container that could
# not enforce policy must never print a line that reads as if it did, and a
# container where a managed file IS in force must never print a line denying it,
# whoever put that file there and whatever this image did or did not deliver.
MANAGED_DIR="/etc/claude-code"
MANAGED_STAMP="/etc/claude-code-image-policy.sha256"
MANAGED_FILE="$MANAGED_DIR/managed-settings.json"
MANAGED_PERM_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
managed_ok=0          # 1 only when a policy file is really in force
managed_why=""        # why it is not, when it is not
managed_est_why=""    # why THIS IMAGE delivered no policy set of its own, if it did not
managed_source=""     # image | operator
managed_names=""      # the dotted paths the file delivers
managed_mode=""       # the file's octal mode, as verified below
managed_dmode=""      # the directory's octal mode, as verified below
managed_owner_uid="$(id -u)"   # the uid this entrypoint runs as: root, in this image

# The image's own policy set. jq builds it because a printf template would emit
# invalid JSON for an exotic CLAUDE_PERMISSION_MODE and the CLI would then drop
# the whole file, silently, with no policy in force and a happy-looking log.
MANAGED_POLICY="$(jq -n --arg pm "$MANAGED_PERM_MODE" '{
    permissions: { defaultMode: $pm },
    skipDangerousModePermissionPrompt: true
}' 2>/dev/null)" || MANAGED_POLICY=""

# True when $MANAGED_FILE is byte-for-byte the file THIS image last wrote. The
# stamp is what separates "our file, refresh it so a changed
# CLAUDE_PERMISSION_MODE takes effect on the next boot" from "the operator put
# this here, never touch it". Without it the second boot of a container would
# keep the first boot's policy for ever, and a mounted host policy would be
# overwritten by the image on start, which is the opposite of the point.
managed_is_ours() {
    local now stamped
    [[ -s "$MANAGED_STAMP" && -f "$MANAGED_FILE" ]] || return 1
    now="$(sha256sum < "$MANAGED_FILE" 2>/dev/null | cut -d' ' -f1)" || return 1
    stamped="$(cat "$MANAGED_STAMP" 2>/dev/null)" || return 1
    [[ -n "$now" && "$now" == "$stamped" ]]
}

# The dotted path of every setting a managed file delivers. NAMES ONLY, never
# values: an operator's own managed file can legitimately carry a token under
# .env, and this line goes into a boot log that anyone who can run `claude-logs`
# can read.
managed_keys() {
    jq -r '[paths(scalars) | map(tostring) | join(".")] | join(", ")' "$1" 2>/dev/null
}

if [[ -n "${CLAUDE_MANAGED_POLICY:-}" ]] \
   && [[ ! "${CLAUDE_MANAGED_POLICY}" =~ ^(0|false|no|off|1|true|yes|on)$ ]]; then
    # A typo must never read as a deliberate off (the lesson §12a records). The
    # safe direction is taken automatically here, so this only reports it.
    log "Managed policy       : NOTE, CLAUDE_MANAGED_POLICY='${CLAUDE_MANAGED_POLICY}' is not a recognised value, so policy was left ON (recognised: 0/false/no/off = off, 1/true/yes/on = on)"
fi

# STAGE 1: DELIVERY. Whether this image writes its own policy set this boot.
# Every branch that writes nothing records WHY it wrote nothing and stops there,
# because "this image delivered no policy" is not the same statement as "no
# policy is in force": an operator's own file can already be sitting at the
# vendor path, where the CLI reads it regardless. Stage 2 has the last word on
# what is enforced, and it looks at the disk.
if [[ "${CLAUDE_MANAGED_POLICY:-1}" =~ ^(0|false|no|off)$ ]]; then
    # The operator's escape hatch, from the host, for the risk this block
    # introduces: a setting that is genuinely not overridable from inside is also
    # no longer loosenable by a session that needs it loosened. It stops this
    # image DELIVERING policy. It cannot unsay a file that is already at the
    # vendor path, so it must not suppress the verification below either.
    managed_est_why="CLAUDE_MANAGED_POLICY=${CLAUDE_MANAGED_POLICY} turned it off, so this image established no managed settings file"
elif [[ -z "$MANAGED_POLICY" ]]; then
    managed_est_why="the image's own policy set could not be composed (jq failed for CLAUDE_PERMISSION_MODE='$MANAGED_PERM_MODE')"
elif [[ -e "$MANAGED_FILE" ]] && ! managed_is_ours; then
    # An operator delivered this file from the host: a bind mount, a derived
    # image, a docker cp. It is theirs. Never overwritten, never chmod'd, never
    # merged into. The image's own defaults still reach the session through §8b.
    managed_source="operator"
else
    managed_source="image"
    if ! mkdir -p "$MANAGED_DIR" 2>/dev/null; then
        managed_est_why="the directory $MANAGED_DIR could not be created (a read-only filesystem?)"
    elif ! chmod 755 "$MANAGED_DIR" 2>/dev/null; then
        managed_est_why="the directory $MANAGED_DIR could not be set to mode 755, so it may be writable by a non-root process"
    elif ! printf '%s\n' "$MANAGED_POLICY" > "$MANAGED_FILE.tmp" 2>/dev/null; then
        managed_est_why="$MANAGED_FILE.tmp could not be written (is $MANAGED_DIR read-only?)"
        rm -f "$MANAGED_FILE.tmp" 2>/dev/null || true
    elif ! chmod 644 "$MANAGED_FILE.tmp" 2>/dev/null; then
        managed_est_why="the mode of the new policy file could not be set to 644"
        rm -f "$MANAGED_FILE.tmp" 2>/dev/null || true
    elif ! mv -f "$MANAGED_FILE.tmp" "$MANAGED_FILE" 2>/dev/null; then
        # Composed into a temp file and moved into place, so a failure anywhere
        # above leaves the previous file intact instead of a truncated one that
        # the next boot would report as unparseable.
        managed_est_why="$MANAGED_FILE could not be replaced (it may be mounted read-only from the host)"
        rm -f "$MANAGED_FILE.tmp" 2>/dev/null || true
    fi
fi

# Whose file is at the vendor path, when this image did not put one there this
# boot. The stamp is the only thing that can tell a file this image wrote from
# one the operator delivered, and the log names the source either way.
if [[ -z "$managed_source" && -e "$MANAGED_FILE" ]]; then
    if managed_is_ours; then managed_source="image"; else managed_source="operator"; fi
fi

# STAGE 2: VERIFICATION, and it runs on every boot. The claim the log makes is
# about the file Claude Code will actually read at the top of its hierarchy, not
# about the code path that produced it, so what is on disk is what gets checked
# even when stage 1 delivered nothing. An operator who mounts their own policy
# file and ALSO turns this image's delivery off still has that file in force, and
# a boot that skipped this pass would print a denial of an enforcement that is
# really there. `-O` is "owned by the effective uid", and this entrypoint is root
# here, so it is the root-owned test; the agent-uid and mode checks are what make
# "not writable from inside" more than a hope.
if [[ ! -e "$MANAGED_FILE" ]]; then
    # Nothing at the path at all: stage 1's own reason is the honest one, because
    # it says why this image put nothing there.
    managed_why="${managed_est_why:-no file is present at $MANAGED_FILE}"
elif [[ ! -f "$MANAGED_FILE" ]]; then
    managed_why="$MANAGED_FILE is not a regular file, so nothing there can be read as policy"
elif ! jq -e . "$MANAGED_FILE" >/dev/null 2>&1; then
    managed_why="the file at $MANAGED_FILE is UNREADABLE as policy: it is not parseable as JSON, so it was left exactly as it is and none of its settings are enforced"
elif [[ ! -O "$MANAGED_FILE" ]]; then
    managed_why="$MANAGED_FILE is not owned by this container's root (uid $managed_owner_uid), so root does not control it"
elif [[ "$(stat -c %u "$MANAGED_FILE" 2>/dev/null)" == "$CLAUDE_UID" ]]; then
    managed_why="$MANAGED_FILE is owned by the agent user $CLAUDE_USER (uid $CLAUDE_UID), which could then rewrite it"
else
    managed_mode="$(stat -c %a "$MANAGED_FILE" 2>/dev/null || true)"
    managed_dmode="$(stat -c %a "$MANAGED_DIR" 2>/dev/null || true)"
    if [[ -z "$managed_mode" || -z "$managed_dmode" ]]; then
        managed_why="the mode of $MANAGED_FILE or of $MANAGED_DIR could not be read"
    elif (( (8#$managed_mode & 8#22) != 0 )); then
        managed_why="$MANAGED_FILE is mode $managed_mode, which grants write to group or other, so a non-root process could rewrite it"
    elif (( (8#$managed_dmode & 8#22) != 0 )); then
        # A 644 root-owned file inside a group-writable directory is not
        # protected: the agent cannot write the file, it just unlinks it and
        # puts its own there instead.
        managed_why="$MANAGED_DIR is mode $managed_dmode, which grants write to group or other, so a non-root process could unlink the policy file and put its own in its place"
    elif [[ ! -O "$MANAGED_DIR" ]]; then
        managed_why="$MANAGED_DIR is not owned by this container's root (uid $managed_owner_uid), so a non-root process could replace the policy file"
    else
        managed_names="$(managed_keys "$MANAGED_FILE")" || managed_names=""
        if [[ -z "$managed_names" ]]; then
            managed_why="$MANAGED_FILE carries no settings at all, so there is no policy in force"
        else
            managed_ok=1
        fi
    fi
fi

# Stamp only what this image itself wrote: a file it merely found is the
# operator's, and stamping it would make the next boot overwrite their policy.
if (( managed_ok == 1 )) && [[ "$managed_source" == "image" && -z "$managed_est_why" ]]; then
    managed_sha="$(sha256sum < "$MANAGED_FILE" 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ -n "$managed_sha" ]] && printf '%s\n' "$managed_sha" > "$MANAGED_STAMP" 2>/dev/null; then
        chmod 600 "$MANAGED_STAMP" 2>/dev/null || true
    else
        log "Managed policy       : NOTE, the stamp $MANAGED_STAMP could not be written, so a later boot will read this file as operator-supplied and leave it alone (a changed CLAUDE_PERMISSION_MODE would not take effect until the file is removed)"
    fi
fi

if (( managed_ok == 1 )); then
    # "owned by uid N", not "owned by root": N is what the -O test above actually
    # compared against, and it is 0 in this image.
    log "Managed policy       : ENFORCED from $MANAGED_FILE ($managed_source-supplied, owned by uid $managed_owner_uid and not by the agent user $CLAUDE_USER (uid $CLAUDE_UID), file mode $managed_mode in a mode-$managed_dmode directory, not writable by $CLAUDE_USER). Managed settings, NOT overridable from inside the container: $managed_names"
    if [[ -n "$managed_est_why" ]]; then
        # Policy is in force that this boot did not deliver. ENFORCED alone would
        # leave an operator who reached for the escape hatch wondering why their
        # settings are still managed; NOT ENFORCED alone would be exactly the
        # denial of a live enforcement this pairing exists to prevent.
        log "Managed policy       : NOTE, $managed_est_why, but a managed file was ALREADY at $MANAGED_FILE and Claude Code reads it above every other settings level, so the settings named above ARE in force and are not overridable from inside this container. Only the host can change that: remove or replace that file, drop the mount that supplies it, or start a fresh container from this image."
    fi
else
    log "Managed policy       : NOT ENFORCED ($managed_why). NO setting is managed: everything stays overridable from inside the container, exactly as it was before this image delivered any policy."
fi

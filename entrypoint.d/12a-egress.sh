# shellcheck shell=bash
# --- 12a. Egress lockdown (opt-in) -------------------------------------------
# Apply a default-deny firewall NOW, after the entrypoint's own setup (clone,
# plugin install) has finished with open egress, and as root (we still hold
# NET_ADMIN) before the unprivileged agent starts, so the agent runs sealed and
# cannot alter its own rules.
#
# TWO POSTURES, CHOSEN BY SPELLING. Fail-open stays the default and is what
# 1|true|yes|on have always meant: a firewall that could not be applied is a loud
# log line and the agent starts anyway, because a container that bricks a
# homelab's connectivity on a bad allowlist is the worse regression. `strict` is
# the fail-CLOSED spelling for an operator running an agent on untrusted input:
# same firewall, same ruleset, same log lines, but a run that leaves BOTH families
# unrestricted REFUSES TO START THE AGENT instead of proceeding. Lockdown stops
# being a request and becomes a requirement, and the operator escapes a refusing
# container by changing this one variable back.
#
# PER FAMILY, ALWAYS. A container can route IPv4 and IPv6, and the firewall can
# succeed on one and fail on the other, so there is no honest single-sentence
# answer to "is lockdown active". This block therefore never emits an unqualified
# "active": every line below names BOTH families and says, for each, whether it
# is default-deny or UNRESTRICTED. An operator reading `claude-logs` sees the
# unprotected family by name, which is the whole point of the line.
#
# The firewall's exit status IS the per-family verdict (see bin/claude-egress-firewall):
#   0 both default-deny · 2 IPv4 default-deny + IPv6 open · anything else both open.
# Note `set -e` is on, so the status is captured with `|| rc=$?`, never bare.
EGRESS_FIREWALL_BIN="/usr/local/bin/claude-egress-firewall"
if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on|strict)$ ]]; then
    egress_strict=0
    if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" == "strict" ]]; then egress_strict=1; fi
    egress_rc=0
    "$EGRESS_FIREWALL_BIN" || egress_rc=$?
    case "$egress_rc" in
        0) log "Egress lockdown      : IPv4 default-deny, IPv6 default-deny (allowlist + CLAUDE_EGRESS_EXTRA_HOSTS)" ;;
        2) log "Egress lockdown      : IPv4 default-deny, IPv6 UNRESTRICTED (the IPv6 ruleset could not be applied, see [egress] lines above)" ;;
        # Every OTHER status means the firewall applied NOTHING (fail_open() exits 1
        # on all five of its reasons, and a status this entrypoint cannot interpret
        # is read the same way: claim nothing). The log line is identical either way;
        # what strict adds is that the entrypoint stops here instead of falling
        # through to the tmux launch on the next statement.
        *) log "Egress lockdown      : IPv4 UNRESTRICTED, IPv6 UNRESTRICTED (FAILED to apply, egress left OPEN, see [egress] lines above)"
           if (( egress_strict == 1 )); then
               die "Egress lockdown was requested STRICTLY (CLAUDE_EGRESS_LOCKDOWN=strict) and the
       ruleset could NOT be applied: claude-egress-firewall exited $egress_rc, so this
       container has UNRESTRICTED egress on both address families. Starting the agent
       now is the exact outcome strict exists to prevent, so it is not started.
       The [egress] lines above name the cause (no NET_ADMIN capability, no iptables
       in the image, or an allowlist that resolved to nothing). Fix that, or set
       CLAUDE_EGRESS_LOCKDOWN=1 for the fail-open posture that logs and boots anyway."
           fi ;;
    esac
    # PERIODIC RE-RESOLVE. The allowlist above is a snapshot of DNS at boot, and this
    # container is meant to run for weeks: a CDN that rotates addresses turns the
    # snapshot into a set of rules pointing at hosts nobody serves any more, and the
    # agent's tooling starts failing at a moment nobody is watching. So a container
    # under lockdown can re-resolve on an interval, committing each refreshed ruleset
    # through the same atomic restore the boot pass used.
    #
    # IT RUNS HERE, AS ROOT, and it is started BEFORE the privilege drop for the same
    # reason the boot pass is: the agent has no NET_ADMIN and cannot signal a root
    # process, so it can neither alter what the refresh commits nor stop it happening.
    #
    # THE POSTURE IS ALWAYS STATED. Absent, malformed and non-positive intervals are
    # one case (no refresh), and silence about it would leave an operator who typed
    # `CLAUDE_EGRESS_REFRESH_INTERVAL=15m` believing their allowlist was being kept
    # current when it never will be. Only the "Egress lockdown" lines above are the
    # per-family posture contract; this is a separate line and does not touch it.
    egress_refresh="${CLAUDE_EGRESS_REFRESH_INTERVAL:-}"
    if [[ -z "$egress_refresh" ]]; then
        log "Egress refresh       : OFF (CLAUDE_EGRESS_REFRESH_INTERVAL is not set; the allowlist is resolved once, at boot, and pinned addresses go stale as CDNs rotate)"
    elif [[ ! "$egress_refresh" =~ ^[0-9]+$ ]] || (( 10#$egress_refresh <= 0 )); then
        log "Egress refresh       : OFF (CLAUDE_EGRESS_REFRESH_INTERVAL='${egress_refresh}' is not a positive whole number of seconds, so it cannot be an interval; the allowlist is resolved once, at boot)"
    elif [[ "$egress_rc" != 0 && "$egress_rc" != 2 ]]; then
        log "Egress refresh       : OFF (the boot pass committed no ruleset, so there is nothing to refresh; re-committing later would seal a container this log has already reported as UNRESTRICTED)"
    else
        "$EGRESS_FIREWALL_BIN" --refresh-daemon &
        log "Egress refresh       : every ${egress_refresh}s, as root (re-resolves the same allowlist and re-commits it atomically; a lookup that comes back empty RETAINS the ruleset in force and is logged by name, never narrowed)"
    fi
elif [[ -n "${CLAUDE_EGRESS_LOCKDOWN:-}" ]] && [[ ! "${CLAUDE_EGRESS_LOCKDOWN}" =~ ^(0|false|no|off)$ ]]; then
    # An unrecognised value: neither an off value nor an on/strict spelling. Silence
    # here is the failure mode strict exists to end, because a mistyped `stict` (or a
    # trailing space) would otherwise read as a deliberate "off" and the operator
    # would believe they were contained. WARN, never die: refusing to boot on a
    # stale or fat-fingered .env line would be a worse regression than the one being
    # reported, which is the same trade section 0 makes for the retired vars.
    log "Egress lockdown      : IPv4 UNRESTRICTED, IPv6 UNRESTRICTED (CLAUDE_EGRESS_LOCKDOWN='${CLAUDE_EGRESS_LOCKDOWN}' is not a recognised value, so NO firewall was applied; recognised: 0/false/no/off = off, 1/true/yes/on = lockdown that fails OPEN, strict = lockdown that refuses to start the agent when it cannot be applied)"
fi

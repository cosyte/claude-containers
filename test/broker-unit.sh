#!/usr/bin/env bash
# Unit tests for bin/claude-worker-broker (CC-2) — NO docker, NO sysbox, NO root.
#
# Covers the deny-by-default request validator, the FIXED launch template (golden
# argv compare — "a request yields exactly the template flags" at unit level), the
# substrate refusals (uid_map containment + Sysbox attestation floor), and the
# lease-discipline counters (via the broker_docker stub — the broker funnels every
# docker call through that one wrapper precisely so tests can stub it).
#
# The end-to-end proof (real controller, real unprivileged user, real inner
# dockerd) is bin/claude-broker-verify and needs Sysbox on the host; it is
# deliberately NOT run here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Source the broker (sourcing defines functions and returns — the built-in seam).
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-worker-broker"
# The broker (via _common.sh) sets -e; this harness counts failures instead of
# dying on the first one — undo it, keep -u/pipefail.
set +e

# Define AFTER the source: _common.sh ships its own ok() and would shadow the
# counters (the broker itself never calls ok/bad, so overriding back is safe).
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- request validation: deny by default ------------------------------------------

echo "== broker_validate_request: deny by default =="

mkreq() { printf '%b' "$1" > "$TMPD/req"; echo "$TMPD/req"; }

if broker_validate_request "$(mkreq 'repo=hl7\nitem=HL7-Q\n')" \
   && [[ "$REQ_REPO" == hl7 && "$REQ_ITEM" == HL7-Q ]]; then
    ok  "a well-formed request (repo + item) is accepted and parsed"
else
    bad "a well-formed request must be accepted (got REQ_ERROR='$REQ_ERROR')"
fi

if broker_validate_request "$(mkreq 'item=CC-9\nrepo=pathways\n')"; then
    ok  "key order does not matter"
else
    bad "key order must not matter (got '$REQ_ERROR')"
fi

if broker_validate_request "$(mkreq 'repo=hl7\n')"; then
    bad "a request missing 'item' must be rejected"
else
    ok  "missing 'item' is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'item=CC-9\n')"; then
    bad "a request missing 'repo' must be rejected"
else
    ok  "missing 'repo' is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\nitem=CC-9\nimage=evil:latest\n')"; then
    bad "an unknown key (image=) must be rejected — no template override"
else
    ok  "unknown key 'image' is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\nitem=CC-9\ncap-add=SYS_ADMIN\n')"; then
    bad "a forged cap-add key must be rejected"
else
    ok  "forged 'cap-add' key is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\nitem=CC-9\nmemory=64g\n')"; then
    bad "a forged memory-raise key must be rejected"
else
    ok  "forged 'memory' key is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\nrepo=mllp\nitem=CC-9\n')"; then
    bad "a duplicate key must be rejected"
else
    ok  "duplicate 'repo' key is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=-e\nitem=CC-9\n')"; then
    bad "a value starting with '-' (flag injection) must be rejected"
else
    ok  "flag-shaped value 'repo=-e' is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\nitem=a b c\n')"; then
    bad "a value with spaces (argv smuggling) must be rejected"
else
    ok  "space-carrying value is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=../../etc\nitem=CC-9\n')"; then
    bad "a path-traversal value must be rejected"
else
    ok  "path-traversal value is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\nitem=CC-9 --privileged\n')"; then
    bad "an item smuggling '--privileged' must be rejected"
else
    ok  "item smuggling '--privileged' is rejected ($REQ_ERROR)"
fi

long_item="$(printf 'a%.0s' $(seq 1 80))"
if broker_validate_request "$(mkreq "repo=hl7\nitem=$long_item\n")"; then
    bad "a 80-char value (over the 64 cap) must be rejected"
else
    ok  "over-length value is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq '')"; then
    bad "an empty request must be rejected"
else
    ok  "empty request is rejected ($REQ_ERROR)"
fi

if broker_validate_request "$(mkreq 'repo=hl7\r\nitem=CC-9\n')"; then
    bad "a CRLF request must be rejected (CR could hide payload from review)"
else
    ok  "carriage returns are rejected ($REQ_ERROR)"
fi

head -c 8192 /dev/zero | tr '\0' 'a' > "$TMPD/req"
if broker_validate_request "$TMPD/req"; then
    bad "an oversized (8 KB) request must be rejected"
else
    ok  "oversized request is rejected ($REQ_ERROR)"
fi

# Belt-and-suspenders: broker_validate_request rejects a symlink/FIFO directly.
# (The load-bearing TOCTOU closure is broker_process_request renaming the entry
# into the root-only staging dir BEFORE this check — proven on-host in
# bin/claude-broker-verify phase 4b, not reproducible without root here.)
printf 'repo=hl7\nitem=CC-9\n' > "$TMPD/real"
ln -s "$TMPD/real" "$TMPD/link"
if broker_validate_request "$TMPD/link"; then
    bad "a SYMLINK request must be rejected even when its target is well-formed"
else
    ok  "symlinked request is rejected ($REQ_ERROR)"
fi
mkfifo "$TMPD/fifo"
if broker_validate_request "$TMPD/fifo"; then
    bad "a FIFO request must be rejected (would hang the serve loop)"
else
    ok  "FIFO request is rejected without reading it ($REQ_ERROR)"
fi

mkdir "$TMPD/dir"
if broker_validate_request "$TMPD/dir"; then
    bad "a DIRECTORY request must be rejected (not a regular file)"
else
    ok  "directory request is rejected ($REQ_ERROR)"
fi

# --- serve-loop resilience: no hostile spool entry can kill the broker ---------------
# The serve loop runs each handler under errexit. A directory the agent mkdir's in
# the spool must be rejected, cleaned, and leave the handler RETURNING 0 — not abort
# the root control plane on `rm` of a non-regular entry. Run the real handler under
# `set -e` (as the loop does) so a regression that let `rm` fail is caught here.
echo
echo "== broker_process_request: a spool directory can't kill the serve loop =="
PDIR="$(mktemp -d)"; mkdir -p "$PDIR/requests" "$PDIR/staging" "$PDIR/responses"
mkdir "$PDIR/requests/dirreq"        # the hostile entry an agent could plant
broker_docker() { return 1; }        # must never be reached (validate rejects first)
rc=0
( BROKER_DIR="$PDIR"; set -e; broker_process_request "$PDIR/requests/dirreq" ) || rc=$?
if (( rc == 0 )) && [[ ! -e "$PDIR/staging/dirreq" ]]; then
    ok  "a directory in the spool is rejected + cleaned + returns 0 under errexit (loop survives)"
else
    bad "a spool directory must reject+clean+return 0 under set -e (rc=$rc, staging-left=$([[ -e "$PDIR/staging/dirreq" ]] && echo yes || echo no))"
fi
rm -rf "$PDIR"

# --- the fixed template: golden argv ------------------------------------------------

echo
echo "== broker_template_args: the template is FIXED =="

# Golden compare against the exact default template. If this fails because the
# template deliberately changed, update the golden here AND re-run the on-host
# proof (bin/claude-broker-verify) — the template is a security surface.
golden="$(cat <<'EOF'
run
-d
--name
claude-worker-hl7-q
--label
claude.worker=1
--label
claude.item=HL7-Q
--label
claude.repo=hl7
--label
claude.managed=1
--security-opt
no-new-privileges
--cap-drop
ALL
--cap-add
CHOWN
--cap-add
DAC_OVERRIDE
--cap-add
FOWNER
--cap-add
FSETID
--cap-add
KILL
--cap-add
SETGID
--cap-add
SETUID
--cap-add
SETPCAP
--cap-add
NET_BIND_SERVICE
--cap-add
SYS_CHROOT
--cap-add
AUDIT_WRITE
--memory
4g
--memory-reservation
3072m
--cpus
2
--pids-limit
2048
--shm-size
2g
-e
CLAUDE_SECRET_GUARD=1
-e
CLAUDE_EGRESS_LOCKDOWN=0
EOF
)"
got="$(CLAUDE_EGRESS_LOCKDOWN=0 CLAUDE_SECRET_GUARD=1 broker_template_args hl7 HL7-Q)"
if [[ "$got" == "$golden" ]]; then
    ok  "default template matches the golden argv exactly"
else
    bad "template drifted from the golden argv:"
    diff <(echo "$golden") <(echo "$got") | sed 's/^/        /'
fi

# The dangerous Docker-default caps must never appear, and nothing privileged ever.
if grep -qE 'NET_RAW|MKNOD|SETFCAP|--privileged|docker.sock' <<<"$got"; then
    bad "template must never re-add NET_RAW/MKNOD/SETFCAP or go privileged"
else
    ok  "NET_RAW/MKNOD/SETFCAP stay dropped; nothing privileged in the template"
fi

# Requests contribute VALUES only: the two injected strings appear solely in the
# name/label positions.
got2="$(broker_template_args myrepo MY-ITEM.1)"
if [[ "$(grep -c 'MY-ITEM.1' <<<"$got2")" == 1 && "$(grep -c '^myrepo$' <<<"$got2")" == 0 ]] \
   && grep -q '^claude.repo=myrepo$' <<<"$got2" && grep -q '^claude.item=MY-ITEM.1$' <<<"$got2"; then
    ok  "request values land only in the fixed label/name positions"
else
    bad "request values leaked outside the fixed label/name positions"
fi

# Egress lockdown inheritance: NET_ADMIN + the env mirror appear IFF the fleet
# control is on (the firewall needs the cap; the agent inside stays unprivileged).
got3="$(CLAUDE_EGRESS_LOCKDOWN=1 CLAUDE_EGRESS_EXTRA_HOSTS=registry.example.com broker_template_args hl7 CC-9)"
if grep -q '^NET_ADMIN$' <<<"$got3" && grep -q '^CLAUDE_EGRESS_LOCKDOWN=1$' <<<"$got3" \
   && grep -q '^CLAUDE_EGRESS_EXTRA_HOSTS=registry.example.com$' <<<"$got3"; then
    ok  "egress lockdown ON inherits into the worker (NET_ADMIN + env mirror)"
else
    bad "egress lockdown ON must add NET_ADMIN + mirror the env into the worker"
fi
if ! grep -q '^NET_ADMIN$' <<<"$got"; then
    ok  "egress lockdown OFF grants no NET_ADMIN"
else
    bad "egress lockdown OFF must not grant NET_ADMIN"
fi

# --- substrate refusals ---------------------------------------------------------------

echo
echo "== broker_check_substrate: fail-closed refusals =="

# Run the check in a subshell with seams; assert on exit code.
sub() { ( export "$@" CLAUDE_BROKER_SKIP_ROOT=1; broker_check_substrate ) >/dev/null 2>&1; }

if sub CLAUDE_BROKER_FAKE_UID_MAP="0 165536 65536" CLAUDE_SYSBOX_ATTESTED_VERSION=0.7.0; then
    ok  "userns-contained uid_map + attested 0.7.0 (the floor) is accepted"
else
    bad "a contained uid_map with a floor attestation must be accepted"
fi

if sub CLAUDE_BROKER_FAKE_UID_MAP="0 0 4294967295" CLAUDE_SYSBOX_ATTESTED_VERSION=0.7.0; then
    bad "uid_map base 0 (NO userns — not under sysbox-runc) must be REFUSED"
else
    ok  "uid_map base 0 (no userns containment) is refused"
fi

if sub CLAUDE_BROKER_FAKE_UID_MAP="garbage" CLAUDE_SYSBOX_ATTESTED_VERSION=0.7.0; then
    bad "an unreadable uid_map must be REFUSED (fail closed)"
else
    ok  "an unreadable uid_map is refused (fail closed)"
fi

if sub CLAUDE_BROKER_FAKE_UID_MAP="0 165536 65536" CLAUDE_SYSBOX_ATTESTED_VERSION=0.6.7; then
    bad "a pre-patch Sysbox attestation (0.6.7) must be REFUSED"
else
    ok  "pre-patch Sysbox attestation (0.6.7) is refused"
fi

if ( export CLAUDE_BROKER_SKIP_ROOT=1 CLAUDE_BROKER_FAKE_UID_MAP="0 165536 65536"
     unset CLAUDE_SYSBOX_ATTESTED_VERSION 2>/dev/null
     broker_check_substrate ) >/dev/null 2>&1; then
    bad "a MISSING Sysbox attestation must be REFUSED"
else
    ok  "missing Sysbox attestation is refused"
fi

if sub CLAUDE_BROKER_FAKE_UID_MAP="0 165536 65536" CLAUDE_SYSBOX_ATTESTED_VERSION=banana; then
    bad "a garbage Sysbox attestation must be REFUSED (fail closed)"
else
    ok  "garbage Sysbox attestation is refused (fail closed)"
fi

if sub CLAUDE_BROKER_FAKE_UID_MAP="0 165536 65536" CLAUDE_SYSBOX_ATTESTED_VERSION=0.7.0 SYSBOX_MIN_VERSION=0.0.0; then
    bad "a lowered SYSBOX_MIN_VERSION must be REFUSED via the attestation path too"
else
    ok  "the immovable CVE floor binds on the attestation path (lowered floor refused)"
fi

# --- lease discipline (broker_docker stubbed) --------------------------------------------

echo
echo "== lease discipline: one worker per item, capped total =="

# Stub the single docker funnel: pretend one live worker exists, item CC-BUSY.
broker_docker() {
    case "$*" in
        *"--format"*) echo "CC-BUSY" ;;   # live-item listing
        *"ps -q"*)    echo "abc123" ;;    # live-worker count
        *) return 1 ;;
    esac
}

if broker_item_live CC-BUSY; then
    ok  "an item with a live worker is detected (second lease refused upstream)"
else
    bad "broker_item_live must detect a live worker for the item"
fi
if broker_item_live cc-busy; then
    ok  "the lease predicate is case-folded (cc-busy == CC-BUSY, matching the lowercased container name)"
else
    bad "broker_item_live must match case-insensitively — container names are lowercased"
fi
if broker_item_live CC-FREE; then
    bad "a free item must not read as live"
else
    ok  "a free item reads as free"
fi
if [[ "$(broker_live_workers)" == 1 ]]; then
    ok  "live-worker count comes from the claude.worker label"
else
    bad "broker_live_workers miscounted (got '$(broker_live_workers)')"
fi

echo
echo "== failure paths fail closed (no ok-mis-report, no zero-count) =="

# A failed `docker run` must make broker_launch return nonzero. It is called
# from an `if` context, where bash suspends errexit inside the function — the
# explicit `|| return 1` is what keeps a daemon error from being echoed as ok.
broker_docker() {
    case "$*" in
        run\ *) echo "Error response from daemon: Conflict. The container name is already in use" >&2; return 125 ;;
        *) return 1 ;;
    esac
}
if out="$(broker_launch hl7 CC-X 2>&1)"; then
    bad "broker_launch must FAIL when docker run fails (got success: '$out')"
else
    ok  "a failed docker run makes broker_launch fail — never mis-reported as ok"
fi

# A daemon error while counting live workers must refuse upstream (fail closed),
# never read as "zero live workers" and over-admit past the cap.
broker_docker() { return 1; }
if broker_live_workers >/dev/null 2>&1; then
    bad "broker_live_workers must return nonzero when docker ps fails"
else
    ok  "a docker ps failure fails closed (refused upstream, not counted as 0)"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))

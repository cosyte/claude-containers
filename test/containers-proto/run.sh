#!/usr/bin/env bash
# Containers in sessions, prototype: can the claude user run rootless podman inside a session
# container started with production's hardening plus a few named options? Never part of the
# shipped image; run by .github/workflows/containers-proto.yml against test/containers-proto/
# Dockerfile, and the results go into docs/containers-in-sessions.md.
#
#   IMAGE=claude-containers-proto:ci test/containers-proto/run.sh [mode ...]
#
# Modes (all keep cap-drop ALL and production's minimal cap set):
#   single  no-new-privileges, no subuid lines: podman maps the one uid it has
#   helper  no-new-privileges, subuid lines, newuidmap/newgidmap replaced on PATH by a client
#           of a root daemon (uidmap-helper.py) that writes the maps
#   fcaps   no-new-privileges OFF, subuid lines, newuidmap/newgidmap with file capabilities
#
# Each step is PASS or FAIL (OFF: a posture this mode drops on purpose) with its seconds, in $OUT/results.tsv, a Markdown table in
# $OUT/results.md (and $GITHUB_STEP_SUMMARY), and one log per step in $OUT/logs. A mode's
# failing step is a result, not an error; the exit status is nonzero only when a security
# check fails (privileged, an extra capability, a non-zero CapEff, unshare -U working
# without the options, or the helper mapping an id that is not the caller's).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
IMAGE="${IMAGE:-claude-containers-proto:ci}"
OUT="${OUT:-$PWD/containers-proto-results}"
MODES=("$@"); (( ${#MODES[@]} )) || MODES=(single helper fcaps)
U=claude
CLAUDE_HOME=/home/claude
RUNDIR=/run/user/1000
HELPER_BIN=/usr/local/lib/containers-proto/helper-bin
SEC_FAIL=0

mkdir -p "$OUT/logs"
printf 'mode\tstep\tresult\tseconds\tnote\n' > "$OUT/results.tsv"

# Production's hardening, exactly as claude-launch and compose-gen apply it today, and
# claude-launch's other run flags that could bite a nested engine (init, limits, /tmp tmpfs).
# shellcheck disable=SC1091
HARDEN="$(source "$ROOT/bin/_common.sh"; harden_run_args)"
# shellcheck disable=SC1091,SC2016
read -r -a LAUNCH_ARGS <<<"$(source "$ROOT/bin/_common.sh"; echo --init --shm-size "$CLAUDE_SHM_SIZE" \
    --cpus "$CLAUDE_CPU_LIMIT" --memory "$CLAUDE_MEM_LIMIT" \
    --memory-reservation "$CLAUDE_MEM_RESERVATION" --pids-limit "$CLAUDE_PIDS_LIMIT")"
LAUNCH_ARGS+=(--tmpfs "/tmp:rw,nosuid,nodev,exec,size=1g")
MIN_CAPS="$(source "$ROOT/bin/_common.sh"; echo "$CLAUDE_MIN_CAPS")"
# The vendored profile is containers/common's verbatim. Docker resolves a profile's
# `includes.caps` once, against the container's own cap set, and a session has no
# CAP_SYS_ADMIN, so sethostname, setdomainname and setns (gated on it there) would stay
# refused (by the rule for sessions without it) even inside the namespaces podman creates. They are moved to the unconditional
# allow list, as moby's default profile already does for the first two: the kernel still
# checks CAP_SYS_ADMIN in the namespace's owning user namespace, so in the session's own
# namespaces they still fail.
SECCOMP="$OUT/seccomp-session.json"
jq '(.syscalls[] | select(.includes.caps == ["CAP_SYS_ADMIN"] or .excludes.caps == ["CAP_SYS_ADMIN"])
        | .names) -= ["sethostname", "setdomainname", "setns"]
    | .syscalls += [{"names": ["sethostname", "setdomainname", "setns"], "action": "SCMP_ACT_ALLOW"}]' \
    "$DIR/seccomp.json" > "$SECCOMP" || exit 2
PROTO_OPTS=(--security-opt "seccomp=$SECCOMP" --security-opt apparmor=unconfined
            --security-opt systempaths=unconfined --device /dev/net/tun)

record() { # mode step PASS|FAIL seconds note
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$OUT/results.tsv"
    printf '%-7s %-14s %-4s %5ss  %s\n' "$1" "$2" "$3" "$4" "$5"
}

# step <mode> <name> <timeout> <container> <bash script run as claude>
step() {
    local mode=$1 name=$2 to=$3 cn=$4 script=$5 log="$OUT/logs/$1-$2.log" t0=$SECONDS rc
    local path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    [[ "$mode" == helper ]] && path="$HELPER_BIN:$path"
    timeout "$to" docker exec -u "$U" -w "$CLAUDE_HOME" -e HOME="$CLAUDE_HOME" \
        -e XDG_RUNTIME_DIR="$RUNDIR" -e PATH="$path" \
        -e DOCKER_HOST="unix://$RUNDIR/podman/podman.sock" \
        "$cn" bash -c "set -euo pipefail; $script" > "$log" 2>&1
    rc=$?
    local note=""
    (( rc == 124 )) && note="timed out after ${to}s"
    (( rc != 0 && rc != 124 )) && note="$(grep -v '^\s*$' "$log" | tail -1 | cut -c1-160 | tr '\t|' '  ')"
    record "$mode" "$name" "$([[ $rc == 0 ]] && echo PASS || echo FAIL)" $((SECONDS - t0)) "$note"
    return "$rc"
}

asroot() { docker exec -u 0 "$@"; }

sec() { # mode name ok? note: a security assertion
    local res=PASS; [[ "$3" == 1 ]] || { res=FAIL; SEC_FAIL=1; }
    record "$1" "$2" "$res" 0 "$4"
}

# The container's own posture, from outside (docker inspect) and inside (CapEff of the user).
check_posture() { # mode container nnp-expected
    local mode=$1 cn=$2 nnp=$3 priv adds drops opts extra=() c
    priv="$(docker inspect -f '{{.HostConfig.Privileged}}' "$cn")"
    sec "$mode" not-privileged "$([[ "$priv" == false ]] && echo 1)" "Privileged=$priv"
    adds="$(docker inspect -f '{{join .HostConfig.CapAdd " "}}' "$cn")"
    drops="$(docker inspect -f '{{join .HostConfig.CapDrop " "}}' "$cn")"
    for c in $adds; do [[ " $MIN_CAPS " == *" ${c#CAP_} "* ]] || extra+=("$c"); done
    sec "$mode" caps-production "$([[ " $drops " == *" ALL "* && ${#extra[@]} == 0 ]] && echo 1)" \
        "CapDrop=$drops; beyond production: ${extra[*]:-none}"
    opts="$(docker inspect -f '{{join .HostConfig.SecurityOpt " "}}' "$cn" | sed 's/seccomp=[^ ]*/seccomp=<podman profile>/')"
    if [[ "$nnp" == 1 ]]; then
        sec "$mode" no-new-privs "$([[ "$opts" == *no-new-privileges* ]] && echo 1)" "$opts"
    else
        record "$mode" no-new-privs OFF 0 "off by design in this mode: $opts"
    fi
    c="$(docker exec -u "$U" "$cn" awk '/^CapEff/{print $2}' /proc/self/status)"
    sec "$mode" user-capeff-0 "$([[ "$c" == 0000000000000000 ]] && echo 1)" "CapEff=$c"
}

start() { # name nnp(1|0) proto-opts(1|0)
    local name=$1 nnp=$2 proto=$3 args
    # shellcheck disable=SC2206  # harden_run_args is a flat flag string, split on purpose
    args=($HARDEN)
    if [[ "$nnp" == 0 ]]; then
        local a=() i
        for (( i = 0; i < ${#args[@]}; i++ )); do
            if [[ "${args[i]}" == --security-opt && "${args[i+1]}" == no-new-privileges ]]; then
                i=$((i + 1)); continue
            fi
            a+=("${args[i]}")
        done
        args=("${a[@]}")
    fi
    [[ "$proto" == 1 ]] && args+=("${PROTO_OPTS[@]}")
    args+=("${LAUNCH_ARGS[@]}")
    docker rm -f "$name" >/dev/null 2>&1
    docker volume rm "$name-store" >/dev/null 2>&1
    echo "+ docker run ${args[*]} $IMAGE  ($name)"
    docker run -d --name "$name" "${args[@]}" \
        -v "$name-store:$CLAUDE_HOME/.local/share/containers" \
        --entrypoint sleep "$IMAGE" infinity >/dev/null
    asroot "$name" install -d -o "$U" -g "$U" -m 700 "$RUNDIR"
}

cleanup() {
    local m
    for m in neg "${MODES[@]}"; do
        docker rm -f "cp-$m" >/dev/null 2>&1
        docker volume rm "cp-$m-store" >/dev/null 2>&1
    done
}
trap cleanup EXIT

# --- Negative: production hardening alone refuses a user namespace --------------------------
start cp-neg 1 0
if docker exec -u "$U" cp-neg unshare -U true > "$OUT/logs/neg-unshare.log" 2>&1; then
    sec baseline unshare-refused 0 "unshare -U worked without the options"
else
    sec baseline unshare-refused 1 "$(tail -1 "$OUT/logs/neg-unshare.log" | tr '\t|' '  ')"
fi
check_posture baseline cp-neg 1
docker rm -f cp-neg >/dev/null 2>&1

BUILD_DF='FROM docker.io/library/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*'
COMPOSE='services:
  db:
    image: docker.io/library/postgres:17
    environment: { POSTGRES_PASSWORD: proto }
  app:
    image: docker.io/library/postgres:17
    command: ["sh", "-c", "until pg_isready -h db -U postgres; do sleep 1; done; echo reached-db; sleep infinity"]
    depends_on: [db]'

for mode in "${MODES[@]}"; do
    cn="cp-$mode"
    case "$mode" in
        fcaps) start "$cn" 0 1 ;;
        single|helper) start "$cn" 1 1 ;;
        *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
    case "$mode" in
        single)
            asroot "$cn" sed -i "/^$U:/d" /etc/subuid /etc/subgid
            # One uid: files owned by other uids in an image land as the user's own.
            asroot "$cn" sh -c "printf '[storage]\ndriver = \"overlay\"\n[storage.options.overlay]\nignore_chown_errors = \"true\"\n' > $CLAUDE_HOME/.config/containers/storage.conf"
            ;;
        helper|fcaps)
            asroot "$cn" sh -c "sed -i '/^$U:/d' /etc/subuid /etc/subgid; echo $U:100000:65536 >> /etc/subuid; echo $U:100000:65536 >> /etc/subgid"
            ;;
    esac
    [[ "$mode" == helper ]] && docker exec -d -u 0 "$cn" python3 /usr/local/lib/containers-proto/uidmap-helper.py
    sleep 1
    check_posture "$mode" "$cn" "$([[ $mode == fcaps ]] && echo 0 || echo 1)"
    step "$mode" unshare-U 30 "$cn" 'unshare -U true'
    if [[ "$mode" == helper ]]; then
        # The helper must refuse an id outside the caller's own and its subuid range (host root).
        if docker exec -u "$U" -e PATH="$HELPER_BIN:/usr/bin:/bin" "$cn" bash -c \
                'unshare -U sleep 10 & p=$!; sleep 1; newuidmap $p 0 0 1' > "$OUT/logs/helper-helper-root.log" 2>&1; then
            sec "$mode" helper-refuses 0 "the helper mapped uid 0"
        elif ! grep -q "is not uid" "$OUT/logs/helper-helper-root.log"; then
            # A refusal for any other reason (no daemon, no socket) proves nothing.
            sec "$mode" helper-refuses 0 "failed without the helper's refusal: $(tail -1 "$OUT/logs/helper-helper-root.log" | tr '\t|' '  ')"
        else
            sec "$mode" helper-refuses 1 "$(tail -1 "$OUT/logs/helper-helper-root.log" | tr '\t|' '  ')"
        fi
    fi
    step "$mode" podman-info 120 "$cn" 'podman info --format "{{.Store.GraphDriverName}} uids={{json .Host.IDMappings.UIDMap}}" | tee /dev/stderr'
    step "$mode" build-apt 900 "$cn" "mkdir -p /tmp/b && printf '%s\n' '$BUILD_DF' > /tmp/b/Dockerfile && podman build -t proto-build /tmp/b && podman run --rm proto-build curl --version"
    step "$mode" postgres 600 "$cn" 'podman run -d --name pg -e POSTGRES_PASSWORD=proto docker.io/library/postgres:17 >/dev/null
        for _ in $(seq 90); do podman exec pg pg_isready -U postgres && exit 0; sleep 1; done; podman logs pg; exit 1'
    step "$mode" nginx 600 "$cn" 'podman run -d --name web -p 127.0.0.1:8080:80 docker.io/library/nginx:stable >/dev/null
        for _ in $(seq 60); do curl -fsS http://127.0.0.1:8080/ | grep -q nginx && exit 0; sleep 1; done; podman logs web; exit 1'
    step "$mode" compose 600 "$cn" "mkdir -p /tmp/c && printf '%s\n' '$COMPOSE' > /tmp/c/compose.yaml && cd /tmp/c
        mkdir -p $RUNDIR/podman
        (podman system service --time=0 \"\$DOCKER_HOST\" > /tmp/c/service.log 2>&1 &)
        for _ in \$(seq 20); do [ -S $RUNDIR/podman/podman.sock ] && break; sleep 0.5; done
        docker version --format 'server {{.Server.Version}}'
        dc() { if docker compose version >/dev/null 2>&1; then docker compose \"\$@\"; else docker-compose \"\$@\"; fi; }
        dc -p proto up -d
        for _ in \$(seq 90); do dc -p proto logs app 2>/dev/null | grep -q reached-db && { dc -p proto down -t 1; exit 0; }; sleep 1; done
        dc -p proto logs; exit 1"
    docker rm -f "$cn" >/dev/null 2>&1
    docker volume rm "$cn-store" >/dev/null 2>&1
done

{
    echo "| mode | step | result | seconds | note |"
    echo "|---|---|---|---|---|"
    tail -n +2 "$OUT/results.tsv" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5}'
} > "$OUT/results.md"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$OUT/results.md" >> "$GITHUB_STEP_SUMMARY"
cat "$OUT/results.md"
exit "$SEC_FAIL"

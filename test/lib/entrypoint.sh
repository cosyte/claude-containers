# shellcheck shell=bash
# The boot path, for the suites that read it: entrypoint.sh (the loader) and the numbered
# sections in entrypoint.d/ that it sources in order. Needs REPO_ROOT.
#   ep_section <n>   the file of section <n> (0b, 2c, 7a, ...); a missing one is a path that
#                    does not exist, so the suite's extraction comes back empty and says so
#   ep_boot          the whole boot path as one text in the order it runs: the loader with
#                    the sections in place of its loop (for order checks and whole-boot greps)
EP_LOADER="$REPO_ROOT/entrypoint.sh"
EP_D="$REPO_ROOT/entrypoint.d"

ep_section() {
    local f n
    for f in "$EP_D"/[0-9]*.sh; do
        n="${f##*/}"; n="${n%%-*}"
        [[ "${n#0}" == "$1" ]] && { printf '%s\n' "$f"; return 0; }
    done
    printf '%s\n' "$EP_D/no-section-$1.sh"
}

ep_boot() {
    local f
    sed '/^for _section in /,$d' "$EP_LOADER"
    while IFS= read -r f; do cat "$f"; done < <(printf '%s\n' "$EP_D"/[0-9]*.sh | LC_ALL=C sort)
    sed '1,/^for _section in /d' "$EP_LOADER" | sed '1,/^done$/d'
}

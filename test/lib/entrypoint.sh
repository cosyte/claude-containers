# shellcheck shell=bash
# The boot path, for the suites that read it: entrypoint.sh (the loader) and the numbered
# sections in entrypoint.d/ that it sources in order. Needs REPO_ROOT.
#   ep_section <n>   the file of section <n> (0b, 2c, 7a, ...); a missing one is a path that
#                    does not exist, so the suite's extraction comes back empty and says so
#   ep_boot          the whole boot path as one text in the order it runs: the loader with
#                    the sections in place of its loop (for order checks and whole-boot greps)
#   ep_order         the section numbers the loader announces ("§<n>"), in the order it sources
#                    them, space-separated: what test/smoke.sh expects in the boot log, read
#                    from entrypoint.d/ so a new section never needs a hand-kept list
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

# The loader's own naming: the C-locale sort of [0-9]*.sh, the name up to its first '-', one
# leading 0 dropped (00b-x.sh is §0b, 12h-x.sh is §12h). The array has a name of its own: the
# suites that source this file use `out` and the like as strings, and shellcheck reads the
# sourced file into each of them.
ep_order() {
    local f n _ep_nums=()
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        n="${f##*/}"; n="${n%.sh}"; n="${n%%-*}"
        _ep_nums+=("${n#0}")
    done < <(printf '%s\n' "$EP_D"/[0-9]*.sh | LC_ALL=C sort)
    printf '%s\n' "${_ep_nums[*]}"
}

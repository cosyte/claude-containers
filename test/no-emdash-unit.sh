#!/usr/bin/env bash
# Unit tests for scripts/check-no-emdash.sh, the dash gate: NO docker, NO root, NO network.
#   - every banned form of the em dash and of the en dash in a tracked file reds, naming the file
#   - every banned form of both dashes on --stdin reds, naming the label
#   - what the rule allows passes: hyphens, a range written with "to", the minus sign (U+2212)
# Each case runs a copy of the real gate in a throwaway git repository, since the gate scans
# `git ls-files` from its own top level.
#
# This file is tracked and scanned, so it holds no banned form as text: every form below is
# assembled at runtime, the literal dashes from their UTF-8 bytes and each encoding from two
# pieces that are not themselves a banned form.
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/check-no-emdash.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# The twelve banned forms, as "name|text" lines: per dash, the literal character, its URL
# encoding, its JS backslash-u escape, and its named, decimal and hexadecimal HTML entities.
forms() {
    local name hex dec ent pct
    while read -r name hex dec ent pct; do
        name="${name/-/ }"
        printf '%s, literal|%b\n' "$name" "\\xe2\\x80\\x$pct"
        printf '%s, URL encoded|%s%s\n' "$name" '%E2%80%' "${pct^^}"
        printf '%s, backslash-u escape|%s%s\n' "$name" '\' "u$hex"
        printf '%s, named entity|%s%s\n' "$name" '&' "$ent;"
        printf '%s, decimal entity|%s%s\n' "$name" '&#' "$dec;"
        printf '%s, hexadecimal entity|%s%s\n' "$name" '&#x' "$hex;"
    done <<'EOF'
em-dash 2014 8212 mdash 94
en-dash 2013 8211 ndash 93
EOF
}

# repo <dir> <relpath> <body>: a throwaway git repository holding a copy of the gate, a clean
# README.md, and one file. The README is there so grep is handed two files: the gate runs it
# without -H, and grep names the file in a hit only when it has more than one.
repo() {
    mkdir -p "$1/scripts" "$1/$(dirname "$2")"
    cp "$GATE" "$1/scripts/check-no-emdash.sh"
    printf 'clean prose\n' > "$1/README.md"
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" init -q && git -C "$1" add -- .
}

test_forms_are_twelve_distinct_strings() {
    local n u
    n="$(forms | wc -l)"
    u="$(forms | cut -d'|' -f2 | sort -u | grep -c .)"
    [[ "$n" == 12 && "$u" == 12 ]] \
        && ok "the banned forms are twelve distinct, non-empty strings" \
        || bad "the banned forms: $n lines, $u distinct non-empty"
}

test_each_form_in_a_tracked_file_reds() {
    local name text dir out rc i=0
    while IFS='|' read -r name text; do
        i=$((i+1)); dir="$TMPD/file-$i"
        repo "$dir" docs/page.md "a $text b"
        out="$(cd "$dir" && bash scripts/check-no-emdash.sh 2>&1)"; rc=$?
        if [[ $rc == 1 && "$out" == *"docs/page.md:1:"* && "$out" == *"em or en dash"* ]]; then
            ok "a tracked file carrying the $name reds, naming the file"
        else
            bad "a tracked file carrying the $name: exit $rc: $out"
        fi
    done < <(forms)
}

test_each_form_on_stdin_reds() {
    local name text out rc
    while IFS='|' read -r name text; do
        out="$(printf 'title %s here\n' "$text" | bash "$GATE" --stdin 'the PR text' 2>&1)"; rc=$?
        if [[ $rc == 1 && "$out" == *"found in the PR text"* ]]; then
            ok "the $name on --stdin reds, naming the label"
        else
            bad "the $name on --stdin: exit $rc: $out"
        fi
    done < <(forms)
}

test_what_the_rule_allows_passes() {
    local clean dir out rc
    clean="$(printf 'a-b, pages 2 to 3, \xe2\x88\x921')"
    dir="$TMPD/clean"
    repo "$dir" docs/page.md "$clean"
    out="$(cd "$dir" && bash scripts/check-no-emdash.sh 2>&1)"; rc=$?
    [[ $rc == 0 && "$out" == *"OK (no em or en dashes in the tracked files"* ]] \
        && ok "a tracked file with hyphens, a range written with to and a minus sign passes" \
        || bad "the clean file: exit $rc: $out"
    out="$(printf '%s\n' "$clean" | bash "$GATE" --stdin 'clean text' 2>&1)"; rc=$?
    [[ $rc == 0 && "$out" == *"OK (no em or en dashes in clean text)"* ]] \
        && ok "the same text on --stdin passes" \
        || bad "the clean text on --stdin: exit $rc: $out"
}

test_forms_are_twelve_distinct_strings
test_each_form_in_a_tracked_file_reds
test_each_form_on_stdin_reds
test_what_the_rule_allows_passes

echo
echo "no-emdash-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))

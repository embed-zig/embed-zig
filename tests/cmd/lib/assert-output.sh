#!/usr/bin/env sh
set -eu

normalize_file() {
    sed 's/[[:space:]]*$//' "$1" | sed '/^$/d'
}

assert_output() {
    actual_file="$1"
    expected_file="$2"

    actual_norm="$(mktemp -t cmd-actual.XXXXXX)"
    expected_norm="$(mktemp -t cmd-expected.XXXXXX)"
    trap 'rm -f "$actual_norm" "$expected_norm"' EXIT

    normalize_file "$actual_file" >"$actual_norm"
    normalize_file "$expected_file" >"$expected_norm"

    if ! /usr/bin/cmp -s "$expected_norm" "$actual_norm"; then
        if [ -x /usr/bin/diff ]; then
            /usr/bin/diff -u "$expected_norm" "$actual_norm" || true
        else
            echo "expected:" >&2
            cat "$expected_norm" >&2
            echo "actual:" >&2
            cat "$actual_norm" >&2
        fi
        echo "command output did not match expected fixture" >&2
        return 1
    fi
}

if [ "$#" -ne 2 ]; then
    echo "usage: assert-output.sh ACTUAL EXPECTED" >&2
    exit 2
fi

assert_output "$1" "$2"

#!/usr/bin/env sh
set -eu

COMMON_PATH="${CMD_COMMON_PATH:-$0}"
CMD_COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "$COMMON_PATH")" && pwd)"
CMD_TEST_ROOT="$(CDPATH= cd -- "$CMD_COMMON_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$CMD_TEST_ROOT/../.." && pwd)"

if [ -f "$CMD_TEST_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    . "$CMD_TEST_ROOT/.env"
fi

CMDCTL="${CMDCTL:-$REPO_ROOT/zig-out/bin/cmdctl}"

require_cmdctl() {
    if [ ! -x "$CMDCTL" ]; then
        (cd "$REPO_ROOT" && zig build cmdctl)
    fi
    if [ ! -x "$CMDCTL" ]; then
        echo "cmdctl not found or not executable: $CMDCTL" >&2
        exit 1
    fi
}

run_fixtures() {
    transport="$1"
    shift
    require_cmdctl

    for input in "$CMD_TEST_ROOT"/fixtures/*.input; do
        name="$(basename "$input" .input)"
        expected="$CMD_TEST_ROOT/fixtures/$name.output"
        actual="$(mktemp -t "cmd-$transport-$name.XXXXXX")"
        command_line="$(cat "$input")"
        if [ -n "${CMD_COMMAND_PREFIX:-}" ]; then
            command_line="$CMD_COMMAND_PREFIX $command_line"
        fi
        "$CMDCTL" "$transport" "$@" --exec "$command_line" >"$actual"
        "$CMD_TEST_ROOT/lib/assert-output.sh" "$actual" "$expected"
        rm -f "$actual"
    done
}

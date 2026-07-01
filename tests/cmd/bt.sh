#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

: "${CMD_BT_SERVICE_UUID:?set CMD_BT_SERVICE_UUID or create tests/cmd/.env from .env.example}"
: "${CMD_BT_TX_CHAR_UUID:?set CMD_BT_TX_CHAR_UUID or create tests/cmd/.env from .env.example}"
: "${CMD_BT_RX_CHAR_UUID:?set CMD_BT_RX_CHAR_UUID or create tests/cmd/.env from .env.example}"

args="--service $CMD_BT_SERVICE_UUID --tx $CMD_BT_TX_CHAR_UUID --rx $CMD_BT_RX_CHAR_UUID"
if [ -n "${CMD_BT_ADDR:-}" ]; then
    args="--addr $CMD_BT_ADDR $args"
fi

preflight="$(mktemp "${TMPDIR:-/tmp}/cmd-bt-preflight.XXXXXX")"
set +e
# shellcheck disable=SC2086
"$CMDCTL" bt $args --exec ping >"$preflight" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
    if grep -q 'BtKcpHostBackendUnavailable' "$preflight"; then
        echo "SKIP bt: cmdctl BT/KCP host backend is unavailable"
        rm -f "$preflight"
        exit 0
    fi
    cat "$preflight" >&2
    rm -f "$preflight"
    exit "$status"
fi
rm -f "$preflight"

# shellcheck disable=SC2086
run_fixtures bt $args

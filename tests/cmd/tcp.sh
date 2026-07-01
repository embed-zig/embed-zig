#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

CMD_TCP_ADDR="${CMD_TCP_ADDR:-127.0.0.1}"
CMD_TCP_PORT="${CMD_TCP_PORT:-39074}"
CMD_TCP_START_SERVER="${CMD_TCP_START_SERVER:-1}"

if [ "$CMD_TCP_START_SERVER" = "1" ]; then
    require_cmdctl
    "$CMDCTL" serve-tcp --addr "$CMD_TCP_ADDR" --port "$CMD_TCP_PORT" &
    server_pid="$!"
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
    sleep 1
fi

run_fixtures tcp --addr "$CMD_TCP_ADDR" --port "$CMD_TCP_PORT"

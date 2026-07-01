#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

: "${CMD_SERIAL_PORT:?set CMD_SERIAL_PORT or create tests/cmd/.env from .env.example}"
CMD_SERIAL_BAUD="${CMD_SERIAL_BAUD:-115200}"
CMD_COMMAND_PREFIX="${CMD_SERIAL_COMMAND_PREFIX:-cmd}"
export CMD_COMMAND_PREFIX

if command -v stty >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin)
            stty -f "$CMD_SERIAL_PORT" "$CMD_SERIAL_BAUD" raw -echo || true
            ;;
        *)
            stty -F "$CMD_SERIAL_PORT" "$CMD_SERIAL_BAUD" raw -echo || true
            ;;
    esac
fi

run_fixtures serial --port "$CMD_SERIAL_PORT" --baud "$CMD_SERIAL_BAUD"

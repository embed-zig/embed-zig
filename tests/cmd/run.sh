#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

if [ "${CMD_FLASH_BEFORE_TEST:-0}" = "1" ]; then
    "$SCRIPT_DIR/flash-devkit.sh"
fi

if [ "${CMD_FLASH_BK_BEFORE_TEST:-0}" = "1" ]; then
    "$SCRIPT_DIR/flash-bk7258.sh"
fi

if [ "${CMD_RUN_TCP:-1}" = "1" ]; then
    "$SCRIPT_DIR/tcp.sh"
fi

if [ "${CMD_RUN_SERIAL:-0}" = "1" ]; then
    "$SCRIPT_DIR/serial.sh"
fi

if [ "${CMD_RUN_BT:-0}" = "1" ]; then
    "$SCRIPT_DIR/bt.sh"
fi

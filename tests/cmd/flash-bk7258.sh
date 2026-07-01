#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

: "${CMD_BK_SERIAL_PORT:?set CMD_BK_SERIAL_PORT or create tests/cmd/.env from .env.example}"
CMD_BK_BOARD="${CMD_BK_BOARD:-bk7258_v3_2024}"
CMD_ARMINO_SDK_PATH="${CMD_ARMINO_SDK_PATH:-$HOME/armino/bk_avdk_smp_v3.1.1}"

args="-Darmino-sdk-path=$CMD_ARMINO_SDK_PATH -Dboard=$CMD_BK_BOARD -Dapp=zux_command-console -Dport=$CMD_BK_SERIAL_PORT"
if [ -n "${CMD_BK_LOADER_PATH:-}" ]; then
    args="$args -Dbk-loader-path=$CMD_BK_LOADER_PATH"
fi

# shellcheck disable=SC2086
(cd "$REPO_ROOT/examples/bk/launcher" && zig build flash $args)

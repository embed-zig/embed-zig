#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

: "${CMD_FLASH_PORT:?set CMD_FLASH_PORT or create tests/cmd/.env from .env.example}"
CMD_DEVKIT_BOARD="${CMD_DEVKIT_BOARD:-devkit}"
CMD_ESP_IDF="${CMD_ESP_IDF:-$HOME/esp/esp-idf-v6.0}"

(cd "$REPO_ROOT/examples/esp/launcher" && \
    zig build flash \
        -Didf="$CMD_ESP_IDF" \
        -Dboard="$CMD_DEVKIT_BOARD" \
        -Dapp=zux_command-console \
        -Dport="$CMD_FLASH_PORT")

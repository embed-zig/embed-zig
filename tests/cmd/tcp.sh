#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
CMD_COMMON_PATH="$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/common.sh"

CMD_TCP_ADDR="${CMD_TCP_ADDR:-127.0.0.1}"
CMD_TCP_PORT="${CMD_TCP_PORT:-39074}"
CMD_TCP_START_SERVER="${CMD_TCP_START_SERVER:-1}"
CMD_TCP_SERVER_KIND="${CMD_TCP_SERVER_KIND:-desktop-app}"
CMD_DESKTOP_LAUNCHER_PORT="${CMD_DESKTOP_LAUNCHER_PORT:-39075}"

wait_for_tcp() {
    i=0
    while [ "$i" -lt 100 ]; do
        if "$CMDCTL" tcp --addr "$CMD_TCP_ADDR" --port "$CMD_TCP_PORT" --exec ping >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "desktop TCP command endpoint did not become ready at $CMD_TCP_ADDR:$CMD_TCP_PORT" >&2
    return 1
}

if [ "$CMD_TCP_START_SERVER" = "1" ]; then
    require_cmdctl
    if [ "$CMD_TCP_SERVER_KIND" = "cmdctl" ]; then
        "$CMDCTL" serve-tcp --addr "$CMD_TCP_ADDR" --port "$CMD_TCP_PORT" &
    else
        (
            cd "$REPO_ROOT/examples/desktop/launcher"
            zig build \
                -Dapp=zux_command-console \
                -Ddesktop_run_tray=false \
                -Dport="$CMD_DESKTOP_LAUNCHER_PORT" \
                -Dcommand_console_desktop_tcp=true
        )
        "$REPO_ROOT/examples/desktop/launcher/zig-out/app/EmbedDesktopLauncher.app/Contents/MacOS/desktop_launcher_app" &
    fi
    server_pid="$!"
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
    wait_for_tcp
fi

run_fixtures tcp --addr "$CMD_TCP_ADDR" --port "$CMD_TCP_PORT"

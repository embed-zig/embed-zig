#!/bin/sh

set -eu

export GIT_TERMINAL_PROMPT=0

dest="$1"
repo="$2"
want_commit="$3"
parent="$(dirname "$dest")"
lock="$dest.lock"
tmp=""
waited=0
lock_wait_timeout_s=300

cleanup() {
    if [ -n "$tmp" ] && [ -d "$tmp" ]; then
        rm -rf "$tmp"
    fi
    if [ "$(readlink "$lock" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$lock"
    fi
}

is_live_pid() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    kill -0 "$1" 2>/dev/null
}

mkdir -p "$parent"
while ! ln -s "$$" "$lock" 2>/dev/null; do
    if [ -L "$lock" ]; then
        owner_pid="$(readlink "$lock" 2>/dev/null || true)"
        if ! is_live_pid "$owner_pid"; then
            rm -f "$lock"
            continue
        fi
    elif [ -d "$lock" ]; then
        owner_pid="$(cat "$lock/pid" 2>/dev/null || true)"
        if ! is_live_pid "$owner_pid"; then
            rm -rf "$lock"
            continue
        fi
    elif [ -e "$lock" ]; then
        rm -rf "$lock"
        continue
    else
        continue
    fi
    waited=$((waited + 1))
    if [ "$waited" -ge "$lock_wait_timeout_s" ]; then
        echo "timed out waiting for git repo lock: $lock" >&2
        exit 1
    fi
    sleep 1
done
trap cleanup EXIT HUP INT TERM

if [ -e "$dest" ] && [ ! -d "$dest/.git" ]; then
    rm -rf "$dest"
fi

if [ ! -d "$dest/.git" ]; then
    tmp="$(mktemp -d "$parent/.tmp.XXXXXX")"
    git clone --depth 1 "$repo" "$tmp"
    mv "$tmp" "$dest"
    tmp=""
fi

if [ -n "$want_commit" ]; then
    current_head="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
    if [ "$current_head" != "$want_commit" ]; then
        if git -C "$dest" rev-parse --verify --quiet "$want_commit^{commit}" >/dev/null 2>&1; then
            git -C "$dest" checkout --detach "$want_commit"
        else
            git -C "$dest" fetch --depth 1 origin "$want_commit"
            git -C "$dest" checkout --detach FETCH_HEAD
        fi
    fi
else
    git -C "$dest" fetch --depth 1 origin
    git -C "$dest" checkout --detach FETCH_HEAD
fi

#!/usr/bin/env python3
"""Resolve the ESP-IDF export environment as stable KEY=VALUE lines."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys


_ENV_LINE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit the ESP-IDF export environment as KEY=VALUE lines.",
    )
    parser.add_argument(
        "--idf-path",
        required=True,
        help="Path to the ESP-IDF checkout.",
    )
    return parser.parse_args()


def expand_path_value(value: str, current_path: str) -> str:
    return (
        value.replace("${PATH}", current_path)
        .replace("$PATH", current_path)
        .replace("%PATH%", current_path)
    )


def resolve_idf_python(env: dict[str, str]) -> str:
    env_root = env.get("IDF_PYTHON_ENV_PATH")
    if not env_root:
        return sys.executable

    root = pathlib.Path(env_root)
    candidates = (
        root / "Scripts" / "python.exe",
        root / "Scripts" / "python",
        root / "bin" / "python3",
        root / "bin" / "python",
    )
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return sys.executable


def collect_exported_env(idf_path: str) -> dict[str, str]:
    tools = pathlib.Path(idf_path) / "tools" / "idf_tools.py"
    env = os.environ.copy()
    env["IDF_PATH"] = idf_path
    proc = subprocess.run(
        [sys.executable, str(tools), "export", "--format=key-value"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        if proc.stdout:
            sys.stderr.write(proc.stdout)
        raise SystemExit(proc.returncode)

    exported: dict[str, str] = {}
    current_path = env.get("PATH", "")
    for raw_line in proc.stdout.splitlines():
        line = raw_line.strip()
        if not line or not _ENV_LINE_RE.match(line):
            continue
        name, value = line.split("=", 1)
        if name == "PATH":
            value = expand_path_value(value, current_path)
        exported[name] = value

    exported["IDF_PATH"] = idf_path
    exported["ESP_ZIG_IDF_PYTHON"] = resolve_idf_python(exported)
    return exported


def main() -> int:
    args = parse_args()
    idf_path = os.path.abspath(args.idf_path)
    exported = collect_exported_env(idf_path)
    for name in sorted(exported):
        print(f"{name}={exported[name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

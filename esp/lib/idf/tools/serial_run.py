#!/usr/bin/env python3
# Helper tool that nudges the target through a serial reset cycle and waits for
# either download-mode or normal boot markers on the selected port.
# It does not create files; its side effect is serial-port interaction used by
# local flashing and monitoring workflows.

import os
import sys
import time
import subprocess

import serial
from serial.tools import list_ports

DOWNLOAD_MARKERS = (
    "DOWNLOAD(USB/UART0)",
    "waiting for download",
)
BOOT_MARKERS = (
    "SPI_FAST_FLASH_BOOT",
    "Loaded app from partition",
    "Calling app_main()",
    "ESP-IDF",
)


def read_state(port: serial.Serial, duration_s: float) -> tuple[str, str]:
    deadline = time.monotonic() + duration_s
    chunks: list[bytes] = []

    while time.monotonic() < deadline:
        waiting = port.in_waiting
        if waiting <= 0:
            time.sleep(0.05)
            continue

        chunk = port.read(waiting)
        if not chunk:
            continue

        chunks.append(chunk)
        text = b"".join(chunks).decode("utf-8", errors="ignore")

        if any(marker in text for marker in DOWNLOAD_MARKERS):
            return "download", text
        if any(marker in text for marker in BOOT_MARKERS):
            return "boot", text

    text = b"".join(chunks).decode("utf-8", errors="ignore")
    if not text:
        return "silent", text
    return "unknown", text


def wait_for_port(port_name: str, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if os.path.exists(port_name):
            return
        time.sleep(0.1)
    raise FileNotFoundError(port_name)


def candidate_ports() -> list[str]:
    def sort_key(device: str) -> tuple[int, str]:
        if "debug-console" in device:
            return (99, device)
        if "usbmodem" in device:
            return (0, device)
        if "usbserial" in device:
            return (1, device)
        if "ttyACM" in device:
            return (2, device)
        if "ttyUSB" in device:
            return (3, device)
        if device.startswith("/dev/cu."):
            return (4, device)
        return (10, device)

    devices = []
    for info in list_ports.comports():
        device = info.device
        lowered = device.lower()
        if "debug-console" in lowered or "bluetooth" in lowered:
            continue
        devices.append(device)
    devices.sort(key=sort_key)
    return devices


def resolve_port(port_name: str | None, timeout_s: float) -> str:
    if port_name:
        wait_for_port(port_name, timeout_s)
        return port_name

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        devices = candidate_ports()
        if devices:
            return devices[0]
        time.sleep(0.1)
    raise FileNotFoundError("no candidate serial port found")


def open_port(port_name: str | None) -> tuple[serial.Serial, str]:
    resolved_port = resolve_port(port_name, 5.0)
    deadline = time.monotonic() + 5.0

    while True:
        port = serial.Serial()
        port.port = resolved_port
        port.baudrate = 115200
        port.timeout = 0.05
        # Match the safe-open behavior we used for manual RST verification.
        port.dtr = False
        port.rts = False
        try:
            port.open()
            return port, resolved_port
        except serial.SerialException:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def run_esptool(port_name: str, after: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "esptool",
            "--chip",
            "esp32s3",
            "--port",
            port_name,
            "--before",
            "no_reset",
            "--after",
            after,
            "chip_id",
        ],
        capture_output=True,
        text=True,
    )


def esptool_watchdog_reset(port_name: str) -> None:
    result = run_esptool(port_name, "watchdog_reset")
    if result.returncode == 0:
        return

    detail = (result.stderr or result.stdout).strip()
    raise RuntimeError(detail or "esptool watchdog reset failed")


def probe_bootloader(port_name: str) -> bool:
    result = run_esptool(port_name, "no_reset")
    return result.returncode == 0


def main() -> int:
    if len(sys.argv) > 2:
        print("usage: serial_run.py [port]", file=sys.stderr)
        return 2

    requested_port = sys.argv[1] if len(sys.argv) == 2 and sys.argv[1] else None
    port, port_name = open_port(requested_port)
    try:
        state, observed = read_state(port, 0.8)
    finally:
        if port.is_open:
            port.close()

    if state == "boot":
        return 0

    if state == "download" or probe_bootloader(port_name):
        esptool_watchdog_reset(port_name)
    else:
        # If the target is already running a quiet app, avoid forcing another reset.
        return 0

    port, port_name = open_port(requested_port)
    try:
        state, observed = read_state(port, 2.0)
    finally:
        if port.is_open:
            port.close()

    if state == "download":
        print(
            "serial_run.py: target remained in download mode after watchdog reset.\n"
            f"{observed}",
            file=sys.stderr,
        )
        return 1

    if state != "boot" and probe_bootloader(port_name):
        print(
            "serial_run.py: target remained in bootloader/stub after watchdog reset.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

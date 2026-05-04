#!/usr/bin/env python3
# Helper tool that runs monitor commands through a PTY so interactive reset and
# timeout behavior work consistently across local ESP-IDF monitor sessions.
# It does not write files; it proxies terminal I/O and can inject port/reset
# handling before delegating to the real monitor command.

import os
import pty
import selectors
import signal
import subprocess
import sys
import time

from serial.tools import list_ports


def candidate_ports() -> list[str]:
    def sort_key(device: str) -> tuple[int, str]:
        lowered = device.lower()
        if "debug-console" in lowered:
            return (99, device)
        if "usbmodem" in lowered:
            return (0, device)
        if "usbserial" in lowered:
            return (1, device)
        if "ttyacm" in lowered:
            return (2, device)
        if "ttyusb" in lowered:
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


def inject_monitor_port(cmd: list[str]) -> list[str]:
    if "--no-reset" not in cmd:
        return cmd
    if "-p" in cmd or "--port" in cmd:
        return cmd
    if "monitor" not in cmd:
        return cmd

    ports = candidate_ports()
    if not ports:
        return cmd

    out = list(cmd)
    out[out.index("monitor"):out.index("monitor")] = ["-p", ports[0]]
    return out


def send_monitor_reset(master_fd: int) -> None:
    # Default ESP-IDF monitor keys: Ctrl+T, Ctrl+R.
    os.write(master_fd, b"\x14")


def run_direct(cmd: list[str]) -> int:
    return subprocess.call(cmd)


def run_direct_timeout(cmd: list[str], timeout: int) -> int:
    proc = subprocess.Popen(cmd)
    try:
        return proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        return 0


def run_with_pty(cmd: list[str], reset_target: bool = False) -> int:
    return run_with_custom_pty(cmd, None, reset_target)


def run_with_pty_timeout(cmd: list[str], timeout: int, reset_target: bool = False) -> int:
    return run_with_custom_pty(cmd, timeout, reset_target)


def run_with_custom_pty(cmd: list[str], timeout: int | None, reset_target: bool) -> int:
    child_pid, master_fd = pty.fork()
    if child_pid == 0:
        os.execvp(cmd[0], cmd)

    selector = selectors.DefaultSelector()
    selector.register(master_fd, selectors.EVENT_READ)

    stdin_fd = None
    if sys.stdin.isatty():
        stdin_fd = sys.stdin.fileno()
        selector.register(stdin_fd, selectors.EVENT_READ)

    start = time.monotonic()
    deadline = start + timeout if timeout is not None else None
    reset_sent = False
    reset_second_key_due: float | None = None
    banner_seen = False
    recent_output = bytearray()

    try:
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                try:
                    os.kill(child_pid, signal.SIGTERM)
                except OSError:
                    pass
                end_deadline = time.monotonic() + 5.0
                while time.monotonic() < end_deadline:
                    waited_pid, _ = os.waitpid(child_pid, os.WNOHANG)
                    if waited_pid == child_pid:
                        return 0
                    time.sleep(0.05)
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except OSError:
                    pass
                try:
                    os.waitpid(child_pid, 0)
                except ChildProcessError:
                    pass
                return 0

            waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
            if waited_pid == child_pid:
                if os.WIFEXITED(status):
                    return os.WEXITSTATUS(status)
                if os.WIFSIGNALED(status):
                    return 128 + os.WTERMSIG(status)
                break

            events = selector.select(timeout=0.1)
            for key, _ in events:
                if key.fileobj == master_fd:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        chunk = b""
                    if chunk:
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                        recent_output.extend(chunk)
                        if len(recent_output) > 4096:
                            del recent_output[:-4096]
                        if b"--- esp-idf-monitor" in recent_output:
                            banner_seen = True
                    continue

                if stdin_fd is not None and key.fileobj == stdin_fd:
                    data = os.read(stdin_fd, 1024)
                    if data:
                        os.write(master_fd, data)

            if reset_target and not reset_sent:
                ready = banner_seen or (time.monotonic() - start) >= 1.0
                if ready:
                    send_monitor_reset(master_fd)
                    reset_second_key_due = time.monotonic() + 0.05
                    reset_sent = True

            if reset_second_key_due is not None and time.monotonic() >= reset_second_key_due:
                os.write(master_fd, b"\x12")
                reset_second_key_due = None

        return 0
    finally:
        selector.close()
        try:
            os.close(master_fd)
        except OSError:
            pass


def main() -> int:
    timeout = None
    reset_target = False
    args_start = 1

    if len(sys.argv) > 1 and sys.argv[1].startswith("--timeout="):
        timeout = int(sys.argv[1].split("=", 1)[1])
        args_start = 2

    if len(sys.argv) > args_start and sys.argv[args_start] == "--reset-target":
        reset_target = True
        args_start += 1

    if len(sys.argv) < args_start + 1:
        print("usage: pty_monitor.py [--timeout=N] [--reset-target] <cmd...>", file=sys.stderr)
        return 2

    cmd = inject_monitor_port(sys.argv[args_start:])

    # 非交互上下文下，为 idf_monitor 分配一个 pseudo-tty，避免 stdin 非 tty 直接退出。
    if os.name == "posix" and reset_target:
        if timeout:
            return run_with_pty_timeout(cmd, timeout, True)
        return run_with_pty(cmd, True)

    if not sys.stdin.isatty() and os.name == "posix":
        if timeout:
            return run_with_pty_timeout(cmd, timeout)
        return run_with_pty(cmd)

    if timeout:
        return run_direct_timeout(cmd, timeout)
    return run_direct(cmd)


if __name__ == "__main__":
    raise SystemExit(main())

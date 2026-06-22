#!/usr/bin/env python3
import argparse
import sys
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=0.1)
    args = parser.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    ser.dtr = False
    ser.rts = False
    ser.reset_input_buffer()

    try:
        while True:
            data = ser.read(4096)
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
    except KeyboardInterrupt:
        return 0
    finally:
        ser.close()


if __name__ == "__main__":
    raise SystemExit(main())

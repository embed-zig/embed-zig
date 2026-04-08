# lib/at — AT-style command/response over byte streams

Portable **AT-like text protocol** helpers for embed-zig: ordered byte stream
in, line-oriented commands and responses out. Intended for device ↔ host
communication over **UART** or any other backend that exposes **read/write**
(and optional deadlines), e.g. USB CDC-ACM as a virtual serial port.

This package is **not** tied to cellular modems or `lib/cellular`; those stay
separate. Reuse patterns from `lib/bt/Transport.zig` (type-erased transport +
deadlines). **`lib/at/Transport` adds `flushRx`** and is not identical to
`bt/Transport`; see **flushRx vs reset** below.

## Goals

1. **Transport abstraction** — One VTable for `read` / `write`, **`flushRx`**,
   **`reset`**, `deinit`, and read/write deadlines so the same protocol code runs
   on UART, USB CDC, or test doubles. **`flushRx` and `reset` are different**
   operations (see Implementation approach).
2. **Framing & parsing** — Line splitting (`\r`/`\n`), trimming, optional echo
   stripping; incremental parsers that work on fixed buffers (no heap in the
   hot path unless an API explicitly takes an `Allocator`).
3. **Session / command API** — Send a command, collect lines until a terminal
   (`OK`, `ERROR`, …) with timeouts; extensible for project-specific URCs
   (unsolicited lines).
4. **embed alignment** — Runtime primitives via injected `embed` / `lib`
   namespace where needed; avoid direct `std` in non-test library code per
   `AGENTS.md`.

## Non-goals (initially)

- **CMUX / multiplexing** — Not part of this package; demux belongs under
  `lib/cellular` (or similar). AT code assumes **one logical byte stream** per
  `Transport` after any lower-layer mux.
- PPP, or SIMCOM/Quectel profile parsers (remain under `lib/cellular` if
  needed).
- Defining a single global “standard AT command set” for all products; the
  library should stay **generic** and let apps register commands or matchers.

## Implementation path (planned source layout)

| Path | Role |
|------|------|
| `lib/at.zig` | Root module: re-exports the stable public surface (and `test_runner` table). |
| `build/lib/at.zig` | Build-system module definition (`at` module in `build.zig`). |
| `lib/at/Transport.zig` | Type-erased byte transport: like `lib/bt/Transport.zig` plus required **`flushRx`** (discard RX buffer; `reset` remains for stronger teardown). |
| `lib/at/LineReader.zig` (or `framing.zig`) | Fixed-buffer incremental framing aligned with **ITU-T V.250** (CR / default S3) and common **CRLF** on the wire (same CRLF idea as **HTTP/1.x** header lines). Trim / echo strip only as documented there. |
| `lib/at/Session.zig` | **Implemented** — `Session.make(lib, line_cap)` (uses `lib.time.milliTimestamp` and `lib.mem.eql` / `startsWith` in the body). See **Session implementation scope** below. |
| `lib/at/Dte.zig` | **Implemented** — **`at.Dte.make(lib, line_cap)`**: product-facing wrapper over `Session` (`init`, `exchange`, `writeRaw`, `readExact`, `flushRx`, `clearReader`); **`comptime`** requires `lib.time.milliTimestamp`. |
| `lib/at/Dce.zig` | **Implemented** — **`CommandEntry` + `handleLine`**: longest-prefix match on ASCII-trimmed command line, reply written to caller buffer; optional **`default_respond`**. No I/O; pair with a loopback `Transport` in tests. |
| `lib/at/test_runner/dte_loopback.zig` | Smoke runner: in-process loopback `Transport` + `Dce` + `Dte`, no hardware. |
| `lib/at/test_runner/dte_serial.zig` | Smoke runner: host **DTE** over a real serial path (e.g. Mac + device acting as **DCE** on USB-UART). Skips when env not set. |

Exact file names may shift; **layering is fixed**:

```text
Transport → LineReader (framing) → Session → Dte
                                    ↑
                              Dce (tests / mock)
```

## Implementation approach

### Layering

1. **Transport** — Only bytes, deadlines, and lifecycle hooks; no AT syntax.
   - **`flushRx`** — Discard **inbound** data still buffered in the driver /
     hardware RX path; the link (UART/USB) usually **stays up**.
   - **`reset`** — **Stronger** recovery: board-defined (e.g. modem hard reset,
     controller re-init). May tear session state; **not** a synonym for
     `flushRx`.
2. **LineReader** — Produces complete lines using **V.250-style CR** and **CRLF /
   LF** rules (see `LineReader.zig` doc); no `OK`/`ERROR` semantics.
3. **Session** — One **exchange**: send a command line, then read lines until a
   **final result** (`OK`, `ERROR`, `+CME ERROR:`, …). Intermediate lines are
   **information responses**; **URCs** (unsolicited) are routed through an
   optional handler or queue so they do not terminate the current exchange.
   See **What belongs in Session (not LineReader)** below.
4. **Dte** — Product-facing API on the host/MCU that talks to the modem. Holds
   config (timeouts, CRLF, echo policy).
5. **Dce** — Table-driven **`CommandEntry { prefix, respond }`** with
   **longest-prefix** dispatch (`handleLine`); used for **loopback tests** and modem mocks, not
   for vendor AT profiles (those stay in app / `lib/cellular`).

### What belongs in Session (not LineReader)

`LineReader` only splits the byte stream on **CR / CRLF / LF** (see
`LineReader.zig`). Anything where **line boundaries are not enough** for meaning
belongs in **`Session` / `Dte`** (command state machine, timeouts, mode switches):

| Situation | Where it is handled |
|-----------|---------------------|
| **Echo (ATE1)** | **Session**: `exchange` always skips a line that matches the last sent **cmd** body (ASCII trim), before counting non-terminal lines; prefer **ATE0** if echo shape does not match. |
| **Prompts** (e.g. SMS **`>`** after `AT+CMGS`) | **Session**: detect prompt (by line or byte scan), then switch phase — do **not** treat payload as a normal “English” line. |
| **PDU / body after prompt** | **Session**: use **`writeRaw`** / **`readExact`** (raw `Transport` I/O) for **fixed length**, until **0x1A**, or per modem spec — **bypass `LineReader`**; then **`clearReader`** / resume **`exchange`**. |
| **Length-prefixed binary** (e.g. `+QHTTPREAD: <len>` then raw bytes) | **Caller**: one **`exchange`** or **`readLine`** to get the header line, parse `len`, then **`readExact`** for `len` bytes (not another `exchange`). |
| **File / bulk data** | Usually **socket or data plane** (TCP/TLS/HTTP AT), or **framed** transfer — not “read lines until EOF”. |
| **CMUX / PPP** | **Below** Session: demux to a **single logical AT stream** first; `LineReader` + `Session` attach **only** to that stream. |

### `LineReader` errors: `LineTooLong` vs `OutTooSmall`

These are **not** fixed global byte counts; they depend on **your buffers**:

- **`error.LineTooLong`** — The internal `LineReader(cap)` buffer has **`cap`
  bytes** in `pending` **without** a **complete line** (no terminator yet).
  So “too long” means: **one logical line (plus any split terminator) would need
  more than `cap` bytes** before a CR/LF-style end. Raise `cap` at compile time,
  or treat as protocol/peer error in Session.

- **`error.OutTooSmall`** — The caller-supplied **`out` slice** passed to
  `readLine` / `tryPopLineInto` is **shorter than** the **trimmed line body**
  (after CR/LF removal and optional ASCII space trim). “Too small” means:
  **`out.len < line_body_len`**. Use a larger `out` buffer or handle the error
  in Session.

**Retry / layering:** `LineReader` **does not** automatically retry on
`OutTooSmall` — it returns the error and **leaves `pending` unchanged** (the
complete line is still buffered). **`Session` / `Dte`** is the right place to
retry with a **larger `out`** (e.g. call `tryPopLineInto` again), or to pick an
`out` size up front that fits expected responses and avoid the error entirely.

### Session implementation scope (`lib/at/Session.zig`)

Use **`const S = at.Session.make(comptime_lib, line_cap);`** — `line_cap` must match
the **`LineReader(cap)`** used inside (one line’s max body + terminator budget).

**Included today**

- **`exchange(cmd, options)`** — Sends `cmd` (optional `\r\n` via `Config.append_crlf`),
  then reads lines until **`OK`**, **`ERROR`**, **`+CME ERROR:`**, or **`+CMS ERROR:`**
  (after ASCII trim). Other lines are **non-terminal**: optional **`on_info_line`**
  callback (URC / `+CSQ:` / …); **`max_non_terminal_lines`** prevents infinite loops.
- **Command echo** — **`exchange`** skips the first line equal to the last **`cmd`** body (after ASCII trim), so **ATE1** echo does not consume **`max_non_terminal_lines`** or **`on_info_line`**; if the modem’s echo differs from **`cmd`**, use **ATE0** or filter elsewhere.
- **Timeouts** — **`command_timeout_ms`** bounds the whole exchange; **`transport_read_timeout_ms`**
  / **`transport_write_timeout_ms`** are applied per `Transport` read/write attempt
  (same pattern as `lib/bt/host/Hci.zig`). **Note:** each **`readLine`** sets the read
  deadline **once** at entry; if one line arrives slowly over many small reads, increase
  **`transport_read_timeout_ms`** or split work at **`Dte`** (see `LineReader` doc).
- **`writeRaw` / `readExact`** — For **binary segments** after a **`>`** prompt or similar;
  **`readExact`** loops **`transport.read`** with a fresh deadline each time.
- **`flushRx` / `clearReader`** — Align RX state when switching between line mode and raw mode.

**Not implemented here (caller, `Dte`, or product code)**

- **`AT+CMGS` / `>`** two-phase state machine (detect prompt, then PDU, then **0x1A**).
- Parsing **`+CME ERROR: <n>`** numeric codes.
- Automatic **`OutTooSmall` retry** with a larger line buffer (see **LineReader errors** above).
- **CMUX / PPP** (stay below this `Transport`).

### `exchange` (naming / behavior)

**Exchange** means one AT **transaction**: write the command (with optional
`\r\n`), then read lines until a **terminal** line. Collecting informational
lines should use **callbacks** or **fixed-capacity buffers** — not `std`
containers in the default hot path (see `AGENTS.md`). Heap-backed collection is
optional and belongs at the integration / app boundary if needed.

### DTE / DCE terminology

- **DTE** — Sends AT commands (typical MCU / host code).
- **DCE** — Modem / module that responds. **Not** the same as Bluetooth “HCI
  Host”; avoid overloading “host” here.

### USB

Any backend that exposes a **reliable ordered byte stream** with read/write
(and optional deadlines) is valid — including **USB CDC-ACM**. Implement a
`Transport` adapter for your USB stack; `lib/at` stays agnostic.

### embed injection

- Use `comptime lib: type` on factories (e.g. `Dte(lib, line_buf_cap)`), with
  `comptime` validation of required `lib.time` symbols (`milliTimestamp` /
  `nanoTimestamp`) for deadline math, consistent with `lib/bt/host/Hci.zig` and
  `lib/cellular/modem/Modem.zig`.
- Non-test library sources under `lib/at` should not import `std` directly.

## Testing scheme

### Unit tests

- Live **next to** the implementation file (`test "…"` blocks in the same
  `.zig`).
- No network; no serial hardware. Cover `LineReader` edge cases, terminal
  detection, echo stripping, and timeout behavior with **fake `Transport`**
  implementations.

### `test_runner/` (shared smoke runners)

Follow `lib/wifi/test_runner` / `lib/testing.TestRunner`: `make(comptime lib:
type)` (and optional `makeWithOptions`) returning `testing.TestRunner`, with
`init` / `run` / `deinit`.

| Runner | Purpose |
|--------|---------|
| `dte_loopback` | **Memory or ring-backed `Transport`** wiring **Dte** to an in-process **Dce** table. Runs in CI without hardware. |
| `dte_serial` | **Host-only** (e.g. macOS): open serial path from env (**e.g. `EMBED_AT_SERIAL`**), run minimal `AT` / `ATI` **exchange** against a **real DCE** (modem on device). If env unset, **log skip** and **return success** so default CI does not fail. Optional **`EMBED_AT_BAUD`** (default e.g. 115200). |

On-embedded test binaries can reuse the same **Dte** surface with a board
`Transport` (UART to modem); the **serial** runner remains the usual choice for
**Mac DTE ↔ device DCE** smoke.

### Tests (same pattern as **`lib/bt`**)

- **`lib/at.zig`** exports **`at.test_runner.unit`** and **`at.test_runner.integration`** (like **`bt.test_runner`**).
- **`lib/tests.zig`** wires **`at/unit/std`**, **`at/unit/embed_std`**, **`at/integration/std`**, **`at/integration/embed_std`** through **`testing.T`** — mirror of **`bt/unit/…`** and **`bt/integration/…`**.
- **`test_runner/unit.zig`** registers leaf runners (**`Transport`**, **`LineReader`**, **`Session`**, **`Dte`**, **`Dce`**, **`dte_loopback`**); **`test_runner/integration.zig`** runs **`dte_loopback`** then **`dte_serial_host`**.

Run:

- **`zig build test-unit-at`** — unit runner (import / loopback surface smoke).
- **`zig build test-integration-at`** — loopback + serial host (serial skips if env unset).

Cases (under integration runner):

- **`dte_loopback`** — in-process **Dte** ↔ **Dce** (`test_runner/dte_loopback.zig`).
- **`dte_serial_host`** — POSIX serial **DTE** vs **ESP32-S3 DCE firmware** (`test_runner/dte_serial_host.zig`; not re-exported from `pub test_runner`).

Host serial uses **`EMBED_AT_SERIAL`** / **`EMBED_AT_BAUD`**; unset path → skip (success).

### What not to duplicate here

- **CMUX** tests and modem **profile** parsers stay under `lib/cellular` (or
  product trees).

## Build / module wiring

- Module: `build/lib/at.zig`, root `lib/at.zig`, registered as `at` in `build.zig`.
- Run **`zig build test-unit-at`** / **`zig build test-integration-at`** (or **`zig build test-unit`** / **`zig build test-integration`** for all libs).

### Production: UART or USB CDC

1. Implement **`at.Transport`** on your driver (**`read` / `write` / `flushRx` / `reset` / `deinit`**, plus read/write deadlines mapped to your RTOS / bare-metal timer).
2. Build **`Dte`**: `const D = at.Dte.make(board_lib, line_cap); var dte = D.init(at.Transport.init(&impl), .{});` then call **`exchange`**, **`writeRaw`**, **`readExact`** as needed.
3. **USB CDC-ACM** is still a **byte stream** after enumeration; only the **`Transport`** implementation changes, not **`Session`** / **`Dte`**.
4. **`Dce`** is for **tests / loopback mocks** (feed it lines from a fake RX queue, append replies to a fake TX queue), not for talking to a real modem on the wire.

## Next steps

1. **`Transport`** — Implemented: same core surface as `lib/bt/Transport.zig`,
   plus required **`flushRx`** (see layering below).
2. **`LineReader`** — Implemented (`lib/at/LineReader.zig`); see `LineTooLong` /
   `OutTooSmall` above.
3. **`Session`** — Implemented (`Session.make(lib, line_cap)`).
4. **`Dte`** — Implemented (`Dte.make(lib, line_cap)`).
5. **`Dce`** — Implemented (`handleLine`, `CommandEntry`, `respondCopy` helper).
6. **`test_runner/integration.zig`** (**`dte_loopback`** + **`dte_serial_host`**); **`lib/tests.zig`** exposes **`at/integration/std`** and **`at/integration/embed_std`** (see above).
7. Keep this README in sync with the public import path as APIs land.

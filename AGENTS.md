# AGENTS.md
Guidance for coding agents operating in this repository.
Scope: reliable Zig workflows, strict contracts, and behavior-first testing.

---

## 1) Repo snapshot
- Language: Zig (0.15.x in local environment).
- Main code roots:
  - `src/runtime/` (runtime contracts + std implementation)
  - `src/hal/` (hardware abstraction contracts)
  - `src/root.zig` (top-level exports)
- Architecture docs:
  - `openteam/docs/runtime.md`
  - `openteam/docs/hal.md`
  - `openteam/docs/structure.md`
  - `openteam/docs/test_strategy.md`
- No repository-level `build.zig` pipeline is present.
- Default workflow is `zig test <file>`.

## 2) Cursor/Copilot rule files
- Checked locations:
  - `.cursor/rules/`
  - `.cursorrules`
  - `.github/copilot-instructions.md`
- Current status: **none found**.
- If these files are added later, treat them as authoritative and update this file.

## 3) Build, lint, and test commands

### 3.1 Format
```bash
zig fmt src/**/*.zig
```
- If `**` is not expanded by your shell, run with explicit file paths.

### 3.2 Lint baseline
- No dedicated linter is configured.
- Required baseline = `zig fmt` + `zig test`.

### 3.3 Full runtime behavior suite
```bash
zig test src/runtime/std.zig
```
- Run this after runtime/std changes.

### 3.4 Single file tests
```bash
zig test src/runtime/socket.zig
zig test src/runtime/std/crypto/pki.zig
zig test src/hal/wifi.zig
```

### 3.5 Single test case (important)
```bash
zig test src/runtime/std.zig --test-filter "socket tcp loopback echo"
zig test src/runtime/std/crypto/hkdf.zig --test-filter "RFC5869"
```

### 3.6 Compile-only contract checks
- Contract files may report `All 0 tests passed`; still run them.
```bash
zig test src/runtime/profile.zig
zig test src/runtime/io.zig
zig test src/runtime/runtime.zig
zig test src/runtime/root.zig
zig test src/root.zig
```

## 4) Code style and architecture rules

### 4.1 Imports
- Put `const std = @import("std");` first when used.
- Then import local modules.
- Remove unused imports.

### 4.2 Formatting
- Always run `zig fmt` before handoff.
- Keep files focused by domain.

### 4.3 File/module organization
- Entry file name is `root.zig`.
- Runtime std implementation lives in `src/runtime/std/*`.
- Crypto algorithms live in `src/runtime/std/crypto/*`.
- Algorithm tests should live with algorithm files.

### 4.4 Naming
- File names: lowercase snake_case.
- Public types: PascalCase (`Socket`, `DnsServers`).
- Functions/methods: lowerCamelCase (`setNonBlocking`, `parseIpv4`).
- Tests: behavior-oriented names.

### 4.5 Types
- Use exact scalar types in contracts (`u32`, `u64`, `[]const u8`, `bool`).
- Avoid loose substitutes or inferred alternatives in contract surfaces.
- Prefer named shared types for semantic tuples.
  - Example: `runtime.netif.types.DnsServers { primary, secondary }`.

### 4.6 Contract checks (mandatory)
- Required functions: use exact signature checks with
  - `@as(*const fn(...), &Impl.method)`
- Do not rely on `@hasDecl` alone for required function checks.
- Optional modules: `@hasDecl` + strict `from(...)` validation when declared.
- Keep profile model as `minimal/threaded/evented` + declaration presence.

### 4.7 Error handling
- Do not silently swallow critical errors.
- Do not hide failures behind sentinel values.
- Map platform errors to contract-level errors explicitly.
- Avoid unnecessary `anyerror` for stable required APIs.

### 4.8 Layer boundaries
- `hal` must not depend on `runtime`.
- `runtime` may depend on `hal` contracts when needed.
- `pkg` (if present) may depend on both `runtime` and `hal`.

### 4.9 Runtime conventions
- IO contract remains unified: `registerRead/registerWrite/unregister/poll/wake`.
- Wake path should be non-blocking safe and drain logic robust.
- Socket error set should match real capabilities.
- OTA backend trait stays in `runtime/ota_backend.zig`; orchestration belongs above runtime.

## 5) Testing expectations for agents
- For every change, run:
  1. modified file tests
  2. affected aggregate suite
  3. top-level compile check
- For runtime std changes, always run:
  - `zig test src/runtime/std.zig`
- For crypto changes:
  - add/adjust vectors in the changed algorithm file
  - include positive + negative behavior tests where practical
- If a contract file has no runtime tests, still run `zig test` on it.

## 6) Commit hygiene
- Keep commits scoped and intention-revealing.
- Do not commit placeholders/stubs.
- Keep working tree clean except intended files.
- Sync docs when contracts/behavior change.

## 7) Pre-handoff checklist
- [ ] `zig fmt` executed
- [ ] relevant `zig test` commands passed
- [ ] strict contract checks preserved (signature + type)
- [ ] no TODO stubs or silent-failure regressions introduced

## 8) Quick command recap
```bash
zig fmt src/**/*.zig
zig test src/runtime/std.zig
zig test src/runtime/std.zig --test-filter "io wake drains buffered wake bytes"
zig test src/runtime/runtime.zig
zig test src/root.zig
```

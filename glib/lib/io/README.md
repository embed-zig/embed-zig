# lib/io

`lib/io` holds small Go-style I/O helpers that are useful across packages
without introducing another runtime interface layer.

This package intentionally stays on the helper/composition side. If an I/O
contract is specific to one subsystem, it should live with that subsystem
instead of being promoted into `lib/io` just because it reads or writes bytes.
For example, `http.ReadCloser` belongs under `net/http`, not here.

## Exports

```zig
const io = @import("io");

const BufferedReader = io.BufferedReader;
const BufferedWriter = io.BufferedWriter;
const PrefixReader = io.PrefixReader;
const readFull = io.readFull;
const readAll = io.readAll;
const copy = io.copy;
const copyBuf = io.copyBuf;
const writeAll = io.writeAll;
```

Today `lib/io` exports:

- `bufio.BufferedReader`
- `bufio.BufferedWriter`
- `io.PrefixReader`
- `io.readFull`
- `io.readAll`
- `io.copy`
- `io.copyBuf`
- `io.writeAll`

## Design rule

Add something to `lib/io` when it is:

- generic across multiple packages
- naturally expressed as a small helper or adapter
- not tied to one protocol or runtime contract

Keep it out of `lib/io` when it is:

- HTTP-specific, TLS-specific, or socket-specific
- a type-erased VTable contract owned by another subsystem
- only useful in one package

## Tests

`lib/io` exports unit coverage through `io.test_runner.unit`.

Implementation files that need unit tests export `TestRunner(comptime lib: type)`,
and `lib/io/test_runner/unit.zig` composes those runners for `lib/test.zig`.

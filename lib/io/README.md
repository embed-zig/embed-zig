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
const PrefixReader = io.PrefixReader;
```

Today `lib/io` exports:

- `bufio.BufferedReader`
- `io.PrefixReader`
- `io.readFull`
- `io.readAll`
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

`lib/io` keeps unit tests next to the implementation files:

- `io/unit_tests` imports `io/bufio.zig`
- `io/unit_tests` imports `io/io.zig`

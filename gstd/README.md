# gstd

`gstd` is the std-backed host runtime package for `glib`.

Its public surface is intentionally small: it exports one pre-instantiated
runtime namespace and does not re-export the underlying `stdz`, `sync`, or
`net` modules directly.

## Exports

```zig
const gstd = @import("gstd");
const runtime = gstd.runtime;
```

- `gstd.runtime` is `glib.runtime.make(...)` instantiated with the std-backed
  host implementations in this package
- the backing implementation code lives under `gstd/src/`
- `gstd` depends only on the `glib` package

## Notes

This package is the extraction target for the old std-backed runtime adapter
layer that previously lived under `internal/lib/embed_std`.


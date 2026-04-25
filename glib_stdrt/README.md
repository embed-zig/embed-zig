# glib_stdrt

`glib_stdrt` is the std-backed host runtime package for `glib`.

Its public surface is intentionally small: it exports one pre-instantiated
runtime namespace and does not re-export the underlying `stdz`, `sync`, or
`net` modules directly.

## Exports

```zig
const glib_stdrt = @import("glib_stdrt");
const runtime = glib_stdrt.runtime;
```

- `glib_stdrt.runtime` is `glib.runtime.make(...)` instantiated with the std-backed
  host implementations in this package
- the backing implementation code lives under `glib_stdrt/src/`
- `glib_stdrt` depends only on the `glib` package

## Notes

This package is the extraction target for the old std-backed runtime adapter
layer that previously lived under `internal/lib/embed_std`.


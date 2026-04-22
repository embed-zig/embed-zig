# lib/mime

`lib/mime` is the top-level MIME package for `embed-zig`.

It follows Go's package split: MIME parsing and formatting live in `mime`,
while HTTP-specific behavior stays under `net/http`.

## Current scope

Today the package centers on `MediaType` parsing and formatting:

```zig
const mime = @import("mime");

var params: [8]mime.MediaType.Parameter = undefined;
const mt = try mime.parse("text/plain; charset=utf-8", &params);
```

Exports:

- `mime.MediaType`
- `mime.parse(...)`
- `mime.format(...)`

`parse(...)` is buffer-driven: callers provide the parameter storage so the API
can stay explicit about allocation and capacity.

## Design rule

Put functionality in `lib/mime` when it is about MIME syntax or common content
metadata, for example:

- media type parsing
- media type formatting
- extension or content-type helpers

Keep protocol-specific policy in the higher-level package that owns it. For
example, HTTP header rules belong in `net/http` even when they use MIME types.

## Tests

`mime` keeps unit coverage next to `mime/MediaType.zig` through a file-local
`TestRunner`, then aggregates it via `mime.test_runner.unit` for the shared
test entrypoints.

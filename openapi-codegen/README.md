# openapi-codegen

[中文说明](README.zh-CN.md)

Comptime-first OpenAPI 3.x tooling for Zig: parse specs, then `**codegen.models**`, `**codegen.client**`, and `**codegen.server**` expand into real types and operation handles during compilation. Nothing writes a separate `generated.zig` to disk—the API lives in the type system.

## Requirements

- **Zig** ≥ `0.15.2` (see `build.zig.zon`)
- **[embed-zig](https://github.com/embed-zig/embed-zig)** as the runtime surface for generated client/server code. With `v1.1.0`, this repo uses top-level `embed` for module namespaces (`net`, `context`, `testing`, ...) and `embed_std.std` as the injected runtime `lib`.

## What you get


| Piece                             | Role                                                                                 |
| --------------------------------- | ------------------------------------------------------------------------------------ |
| `**openapi`** (`lib/openapi.zig`) | JSON parse → `Spec`; `Files` bundles one or more documents for `$ref` across layouts |
| `**codegen.models`**              | `codegen.models.make(files)` → schema-backed model types                             |
| `**codegen.client**`              | `codegen.client.make(lib, files)` → `ClientApi` with `operations.<operationId>`      |
| `**codegen.server**`              | `codegen.server.make(lib, files)` → strict handler registration                      |


Examples in this repo use `**const embed = @import("embed");**` for module namespaces and `**const lib = @import("embed_std").std;**` for the injected std-like runtime. Generated code calls `**embed.net**`, `**embed.context**`, `**embed.testing**`, while `**lib.mem**`, `**lib.json**`, `**lib.Thread**`, and friends come from `**embed_std.std**`.

## Clone and verify

```sh
zig build unit    # runtime/unit coverage (including SSE flush + ownership regressions)
zig build example # runs tests/examples/ (petstore, stream, sse)
zig build test    # runs unit + example + tests/oapi-codegen/ fixture suites
```

## Depend on the package

Your `build.zig.zon` should list `**openapi_codegen**` and `**embed_zig**`. Use `zig fetch --save` (or a `path` dependency) so tar URLs get a correct `**.hash**`.

Wire modules like this repository’s `build.zig`: create an `**openapi**` module rooted at `lib/openapi.zig`, then pass through `**embed_dep.module("embed")**` as `**embed**` and `**embed_dep.module("embed_std")**` as `**embed_std**`, then wire `**codegen**` with imports `**openapi**`, `**embed**`, and `**embed_std**`.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed_dep = b.dependency("embed_zig", .{ .target = target, .optimize = optimize });
    const og = b.dependency("openapi_codegen", .{ .target = target, .optimize = optimize });

    const openapi_mod = b.addModule("openapi", .{
        .root_source_file = og.path("lib/openapi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const embed_mod = embed_dep.module("embed");
    const embed_std_mod = embed_dep.module("embed_std");

    const codegen_mod = b.addModule("codegen", .{
        .root_source_file = og.path("lib/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
        },
    });

    const app = b.addModule("app", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "codegen", .module = codegen_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
        },
    });

    _ = app;
}
```

## Spec + `ClientApi` (petstore-style)

The petstore example uses **two JSON files**: paths in `service.json`, `components` in `structure.json`. Both must appear in `**openapi.Files`**. The following is adapted from `**tests/examples/petstore/test.zig`**.

```zig
const openapi = @import("openapi");
const codegen = @import("codegen");

const embed = @import("embed");
const lib = @import("embed_std").std;

const raw_service = @embedFile("service.json");
const raw_structure = @embedFile("structure.json");

fn files() openapi.Files {
    const service_spec = openapi.json.parse(raw_service);
    const structure_spec = openapi.json.parse(raw_structure);
    return .{
        .items = &.{
            .{ .name = "service.json", .spec = service_spec },
            .{ .name = "structure.json", .spec = structure_spec },
        },
    };
}

const ClientApi = codegen.client.make(lib, files());
const net = embed.net.make(lib);
```

For a single-file OpenAPI document, use one entry in `.items` and one `@embedFile` instead.

## Calling the generated client (petstore)

Full flow in `**tests/examples/petstore/test.zig**`: spin up `**ServerApi**`, listen on loopback, then build the HTTP stack and `**ClientApi**`. Below are the **client-only** pieces copied from that file.

**1. Transport + `ClientApi.init`**

```zig
var transport = try net.http.Transport.init(alloc, .{});
defer transport.deinit();
var http_client = try net.http.Client.init(alloc, .{
    .round_tripper = transport.roundTripper(),
});
defer http_client.deinit();

var api = try ClientApi.init(.{
    .allocator = alloc,
    .http_client = &http_client,
    .base_url = base_url,
});
defer api.deinit();
```

**2. Context for `send`**

`send` takes `**context.Context**` as the first argument. The example test uses the embed testing harness: `**t.context()**`. In ordinary code, create a background context the same way as `**tests/oapi-codegen/strict-server/test.zig**`:

```zig
var ctx_ns = try embed.context.make(lib).init(alloc);
defer ctx_ns.deinit();
const bg = ctx_ns.background();
// use `bg` wherever the example uses `t.context()`
```

**3. POST with JSON body (`addPet`)**

```zig
const resp = try api.operations.addPet.send(t.context(), alloc, .{
    .body = .{
        .name = "neo",
        .photoUrls = &.{"https://example.test/pets/100-a.png"},
    },
});
defer resp.deinit();
switch (resp.value) {
    .status_200 => |parsed| {
        _ = parsed.value.id.?;
        _ = parsed.value.name;
    },
    else => return error.UnexpectedCreateStatus,
}
```

**4. GET with path parameters (`getPetById`)**

Path template `/pet/{petId}` becomes `**.path = .{ .petId = pet_id }`** (field names come from the OpenAPI parameter names).

```zig
const resp = try api.operations.getPetById.send(t.context(), alloc, .{
    .path = .{ .petId = pet_id },
});
defer resp.deinit();
switch (resp.value) {
    .status_200 => |parsed| {
        _ = parsed.value.name;
    },
    else => return error.UnexpectedReadStatus,
}
```

**5. DELETE with path + optional header (`deletePet`)**

This operation shows `**.path`** together with `**.header`** (OpenAPI `in: header` / cookie-style bundles on `args`).

```zig
const resp = try api.operations.deletePet.send(t.context(), alloc, .{
    .path = .{ .petId = pet_id },
    .header = .{ .api_key = null },
});
defer resp.deinit();
switch (resp.value) {
    .status_204 => {},
    else => return error.UnexpectedDeleteStatus,
}
```

**Body types:** JSON requests still use typed Zig values on `.body`. For **non-JSON request bodies** (`text/plain`, `application/octet-stream`, etc.), pass a `**net.http.ReadCloser`** on `.body` so the client can upload as a stream; on the server side, raw handlers receive that same `ReadCloser` and should `read` it incrementally, then `close` it when done.

**Response shape:** `send` returns a pointer-like handle with a `.value` union keyed by status (e.g. `.status_200`, `.status_404`, `.status_204`). Always `defer resp.deinit()` after you are done. JSON arms hold parsed models and are still released by the outer response handle. **Non-JSON stream bodies** (`text/plain`, `application/octet-stream`, etc.) are a `**net.http.ReadCloser`**: call `read` in a loop, then `close()` that reader yourself before the outer `resp.deinit()`. `text/event-stream` responses return `codegen.sse.Reader`: consume events, then call `stream.deinit()` before the outer `resp.deinit()`. Model types for JSON bodies live on `ClientApi.models`.

## Acknowledgements

Fixtures under `**tests/oapi-codegen**` trace back to **[oapi-codegen](https://github.com/oapi-codegen/oapi-codegen)**. Thanks to that project’s authors for the reference behaviour and test corpus.
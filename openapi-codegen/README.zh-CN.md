# openapi-codegen

[English](README.md)

面向 Zig 的 **comptime OpenAPI 3.x** 方案：在编译期解析文档，通过 `**codegen.models**`、`**codegen.client**`、`**codegen.server**` 生成类型与操作入口，**不会**单独落盘 `generated.zig`——生成结果在类型系统里。

## 环境要求

- **Zig** ≥ `0.15.2`（见 `build.zig.zon`）
- **[embed-zig](https://github.com/embed-zig/embed-zig)**：提供生成 client/server 所需的运行时。本仓库在 `v1.1.0` 之后直接使用顶层 `embed` 作为模块命名空间（`net`、`context`、`testing` 等），并用 `embed_std.std` 作为注入的运行时 `lib`。

## 能力概览


| 模块                               | 作用                                                                                           |
| -------------------------------- | -------------------------------------------------------------------------------------------- |
| `**openapi**`（`lib/openapi.zig`） | JSON → `Spec`；`**Files**` 挂载多文档，支持跨文件 `**$ref**`                                             |
| `**codegen.models**`             | `**codegen.models.make(files)**` → schema 对应 model 类型                                        |
| `**codegen.client**`             | `**codegen.client.make(lib, files)**` → `**ClientApi**`，操作为 `**operations.<operationId>**`   |
| `**codegen.server**`             | `**codegen.server.make(lib, files)**` → 严格 handler 注册                                        |


示例里统一写 `**const embed = @import("embed");**` 和 `**const lib = @import("embed_std").std;**`。`**embed.net**`、`**embed.context**`、`**embed.testing**` 走顶层模块；`**lib.mem**`、`**lib.json**`、`**lib.Thread**` 等 std-like 能力来自 `**embed_std.std**`。

## 克隆后自测

```sh
zig build unit    # runtime/unit 覆盖（含 SSE flush 与 ownership 回归）
zig build example # 运行 tests/examples/（petstore、stream、sse）
zig build test    # 运行 unit + example + tests/oapi-codegen/ 夹具
```

## 在你自己的工程里依赖

在 `**build.zig.zon**` 声明 `**openapi_codegen**` 与 `**embed_zig**`；远端包用 `**zig fetch --save**` 写入 `**.hash**`。接线时先创建 `**openapi**` 模块，再直接透传 `**embed_dep.module("embed")**` 和 `**embed_dep.module("embed_std")**`，最后把它们传给 `**codegen**`。

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

## Spec + `ClientApi`（与 petstore 示例一致）

本仓库 `**tests/examples/petstore/test.zig**` 使用 **双文件**：`**service.json**` 管 paths，`**structure.json**` 管 `**components**`；`**openapi.Files**` 里两份都要列出。下面片段与示例文件一致（节选）。

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

若只有一份 OpenAPI JSON，`**.items**` 里放一条即可。

## 调用生成的 client（petstore）

完整流程（含 `**ServerApi**`、监听、线程）见 `**tests/examples/petstore/test.zig**`。这里只保留与 **client** 直接相关的写法，均来自该文件。

**1. `Transport` + `ClientApi.init`**

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

**2. `send` 的第一个参数：`context.Context`**

示例测试里使用 harness 的 `**t.context()**`。在普通程序里可像 `**tests/oapi-codegen/strict-server/test.zig**` 那样：

```zig
var ctx_ns = try embed.context.make(lib).init(alloc);
defer ctx_ns.deinit();
const bg = ctx_ns.background();
// 下面凡示例写 `t.context()` 的地方可换成 `bg`
```

**3. 带 JSON body 的 POST（`addPet`）**

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

**4. 带 path 参数的 GET（`getPetById`）**

OpenAPI 里 `/pet/{petId}` 对应参数名 `**petId**`，代码里写 `**.path = .{ .petId = pet_id }**`。

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

**5. 带 path + header 的 DELETE（`deletePet`）**

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

**请求体类型：** JSON 请求仍然直接传类型化的 `.body`。对于 **非 JSON 请求体**（`text/plain`、`application/octet-stream` 等），`.body` 需要传 **`net.http.ReadCloser`**，这样 client 会按流式上传；server 侧 raw handler 收到的也是这个 `ReadCloser`，应按需循环 `read`，并在完成后 `close`。

**响应类型：** `send` 返回带 `.value` 的句柄，按 HTTP 状态分支。用完后照常 `defer resp.deinit()`。**JSON** 分支是解析后的 model，仍由外层 response 句柄统一释放。**非 JSON 流式响应**（`text/plain`、`application/octet-stream` 等）分支是 **`net.http.ReadCloser`**：可循环 `read` 做流式读取（例如写入文件），但需要先由调用方自己 `close()`，再调用外层 `resp.deinit()`。`text/event-stream` 响应返回 `codegen.sse.Reader`：消费事件后先 `stream.deinit()`，再调用外层 `resp.deinit()`。JSON model 在 `ClientApi.models` 上。

## 致谢

`**tests/oapi-codegen**` 中的场景与数据源自 **[oapi-codegen](https://github.com/oapi-codegen/oapi-codegen)**。
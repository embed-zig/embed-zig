# oapi-codegen Fixtures

These fixtures come from [`oapi-codegen/oapi-codegen`](https://github.com/oapi-codegen/oapi-codegen), sourced from the upstream `internal/test/` tree.

Layout rules:

- Each leaf directory represents one upstream OpenAPI document.
- Each leaf directory contains `spec.json` and `test.zig`.
- The directory hierarchy follows the upstream test layout, except the leading `issues/` segment is omitted.
- Generic upstream filenames such as `spec.yaml` or `openapi.yaml` are normalized to `spec.json` inside the leaf directory.

See `oapi-codegen-spec-list.md` for the upstream source path and raw URL for every fixture.

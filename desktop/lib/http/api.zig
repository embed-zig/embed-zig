const gstd = @import("gstd");
const openapi = @import("openapi");
const codegen = @import("codegen");
const api_spec = @import("desktop_api_spec");

pub fn files() openapi.Files {
    const spec = openapi.json.parse(api_spec.raw_api);
    return .{
        .items = &.{
            .{
                .name = "api.json",
                .spec = spec,
            },
        },
    };
}

pub const Models = codegen.models.make(files());
pub const ServerApi = codegen.server.make(gstd.runtime.std, files());
pub const ClientApi = codegen.client.make(gstd.runtime.std, files());

const dep = @import("dep");
const openapi = @import("openapi");
const codegen = @import("codegen");
const api_spec = @import("desktop_api_spec");

const embed = dep.embed_std.std;
const raw_api = api_spec.raw_api;

pub fn files() openapi.Files {
    const spec = openapi.json.parse(raw_api);
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
pub const ServerApi = codegen.server.make(embed, files());
pub const ClientApi = codegen.client.make(embed, files());

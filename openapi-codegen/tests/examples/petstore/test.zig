const std = @import("std");
const context = embed.context;
const testing_api = embed.testing;
const net_mod = embed.net;
const openapi = @import("openapi");
const codegen = @import("codegen");

const embed = @import("embed");
const lib = @import("embed_std").std;

/// `service.json`: paths; `structure.json`: `components` (schemas, etc.). Cross-file `$ref` uses `structure.json#/components/...`. `deletePet` includes `204` on the service document.
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
const ServerApi = codegen.server.make(lib, files());

const net = embed.net.make(lib);

const pet_id: i64 = 100;

pub fn TestRunner() testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, runPetstoreExample);
}

fn runPetstoreExample(t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    var app = AppContext{};
    var server = try ServerApi.init(alloc, &app, .{
        .addPet = Handlers.addPet,
        .updatePet = Handlers.updatePet,
        .getPetById = Handlers.getPetById,
        .deletePet = Handlers.deletePet,
    });
    defer server.deinit();

    var srv_run = try startServer(&server);
    defer srv_run.stop(&server) catch {};

    const base_url = try lib.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{srv_run.port});
    defer alloc.free(base_url);

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

    const photo_a = "https://example.test/pets/100-a.png";
    const photo_b = "https://example.test/pets/100-b.png";

    // Create (POST /pet)
    {
        const resp = try api.operations.addPet.send(t.context(), alloc, .{
            .body = .{
                .name = "neo",
                .photoUrls = &.{photo_a},
            },
        });
        defer resp.deinit();
        switch (resp.value) {
            .status_200 => |parsed| {
                if (parsed.value.id.? != pet_id) return error.UnexpectedCreateId;
                if (!std.mem.eql(u8, parsed.value.name, "neo")) return error.UnexpectedCreateName;
            },
            else => return error.UnexpectedCreateStatus,
        }
    }

    // Read (GET /pet/{petId}) — `.path` = OpenAPI `in: path` args for `/pet/{petId}`.
    {
        const resp = try api.operations.getPetById.send(t.context(), alloc, .{
            .path = .{ .petId = pet_id },
        });
        defer resp.deinit();
        switch (resp.value) {
            .status_200 => |parsed| {
                if (!std.mem.eql(u8, parsed.value.name, "neo")) return error.UnexpectedReadName;
            },
            else => return error.UnexpectedReadStatus,
        }
    }

    // Update (PUT /pet)
    {
        const resp = try api.operations.updatePet.send(t.context(), alloc, .{
            .body = .{
                .id = pet_id,
                .name = "neo2",
                .photoUrls = &.{photo_b},
            },
        });
        defer resp.deinit();
        switch (resp.value) {
            .status_200 => |parsed| {
                if (!std.mem.eql(u8, parsed.value.name, "neo2")) return error.UnexpectedUpdateName;
            },
            else => return error.UnexpectedUpdateStatus,
        }
    }

    {
        const resp = try api.operations.getPetById.send(t.context(), alloc, .{
            .path = .{ .petId = pet_id },
        });
        defer resp.deinit();
        switch (resp.value) {
            .status_200 => |parsed| {
                if (!std.mem.eql(u8, parsed.value.name, "neo2")) return error.UnexpectedPostUpdateReadName;
            },
            else => return error.UnexpectedPostUpdateReadStatus,
        }
    }

    // Delete (DELETE /pet/{petId})
    {
        const resp = try api.operations.deletePet.send(t.context(), alloc, .{
            .path = .{ .petId = pet_id },
            .header = .{ .api_key = null },
        });
        defer resp.deinit();
        switch (resp.value) {
            .status_204 => {},
            else => return error.UnexpectedDeleteStatus,
        }
    }

    {
        const resp = try api.operations.getPetById.send(t.context(), alloc, .{
            .path = .{ .petId = pet_id },
        });
        defer resp.deinit();
        switch (resp.value) {
            .status_404 => {},
            else => return error.UnexpectedNotFoundStatus,
        }
    }
}

const AppContext = struct {
    pet: ?StoredPet = null,
    deleted: bool = false,

    const StoredPet = struct {
        id: i64,
        name: []const u8,
        photo_urls: []const []const u8,
    };
};

const Handlers = struct {
    fn addPet(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.addPet.Args,
    ) !ServerApi.operations.addPet.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;

        const id = args.body.id orelse pet_id;
        app.deleted = false;
        app.pet = .{
            .id = id,
            .name = args.body.name,
            .photo_urls = args.body.photoUrls,
        };
        return .{ .status_200 = petResponseFromBody(id, args.body) };
    }

    fn updatePet(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.updatePet.Args,
    ) !ServerApi.operations.updatePet.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;

        const b = args.body;
        const id = b.id orelse return error.MissingPetIdOnUpdate;
        if (app.pet == null or app.pet.?.id != id) {
            return .{ .status_404 = {} };
        }
        app.pet = .{
            .id = id,
            .name = b.name,
            .photo_urls = b.photoUrls,
        };
        return .{ .status_200 = petResponseFromBody(id, b) };
    }

    fn getPetById(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.getPetById.Args,
    ) !ServerApi.operations.getPetById.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;

        if (app.deleted or app.pet == null or app.pet.?.id != args.path.petId) {
            return .{ .status_404 = {} };
        }
        const p = app.pet.?;
        return .{ .status_200 = .{
            .id = p.id,
            .name = p.name,
            .category = null,
            .photoUrls = p.photo_urls,
            .tags = null,
            .status = null,
        } };
    }

    fn deletePet(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.deletePet.Args,
    ) !ServerApi.operations.deletePet.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;

        if (app.pet == null or app.pet.?.id != args.path.petId) {
            return .{ .status_400 = {} };
        }
        app.deleted = true;
        return .{ .status_204 = {} };
    }

    fn petResponseFromBody(id: i64, body: ServerApi.models.Pet) ServerApi.models.Pet {
        return .{
            .id = id,
            .name = body.name,
            .category = body.category,
            .photoUrls = body.photoUrls,
            .tags = body.tags,
            .status = body.status,
        };
    }
};

const ServerRun = struct {
    listener: net_mod.Listener,
    port: u16,
    server_err: ?anyerror = null,
    thread: lib.Thread,

    fn stop(self: *@This(), server: *ServerApi) !void {
        self.listener.close();
        server.close();
        self.thread.join();
        defer self.listener.deinit();
        if (self.server_err) |err| {
            if (err != error.ServerClosed) return err;
        }
    }
};

fn startServer(server: *ServerApi) !ServerRun {
    const listener = try net.listen(server.shared.allocator, .{
        .address = net_mod.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
    });
    const tcp_listener = try listener.as(net.TcpListener);
    const port = try tcp_listener.port();

    var srv_run = ServerRun{
        .listener = listener,
        .port = port,
        .thread = undefined,
    };
    srv_run.thread = try lib.Thread.spawn(.{}, struct {
        fn exec(s: *ServerApi, ln: net_mod.Listener, err: *?anyerror) void {
            s.serve(ln) catch |serve_err| {
                err.* = serve_err;
            };
        }
    }.exec, .{ server, listener, &srv_run.server_err });
    return srv_run;
}

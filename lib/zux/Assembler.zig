const LedStrip = @import("ledstrip");
const Store = @import("store.zig");
const PipelineNodeBuilder = @import("pipeline/NodeBuilder.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime config: anytype) type {
    const StoreBuilder = Store.Builder(.{});
    const NodeBuilder = PipelineNodeBuilder.Builder(.{});

    return struct {
        const Self = @This();

        pub const Lib = lib;
        pub const Config = config;
        pub const StoreBuilderType = StoreBuilder;
        pub const NodeBuilderType = NodeBuilder;

        fn addBtHost(comptime id: u32, comptime Host: type) void {
            _ = Host;
            _ = id;
            @compileError("zux.Assembler.addBtHost is not implemented yet");
        }

        pub const LedStripOptions = struct {
            pixel_count: usize,
            max_frames: usize = 16,
        };

        pub const LedStripShape = struct {
            AnimatorType: type,
            reducer_store_label: []const u8,
            reducer_state_path: []const u8,
            refresh_store_label: []const u8,
        };

        pub fn ledStripShape(comptime id: u32, comptime Strip: type, comptime options: LedStripOptions) LedStripShape {
            _ = Strip;
            _ = id;
            return .{
                .AnimatorType = LedStrip.Animator.make(options.pixel_count, options.max_frames),
                .reducer_store_label = "ledstrip",
                .reducer_state_path = "ledstrip",
                .refresh_store_label = "ledstrip",
            };
        }

        pub fn addLedStrip(comptime id: u32, comptime Strip: type, comptime options: LedStripOptions) void {
            const shape = ledStripShape(id, Strip, options);
            _ = shape;
            @compileError("zux.Assembler.addLedStrip is not implemented yet");
        }

        pub fn build(comptime build_config: anytype) type {
            _ = build_config;
            @compileError("zux.Assembler.build is not implemented yet");
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn exposesPlannedShape(testing: anytype) !void {
            const TestLib = struct {};

            const AssType = make(TestLib, .{});

            try testing.expect(@TypeOf(AssType) == type);
            try testing.expect(@hasDecl(AssType, "Lib"));
            try testing.expect(@hasDecl(AssType, "Config"));
            try testing.expect(@hasDecl(AssType, "StoreBuilderType"));
            try testing.expect(@hasDecl(AssType, "NodeBuilderType"));
            try testing.expect(@hasDecl(AssType, "LedStripOptions"));
            try testing.expect(@hasDecl(AssType, "LedStripShape"));
            try testing.expect(@hasDecl(AssType, "build"));
            try testing.expect(@hasDecl(AssType, "addLedStrip"));
        }

        fn addLedStripShapeDescribesAnimatorStoreNodeAndRefreshIntent(testing: anytype) !void {
            const TestLib = struct {};

            const AssType = make(TestLib, .{});
            const shape = AssType.ledStripShape(7, LedStrip, .{
                .pixel_count = 24,
                .max_frames = 8,
            });

            try testing.expect(shape.AnimatorType == LedStrip.Animator.make(24, 8));
            try testing.expectEqualStrings("ledstrip", shape.reducer_store_label);
            try testing.expectEqualStrings("ledstrip", shape.reducer_state_path);
            try testing.expectEqualStrings("ledstrip", shape.refresh_store_label);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.exposesPlannedShape(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.addLedStripShapeDescribesAnimatorStoreNodeAndRefreshIntent(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

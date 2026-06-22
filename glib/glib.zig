//! glib — application runtime namespace assembled at comptime.
//!
//! `glib.runtime.make(...)` does not own platform behavior. It binds
//! already-selected platform capabilities into one application-facing
//! namespace.

const stdz_mod = @import("stdz");
const context_mod = @import("context");
const context_facade = @import("lib/context/facade.zig");
const testing_mod = @import("testing");
const time_mod = @import("time");
const system_mod = @import("glib_system");
const tests_mod = @import("lib/tests.zig");

pub const Time = time_mod.Time;

pub const std = struct {
    pub const ascii = stdz_mod.ascii;
    pub const crypto = stdz_mod.crypto;
    pub const fmt = stdz_mod.fmt;
    pub const heap = stdz_mod.heap;
    pub const Io = stdz_mod.Io;
    pub const json = stdz_mod.json;
    pub const log = stdz_mod.log;
    pub const mem = stdz_mod.mem;
    pub const posix = stdz_mod.posix;
    pub const Random = stdz_mod.Random;
    pub const Thread = stdz_mod.Thread;
    pub const math = stdz_mod.math;
    pub const debug = stdz_mod.debug;
    pub const meta = stdz_mod.meta;
    pub const atomic = stdz_mod.atomic;
    pub const builtin = stdz_mod.builtin;
    pub const testing = stdz_mod.testing;

    pub const array_list = stdz_mod.array_list;
    pub const ArrayList = stdz_mod.ArrayList;
    pub const ArrayListAligned = stdz_mod.ArrayListAligned;
    pub const ArrayListAlignedUnmanaged = stdz_mod.ArrayListAlignedUnmanaged;
    pub const ArrayListUnmanaged = stdz_mod.ArrayListUnmanaged;

    pub const MultiArrayList = stdz_mod.MultiArrayList;
    pub const SegmentedList = stdz_mod.SegmentedList;

    pub const hash_map = stdz_mod.hash_map;
    pub const HashMap = stdz_mod.HashMap;
    pub const HashMapUnmanaged = stdz_mod.HashMapUnmanaged;
    pub const AutoHashMap = stdz_mod.AutoHashMap;
    pub const AutoHashMapUnmanaged = stdz_mod.AutoHashMapUnmanaged;
    pub const StringHashMap = stdz_mod.StringHashMap;
    pub const StringHashMapUnmanaged = stdz_mod.StringHashMapUnmanaged;

    pub const array_hash_map = stdz_mod.array_hash_map;
    pub const ArrayHashMap = stdz_mod.ArrayHashMap;
    pub const ArrayHashMapUnmanaged = stdz_mod.ArrayHashMapUnmanaged;
    pub const AutoArrayHashMap = stdz_mod.AutoArrayHashMap;
    pub const AutoArrayHashMapUnmanaged = stdz_mod.AutoArrayHashMapUnmanaged;
    pub const StringArrayHashMap = stdz_mod.StringArrayHashMap;
    pub const StringArrayHashMapUnmanaged = stdz_mod.StringArrayHashMapUnmanaged;

    pub const BufMap = stdz_mod.BufMap;
    pub const BufSet = stdz_mod.BufSet;

    pub const PriorityQueue = stdz_mod.PriorityQueue;
    pub const PriorityDequeue = stdz_mod.PriorityDequeue;

    pub const bit_set = stdz_mod.bit_set;
    pub const StaticBitSet = stdz_mod.StaticBitSet;
    pub const DynamicBitSet = stdz_mod.DynamicBitSet;
    pub const DynamicBitSetUnmanaged = stdz_mod.DynamicBitSetUnmanaged;

    pub const DoublyLinkedList = stdz_mod.DoublyLinkedList;
    pub const SinglyLinkedList = stdz_mod.SinglyLinkedList;

    pub const Treap = stdz_mod.Treap;

    pub const enums = stdz_mod.enums;
    pub const EnumArray = stdz_mod.EnumArray;
    pub const EnumMap = stdz_mod.EnumMap;
    pub const EnumSet = stdz_mod.EnumSet;

    pub const static_string_map = stdz_mod.static_string_map;
    pub const StaticStringMap = stdz_mod.StaticStringMap;
    pub const StaticStringMapWithEql = stdz_mod.StaticStringMapWithEql;

    pub const BitStack = stdz_mod.BitStack;

    pub fn make(comptime Impl: type) type {
        return stdz_mod.make(Impl);
    }

    pub const test_runner = tests_mod.std;
};
pub const testing = struct {
    pub const std = testing_mod.std;
    pub const T = testing_mod.T;
    pub const TestingAllocator = testing_mod.TestingAllocator;
    pub const CountingAllocator = testing_mod.CountingAllocator;
    pub const LimitAllocator = testing_mod.LimitAllocator;
    pub const TestRunner = testing_mod.TestRunner;

    pub const test_runner = tests_mod.testing;
};
pub const context = struct {
    pub const Context = context_mod.Context;
    pub const make = context_facade.make;

    pub const test_runner = tests_mod.context;
};
pub const time = struct {
    pub const duration = time_mod.duration;
    pub const instant = time_mod.instant;
    pub const sleep = time_mod.sleep;
    pub const wall = time_mod.wall;
    pub const Time = time_mod.Time;
    pub const unix = time_mod.unix;
    pub const fromUnixMilli = time_mod.fromUnixMilli;
    pub const fromUnixMicro = time_mod.fromUnixMicro;
    pub const fromUnixNano = time_mod.fromUnixNano;

    pub fn make(comptime Impl: type) type {
        return time_mod.make(Impl);
    }

    pub const test_runner = tests_mod.time;
};
pub const system = struct {
    pub const cpu = system_mod.cpu;
    pub const CpuCountError = system_mod.CpuCountError;

    pub fn make(comptime Impl: type) type {
        return system_mod.make(Impl);
    }

    pub const test_runner = tests_mod.system;
};
pub const sync = @import("sync");
pub const task = @import("task");
pub const io = @import("io");
pub const encoding = @import("encoding");
pub const mime = @import("mime");
pub const net = @import("net");
pub const path = @import("path");
pub const fs = @import("fs");
pub const compress = @import("compress");
pub const archive = @import("archive");
pub const crypto = @import("crypto");
pub const runtime = struct {
    const Runtime = @This();
    const TypeMarker = struct {};
    pub const Options = struct {
        stdz_impl: type,
        time_impl: type,
        system_impl: type,
        sync_impl: type,
        channel_factory: @import("sync").channel.FactoryType,
        net_impl: type,
        fs_impl: type,
        task_impl: type = void,
        compress_impl: type = void,
    };

    pub fn make(comptime options: Options) type {
        const runtime_std_raw = @import("stdz").make(options.stdz_impl);
        const runtime_time = @import("time").make(options.time_impl);
        const runtime_system = @import("glib_system").make(options.system_impl);
        const runtime_sync = options.sync_impl;
        const channel_factory = options.channel_factory;
        const fs_impl = options.fs_impl;

        return struct {
            const Self = @This();
            const runtime_marker: TypeMarker = .{};
            pub const runtime = Runtime;
            pub const task = if (options.task_impl == void) void else options.task_impl.make(Self);
            pub const std = stdWithoutThreadSleep(runtime_std_raw, runtime_sync, Self.task);
            pub const time = runtime_time;
            pub const system = runtime_system;
            pub const sync = struct {
                pub const Arc = @import("sync").Arc;
                pub const Mutex = @import("sync").Mutex.make(runtime_sync.Mutex);
                pub const Condition = @import("sync").Condition.make(runtime_sync.Condition);
                pub const RwLock = @import("sync").RwLock.make(runtime_sync.RwLock);
                pub const ChannelFactory = channel_factory;
                pub const Channel = @import("sync").Channel(Self.std, channel_factory);

                pub fn Racer(comptime T: type) type {
                    return @import("sync").RacerWithTask(Self.std, runtime_time, @This(), Self.task, T);
                }
            };
            pub const context = @import("context").makeWithTask(Self.std, runtime_time, Self.sync, Self.task);
            pub const net = @import("net").makeWithTask(Self.std, runtime_time, Self.sync, Self.task, options.net_impl);
            pub const fs = @import("fs").make(Self.std, fs_impl);
            pub const compress = if (options.compress_impl == void) void else @import("compress").make(Self.std, options.compress_impl);
        };
    }

    pub fn is(comptime ns: type) bool {
        switch (@typeInfo(ns)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => {},
            else => return false,
        }
        if (!@hasDecl(ns, "runtime_marker")) return false;
        return @TypeOf(ns.runtime_marker) == TypeMarker;
    }

    fn stdWithoutThreadSleep(comptime RawStd: type, comptime SyncImpl: type, comptime Task: type) type {
        return struct {
            pub const heap = RawStd.heap;
            pub const Thread = RemovedThreadNamespace;
            pub const task = Task;
            pub const sync = struct {
                pub const Mutex = @import("sync").Mutex.make(SyncImpl.Mutex);
                pub const Condition = @import("sync").Condition.make(SyncImpl.Condition);
                pub const RwLock = @import("sync").RwLock.make(SyncImpl.RwLock);
            };
            pub const log = RawStd.log;
            pub const posix = RawStd.posix;
            pub const ascii = RawStd.ascii;
            pub const mem = RawStd.mem;
            pub const fmt = RawStd.fmt;
            pub const json = RawStd.json;
            pub const meta = RawStd.meta;
            pub const Io = RawStd.Io;
            pub const debug = RawStd.debug;
            pub const atomic = RawStd.atomic;
            pub const base64 = RawStd.base64;
            pub const builtin = RawStd.builtin;
            pub const testing = RawStd.testing;
            pub const Random = RawStd.Random;
            pub const crypto = RawStd.crypto;
            pub const math = RawStd.math;

            pub const array_list = RawStd.array_list;
            pub const ArrayList = RawStd.ArrayList;
            pub const ArrayListAligned = RawStd.ArrayListAligned;
            pub const ArrayListAlignedUnmanaged = RawStd.ArrayListAlignedUnmanaged;
            pub const ArrayListUnmanaged = RawStd.ArrayListUnmanaged;

            pub const MultiArrayList = RawStd.MultiArrayList;
            pub const SegmentedList = RawStd.SegmentedList;

            pub const hash_map = RawStd.hash_map;
            pub const HashMap = RawStd.HashMap;
            pub const HashMapUnmanaged = RawStd.HashMapUnmanaged;
            pub const AutoHashMap = RawStd.AutoHashMap;
            pub const AutoHashMapUnmanaged = RawStd.AutoHashMapUnmanaged;
            pub const StringHashMap = RawStd.StringHashMap;
            pub const StringHashMapUnmanaged = RawStd.StringHashMapUnmanaged;

            pub const array_hash_map = RawStd.array_hash_map;
            pub const ArrayHashMap = RawStd.ArrayHashMap;
            pub const ArrayHashMapUnmanaged = RawStd.ArrayHashMapUnmanaged;
            pub const AutoArrayHashMap = RawStd.AutoArrayHashMap;
            pub const AutoArrayHashMapUnmanaged = RawStd.AutoArrayHashMapUnmanaged;
            pub const StringArrayHashMap = RawStd.StringArrayHashMap;
            pub const StringArrayHashMapUnmanaged = RawStd.StringArrayHashMapUnmanaged;

            pub const BufMap = RawStd.BufMap;
            pub const BufSet = RawStd.BufSet;

            pub const PriorityQueue = RawStd.PriorityQueue;
            pub const PriorityDequeue = RawStd.PriorityDequeue;

            pub const bit_set = RawStd.bit_set;
            pub const StaticBitSet = RawStd.StaticBitSet;
            pub const DynamicBitSet = RawStd.DynamicBitSet;
            pub const DynamicBitSetUnmanaged = RawStd.DynamicBitSetUnmanaged;

            pub const DoublyLinkedList = RawStd.DoublyLinkedList;
            pub const SinglyLinkedList = RawStd.SinglyLinkedList;

            pub const Treap = RawStd.Treap;

            pub const enums = RawStd.enums;
            pub const EnumArray = RawStd.EnumArray;
            pub const EnumMap = RawStd.EnumMap;
            pub const EnumSet = RawStd.EnumSet;

            pub const static_string_map = RawStd.static_string_map;
            pub const StaticStringMap = RawStd.StaticStringMap;
            pub const StaticStringMapWithEql = RawStd.StaticStringMapWithEql;

            pub const BitStack = RawStd.BitStack;
        };
    }

    const RemovedThreadNamespace = struct {
        pub const removed_thread_guardrail = true;
        pub const SpawnConfig = RemovedThreadMember("SpawnConfig", "grt.task.Options");
        pub const SpawnError = RemovedThreadMember("SpawnError", "the selected grt.task.SpawnError");
        pub const Mutex = RemovedThreadMember("Mutex", "grt.sync.Mutex");
        pub const Condition = RemovedThreadMember("Condition", "grt.sync.Condition");
        pub const RwLock = RemovedThreadMember("RwLock", "grt.sync.RwLock");

        pub fn spawn(_: anytype, comptime _: anytype, _: anytype) void {
            @compileError("grt.std.Thread.spawn is removed; use grt.task.go");
        }

        pub fn sleep(_: u64) void {
            @compileError("grt.std.Thread.sleep is removed; use grt.time.sleep or grt.time.sleepMillis");
        }

        pub fn getCurrentId() void {
            @compileError("grt.std.Thread.getCurrentId is removed; use explicit task-owned state");
        }

        pub fn getCpuCount() void {
            @compileError("grt.std.Thread.getCpuCount is removed; use grt.system.cpuCount");
        }
    };

    fn RemovedThreadMember(comptime name: []const u8, comptime replacement: []const u8) type {
        return struct {
            comptime {
                @compileError("grt.std.Thread." ++ name ++ " is removed; use " ++ replacement);
            }
        };
    }
};

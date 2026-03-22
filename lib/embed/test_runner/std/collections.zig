const std = @import("std");
const mem = std.mem;

pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.collections);
    const allocator = std.testing.allocator;

    {
        var list: lib.ArrayList(u32) = .empty;
        defer list.deinit(allocator);
        try list.append(allocator, 10);
        try list.append(allocator, 20);
        try list.append(allocator, 30);
        if (list.items.len != 3) return error.ArrayListLenWrong;
        if (list.items[0] != 10 or list.items[2] != 30) return error.ArrayListValueWrong;
        _ = list.orderedRemove(1);
        if (list.items.len != 2) return error.ArrayListRemoveFailed;
        if (list.items[1] != 30) return error.ArrayListRemoveShiftWrong;
        log.info("ArrayList: append+remove ok, len={}", .{list.items.len});
    }

    {
        var map = lib.AutoHashMap(u32, []const u8).init(allocator);
        defer map.deinit();
        try map.put(1, "one");
        try map.put(2, "two");
        try map.put(3, "three");
        if (map.count() != 3) return error.HashMapCountWrong;
        const val = map.get(2) orelse return error.HashMapGetFailed;
        if (!mem.eql(u8, val, "two")) return error.HashMapValueWrong;
        _ = map.remove(2);
        if (map.get(2) != null) return error.HashMapRemoveFailed;
        log.info("AutoHashMap: put+get+remove ok, count={}", .{map.count()});
    }

    {
        var map = lib.StringHashMap(i32).init(allocator);
        defer map.deinit();
        try map.put("alpha", 1);
        try map.put("beta", 2);
        if (map.get("alpha") != 1) return error.StringHashMapGetFailed;
        if (!map.contains("beta")) return error.StringHashMapContainsFailed;
        log.info("StringHashMap: put+get+contains ok", .{});
    }

    {
        var map = lib.AutoArrayHashMap(u32, u32).init(allocator);
        defer map.deinit();
        try map.put(100, 1);
        try map.put(200, 2);
        try map.put(300, 3);
        const keys = map.keys();
        if (keys.len != 3) return error.ArrayHashMapKeysWrong;
        if (keys[0] != 100 or keys[2] != 300) return error.ArrayHashMapOrderWrong;
        log.info("AutoArrayHashMap: insertion-order keys ok, len={}", .{keys.len});
    }

    {
        var map = lib.BufMap.init(allocator);
        defer map.deinit();
        try map.put("host", "localhost");
        try map.put("port", "8080");
        if (map.count() != 2) return error.BufMapCountWrong;
        const host = map.get("host") orelse return error.BufMapGetFailed;
        if (!mem.eql(u8, host, "localhost")) return error.BufMapValueWrong;
        try map.put("host", "0.0.0.0");
        const updated = map.get("host") orelse return error.BufMapGetFailed2;
        if (!mem.eql(u8, updated, "0.0.0.0")) return error.BufMapUpdateFailed;
        map.remove("port");
        if (map.get("port") != null) return error.BufMapRemoveFailed;
        log.info("BufMap: put+get+update+remove ok, count={}", .{map.count()});
    }

    {
        var set = lib.BufSet.init(allocator);
        defer set.deinit();
        try set.insert("hello");
        try set.insert("world");
        try set.insert("hello");
        if (set.count() != 2) return error.BufSetCountWrong;
        if (!set.contains("hello")) return error.BufSetContainsFailed;
        set.remove("hello");
        if (set.contains("hello")) return error.BufSetRemoveFailed;
        log.info("BufSet: insert+contains+remove ok, count={}", .{set.count()});
    }

    {
        var pq = lib.PriorityQueue(u32, void, struct {
            fn cmp(_: void, a: u32, b: u32) std.math.Order {
                return std.math.order(a, b);
            }
        }.cmp).init(allocator, {});
        defer pq.deinit();
        try pq.add(30);
        try pq.add(10);
        try pq.add(20);
        if (pq.count() != 3) return error.PQCountWrong;
        const min = pq.remove();
        if (min != 10) return error.PQMinWrong;
        log.info("PriorityQueue: add+remove min={}, remaining={}", .{ min, pq.count() });
    }

    {
        var bs = try lib.DynamicBitSet.initEmpty(allocator, 64);
        defer bs.deinit();
        bs.set(0);
        bs.set(31);
        bs.set(63);
        if (bs.count() != 3) return error.DynBitSetCountWrong;
        if (!bs.isSet(31)) return error.DynBitSetIsSetFailed;
        bs.unset(31);
        if (bs.isSet(31)) return error.DynBitSetUnsetFailed;
        log.info("DynamicBitSet: set+unset+count ok, count={}", .{bs.count()});
    }

    {
        var bs = lib.StaticBitSet(128).initEmpty();
        bs.set(0);
        bs.set(64);
        bs.set(127);
        if (bs.count() != 3) return error.StaticBitSetCountWrong;
        bs.toggle(64);
        if (bs.isSet(64)) return error.StaticBitSetToggleFailed;
        log.info("StaticBitSet: set+toggle+count ok", .{});
    }

    {
        const DLL = lib.DoublyLinkedList;
        var list = DLL{};
        var n1 = DLL.Node{};
        var n2 = DLL.Node{};
        var n3 = DLL.Node{};
        list.append(&n1);
        list.append(&n2);
        list.append(&n3);
        if (list.len() != 3) return error.DLLLenWrong;
        list.remove(&n2);
        if (list.len() != 2) return error.DLLRemoveFailed;
        if (list.first != &n1 or list.last != &n3) return error.DLLOrderWrong;
        log.info("DoublyLinkedList: append+remove ok, len={}", .{list.len()});
    }

    {
        const SLL = lib.SinglyLinkedList;
        var list = SLL{};
        var n1 = SLL.Node{};
        var n2 = SLL.Node{};
        var n3 = SLL.Node{};
        list.prepend(&n3);
        list.prepend(&n2);
        list.prepend(&n1);
        if (list.len() != 3) return error.SLLLenWrong;
        if (list.first != &n1) return error.SLLOrderWrong;
        _ = list.popFirst();
        if (list.first != &n2) return error.SLLPopFailed;
        log.info("SinglyLinkedList: prepend+popFirst ok, len={}", .{list.len()});
    }

    {
        const Color = enum { red, green, blue };
        var arr = lib.EnumArray(Color, u32).initFill(0);
        arr.set(.red, 10);
        arr.set(.blue, 30);
        if (arr.get(.red) != 10) return error.EnumArrayGetWrong;
        if (arr.get(.green) != 0) return error.EnumArrayDefaultWrong;
        if (arr.get(.blue) != 30) return error.EnumArrayGetWrong2;
        log.info("EnumArray: set+get ok", .{});
    }

    {
        const Fruit = enum { apple, banana, cherry, date };
        var set = lib.EnumSet(Fruit).initEmpty();
        set.insert(.apple);
        set.insert(.cherry);
        if (set.count() != 2) return error.EnumSetCountWrong;
        if (!set.contains(.apple)) return error.EnumSetContainsFailed;
        set.remove(.apple);
        if (set.contains(.apple)) return error.EnumSetRemoveFailed;
        log.info("EnumSet: insert+contains+remove ok", .{});
    }

    {
        const map = lib.StaticStringMap(u32).initComptime(.{
            .{ "foo", 1 },
            .{ "bar", 2 },
            .{ "baz", 3 },
        });
        if ((map.get("foo") orelse return error.SSMGetFailed) != 1) return error.SSMValueWrong;
        if ((map.get("baz") orelse return error.SSMGetFailed2) != 3) return error.SSMValueWrong2;
        if (map.get("missing") != null) return error.SSMMissingShouldBeNull;
        log.info("StaticStringMap: initComptime+get ok", .{});
    }

    {
        const Item = struct { x: u32, y: f32 };
        var mal = lib.MultiArrayList(Item){};
        defer mal.deinit(allocator);
        try mal.append(allocator, .{ .x = 1, .y = 1.0 });
        try mal.append(allocator, .{ .x = 2, .y = 2.0 });
        try mal.append(allocator, .{ .x = 3, .y = 3.0 });
        if (mal.len != 3) return error.MALLenWrong;
        const xs = mal.items(.x);
        if (xs[0] != 1 or xs[2] != 3) return error.MALSliceWrong;
        log.info("MultiArrayList: append+items ok, len={}", .{mal.len});
    }

    {
        var bs = lib.BitStack.init(allocator);
        defer bs.deinit();
        try bs.push(1);
        try bs.push(0);
        try bs.push(1);
        const top = bs.pop();
        if (top != 1) return error.BitStackPopWrong;
        const next = bs.peek();
        if (next != 0) return error.BitStackPeekWrong;
        log.info("BitStack: push+pop+peek ok", .{});
    }

    log.info("collections done", .{});
}

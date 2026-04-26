//! CBCentral — bt.Central implementation via Apple CoreBluetooth.
//!
//! Bridges CBCentralManager + CBPeripheral to the bt.Central VTable.
//! Uses raw Objective-C runtime calls (objc_msgSend) and a dynamically
//! created delegate class to receive async callbacks. A dispatch queue
//! delivers delegate callbacks; Mutex+Condition blocks the caller until
//! each operation completes.

const std = @import("std");
const bt = @import("bt");
const Central = bt.Central;
const objc = @import("objc.zig");
const Allocator = std.mem.Allocator;

const CBCentral = @This();

allocator: Allocator,
queue_label: [*:0]const u8,
manager: ?objc.Id = null,
delegate: ?objc.Id = null,
queue: ?objc.dispatch_queue_t = null,
state: Central.State = .idle,
powered_on: bool = false,
state_known: bool = false,
started: bool = false,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
operation_done: bool = false,
op_error: ?OpError = null,

peripherals: std.ArrayListUnmanaged(PeripheralSlot) = .{},
next_handle: u16 = 1,

svc_out: ?[]Central.DiscoveredService = null,
svc_count: usize = 0,
char_out: ?[]Central.DiscoveredChar = null,
char_count: usize = 0,
read_buf: ?[]u8 = null,
read_len: usize = 0,

hooks: std.ArrayListUnmanaged(EventHook) = .{},

const OpError = enum { att, timeout, disconnected, unexpected };

const EventHook = struct {
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Central.Event) void,
};

const PeripheralSlot = struct {
    handle: u16 = 0,
    peripheral: ?objc.Id = null,
    addr: Central.BdAddr = .{0} ** 6,
};

// ---- lifecycle ----

pub const Config = struct {
    queue_label: [*:0]const u8 = "com.embed.bt.central",
};

pub fn init(allocator: Allocator, config: Config) CBCentral {
    return .{ .allocator = allocator, .queue_label = config.queue_label };
}

pub const StartError = error{BluetoothUnavailable};

pub fn start(self: *CBCentral) StartError!void {
    if (self.started) return;

    self.queue = objc.createSerialQueue(self.queue_label);

    const delegate_cls = ensureDelegateClass();
    self.delegate = objc.msgSend(objc.Id, objc.alloc(delegate_cls), objc.sel("init"), .{});
    objc.setIvar(self.delegate.?, "zig_ptr", @ptrCast(self));

    self.manager = objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBCentralManager")), objc.sel("initWithDelegate:queue:"), .{
        self.delegate.?,
        @as(*anyopaque, self.queue.?),
    });

    self.started = true;

    self.mutex.lock();
    defer self.mutex.unlock();
    while (!self.state_known) {
        self.cond.wait(&self.mutex);
    }
    if (!self.powered_on) return error.BluetoothUnavailable;
}

pub fn stop(self: *CBCentral) void {
    if (!self.started) return;
    if (self.state == .scanning) self.stopScanning();

    self.mutex.lock();
    const snapshot = self.allocator.dupe(PeripheralSlot, self.peripherals.items) catch &.{};
    self.peripherals.shrinkRetainingCapacity(0);
    self.started = false;
    self.powered_on = false;
    self.state_known = false;
    self.state = .idle;
    self.mutex.unlock();
    defer self.allocator.free(snapshot);

    for (snapshot) |slot| {
        if (slot.peripheral) |peripheral| {
            objc.msgSend(void, self.manager.?, objc.sel("cancelPeripheralConnection:"), .{peripheral});
            objc.release(peripheral);
        }
    }
    objc.release(self.manager.?);
    objc.release(self.delegate.?);
    objc.releaseQueue(self.queue.?);
    self.manager = null;
    self.delegate = null;
    self.queue = null;
}

pub fn deinit(self: *CBCentral) void {
    self.stop();
    self.peripherals.deinit(self.allocator);
    self.hooks.deinit(self.allocator);
    const alloc = self.allocator;
    self.* = undefined;
    alloc.destroy(self);
}

// ---- scan ----

pub fn startScanning(self: *CBCentral, config: Central.ScanConfig) Central.ScanError!void {
    if (!self.started) self.start() catch return error.Unexpected;
    if (self.state == .scanning) return error.Busy;
    if (!self.powered_on) return error.Unexpected;

    var keys: [1]objc.Id = .{objc.nsString("CBCentralManagerScanOptionAllowDuplicatesKey")};
    var vals: [1]objc.Id = .{objc.nsNumber(!config.filter_duplicates)};
    const options = objc.nsDictionary(&keys, &vals, 1);

    var svc_filter: ?objc.Id = null;
    if (config.service_uuids.len > 0) {
        const uuid_objs = self.allocator.alloc(objc.Id, config.service_uuids.len) catch return error.Unexpected;
        defer self.allocator.free(uuid_objs);
        for (config.service_uuids, 0..) |uuid, i| uuid_objs[i] = objc.cbuuid(uuid);
        svc_filter = objc.nsArray(uuid_objs, uuid_objs.len);
    }

    objc.msgSend(void, self.manager.?, objc.sel("scanForPeripheralsWithServices:options:"), .{
        @as(?*anyopaque, if (svc_filter) |f| @ptrCast(f) else null),
        options,
    });
    self.state = .scanning;
}

pub fn stopScanning(self: *CBCentral) void {
    if (self.manager) |m| {
        objc.msgSend(void, m, objc.sel("stopScan"), .{});
    }
    if (self.state == .scanning) self.state = .idle;
}

// ---- connect ----

pub fn connect(self: *CBCentral, addr: Central.BdAddr, _: Central.AddrType, _: Central.ConnParams) Central.ConnectError!Central.ConnectionInfo {
    if (!self.started) self.start() catch return error.Unexpected;

    self.mutex.lock();
    const peripheral = self.findPeripheralByAddrLocked(addr);
    if (peripheral == null) {
        self.mutex.unlock();
        return error.Unexpected;
    }
    self.operation_done = false;
    self.op_error = null;

    objc.msgSend(void, self.manager.?, objc.sel("connectPeripheral:options:"), .{
        peripheral.?,
        @as(?*anyopaque, null),
    });

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const err = self.op_error;
    self.mutex.unlock();

    if (err) |e| return switch (e) {
        .timeout => error.Timeout,
        .unexpected => error.Unexpected,
        else => error.Rejected,
    };
    self.state = .connected;

    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.peripherals.items) |slot| {
        if (slot.peripheral != null and std.mem.eql(u8, &slot.addr, &addr)) {
            return .{
                .conn_handle = slot.handle,
                .peer_addr = slot.addr,
                .peer_addr_type = .public,
                .interval = 0,
                .latency = 0,
                .timeout = 0,
            };
        }
    }
    return error.Unexpected;
}

pub fn disconnect(self: *CBCentral, conn_handle: u16) void {
    self.mutex.lock();
    var removed_peripheral: ?objc.Id = null;
    for (self.peripherals.items, 0..) |slot, i| {
        if (slot.handle == conn_handle) {
            removed_peripheral = slot.peripheral;
            _ = self.peripherals.swapRemove(i);
            break;
        }
    }
    if (self.peripherals.items.len == 0) self.state = .idle;
    self.mutex.unlock();

    if (removed_peripheral) |p| {
        if (self.manager) |m| {
            objc.msgSend(void, m, objc.sel("cancelPeripheralConnection:"), .{p});
        }
        objc.release(p);
    }
}

// ---- discovery ----

pub fn discoverServices(self: *CBCentral, conn_handle: u16, out: []Central.DiscoveredService) Central.GattError!usize {
    const peripheral = self.getPeripheral(conn_handle) orelse return error.Disconnected;

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;
    self.svc_out = out;
    self.svc_count = 0;

    objc.msgSend(void, peripheral, objc.sel("setDelegate:"), .{self.delegate.?});
    objc.msgSend(void, peripheral, objc.sel("discoverServices:"), .{@as(?*anyopaque, null)});

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const count = self.svc_count;
    const err = self.op_error;
    self.svc_out = null;
    self.mutex.unlock();

    if (err) |e| return opErrorToGatt(e);
    return count;
}

pub fn discoverChars(self: *CBCentral, conn_handle: u16, start_handle: u16, _: u16, out: []Central.DiscoveredChar) Central.GattError!usize {
    const peripheral = self.getPeripheral(conn_handle) orelse return error.Disconnected;

    const services: objc.Id = objc.msgSend(objc.Id, peripheral, objc.sel("services"), .{});
    const svc_count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, services, objc.sel("count"), .{});

    var target_svc: ?objc.Id = null;
    var handle_idx: u16 = 1;
    for (0..svc_count) |i| {
        const svc: objc.Id = objc.msgSend(objc.Id, services, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, i)});
        if (handle_idx == start_handle) {
            target_svc = svc;
            break;
        }
        handle_idx += 1;
    }
    const svc = target_svc orelse return error.AttError;

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;
    self.char_out = out;
    self.char_count = 0;

    objc.msgSend(void, peripheral, objc.sel("discoverCharacteristics:forService:"), .{
        @as(?*anyopaque, null),
        svc,
    });

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const count = self.char_count;
    const err = self.op_error;
    self.char_out = null;
    self.mutex.unlock();

    if (err) |e| return opErrorToGatt(e);
    return count;
}

// ---- GATT read/write ----

pub fn gattRead(self: *CBCentral, conn_handle: u16, attr_handle: u16, out: []u8) Central.GattError!usize {
    const peripheral = self.getPeripheral(conn_handle) orelse return error.Disconnected;
    const char_obj = self.findCharByHandle(peripheral, attr_handle) orelse return error.AttError;

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;
    self.read_buf = out;
    self.read_len = 0;

    objc.msgSend(void, peripheral, objc.sel("readValueForCharacteristic:"), .{char_obj});

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const len = self.read_len;
    const err = self.op_error;
    self.read_buf = null;
    self.mutex.unlock();

    if (err) |e| return opErrorToGatt(e);
    return len;
}

pub fn gattWrite(self: *CBCentral, conn_handle: u16, attr_handle: u16, data: []const u8) Central.GattError!void {
    const peripheral = self.getPeripheral(conn_handle) orelse return error.Disconnected;
    const char_obj = self.findCharByHandle(peripheral, attr_handle) orelse return error.AttError;

    const ns_data = objc.nsData(data);

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;

    objc.msgSend(void, peripheral, objc.sel("writeValue:forCharacteristic:type:"), .{
        ns_data,
        char_obj,
        @as(objc.NSInteger, 0), // CBCharacteristicWriteWithResponse
    });

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const err = self.op_error;
    self.mutex.unlock();

    if (err) |e| return opErrorToGatt(e);
}

// ---- subscribe/unsubscribe ----

pub fn subscribe(self: *CBCentral, conn_handle: u16, cccd_handle: u16) Central.GattError!void {
    return self.setNotify(conn_handle, cccd_handle, true);
}

pub fn unsubscribe(self: *CBCentral, conn_handle: u16, cccd_handle: u16) Central.GattError!void {
    return self.setNotify(conn_handle, cccd_handle, false);
}

fn setNotify(self: *CBCentral, conn_handle: u16, cccd_handle: u16, enabled: bool) Central.GattError!void {
    const peripheral = self.getPeripheral(conn_handle) orelse return error.Disconnected;
    const char_obj = self.findCharByHandle(peripheral, cccd_handle) orelse return error.AttError;

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;

    objc.msgSend(void, peripheral, objc.sel("setNotifyValue:forCharacteristic:"), .{
        @as(objc.BOOL, if (enabled) objc.YES else objc.NO),
        char_obj,
    });

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const err = self.op_error;
    self.mutex.unlock();

    if (err) |e| return opErrorToGatt(e);
}

// ---- state & info ----

pub fn getState(self: *CBCentral) Central.State {
    return self.state;
}

pub fn getAddr(_: *CBCentral) ?Central.BdAddr {
    return null;
}

pub fn addEventHook(self: *CBCentral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Central.Event) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch return;
}

pub fn removeEventHook(self: *CBCentral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Central.Event) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var i: usize = 0;
    while (i < self.hooks.items.len) {
        const hook = self.hooks.items[i];
        if (hook.ctx == ctx and hook.cb == cb) {
            _ = self.hooks.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

// ---- internal helpers ----

fn getPeripheral(self: *CBCentral, conn_handle: u16) ?objc.Id {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.getPeripheralLocked(conn_handle);
}

fn getPeripheralLocked(self: *CBCentral, conn_handle: u16) ?objc.Id {
    for (self.peripherals.items) |slot| {
        if (slot.handle == conn_handle and slot.peripheral != null) return slot.peripheral;
    }
    return null;
}

fn findPeripheralByAddrLocked(self: *CBCentral, addr: Central.BdAddr) ?objc.Id {
    for (self.peripherals.items) |slot| {
        if (slot.peripheral != null and std.mem.eql(u8, &slot.addr, &addr)) return slot.peripheral;
    }
    return null;
}

fn allocHandle(self: *CBCentral) u16 {
    const h = self.next_handle;
    self.next_handle +%= 1;
    if (self.next_handle == 0) self.next_handle = 1;
    return h;
}

fn storePeripheral(self: *CBCentral, peripheral: objc.Id, addr: Central.BdAddr) u16 {
    const h = self.allocHandle();
    self.peripherals.append(self.allocator, .{
        .handle = h,
        .peripheral = objc.retain(peripheral),
        .addr = addr,
    }) catch return 0;
    return h;
}

fn findCharByHandle(self: *CBCentral, peripheral: objc.Id, attr_handle: u16) ?objc.Id {
    _ = self;
    const services: objc.Id = objc.msgSend(objc.Id, peripheral, objc.sel("services"), .{});
    const svc_count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, services, objc.sel("count"), .{});

    var handle_idx: u16 = 1;
    for (0..svc_count) |si| {
        const svc: objc.Id = objc.msgSend(objc.Id, services, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, si)});
        handle_idx += 1;

        const chars: objc.Id = objc.msgSend(objc.Id, svc, objc.sel("characteristics"), .{});
        if (@intFromPtr(chars) == 0) continue;
        const char_count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, chars, objc.sel("count"), .{});

        for (0..char_count) |ci| {
            const char_obj: objc.Id = objc.msgSend(objc.Id, chars, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, ci)});
            if (handle_idx == attr_handle) return char_obj;
            handle_idx += 1;
        }
    }
    return null;
}

fn opErrorToGatt(e: OpError) Central.GattError {
    return switch (e) {
        .att => error.AttError,
        .timeout => error.Timeout,
        .disconnected => error.Disconnected,
        .unexpected => error.Unexpected,
    };
}

fn fireEvent(self: *CBCentral, event: Central.Event) void {
    self.mutex.lock();
    const snapshot = self.allocator.dupe(EventHook, self.hooks.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);
    for (snapshot) |hook| hook.cb(hook.ctx, event);
}

fn signalDone(self: *CBCentral) void {
    self.operation_done = true;
    self.cond.signal();
}

// ---- Delegate class (created once) ----

var delegate_class: ?objc.Class = null;
var delegate_once = std.once(initDelegateClass);

fn ensureDelegateClass() objc.Class {
    delegate_once.call();
    return delegate_class.?;
}

fn initDelegateClass() void {
    var builder = objc.allocateClassPair("NSObject", "ZigCBCentralDelegate");
    builder.addIvar("zig_ptr", @sizeOf(*anyopaque), @alignOf(*anyopaque));

    builder.addProtocol("CBCentralManagerDelegate");
    builder.addProtocol("CBPeripheralDelegate");

    builder.addMethod("centralManagerDidUpdateState:", @ptrCast(&cbDidUpdateState), "v@:@");
    builder.addMethod("centralManager:didDiscoverPeripheral:advertisementData:RSSI:", @ptrCast(&cbDidDiscover), "v@:@@@@");
    builder.addMethod("centralManager:didConnectPeripheral:", @ptrCast(&cbDidConnect), "v@:@@");
    builder.addMethod("centralManager:didFailToConnectPeripheral:error:", @ptrCast(&cbDidFailConnect), "v@:@@@");
    builder.addMethod("centralManager:didDisconnectPeripheral:error:", @ptrCast(&cbDidDisconnect), "v@:@@@");

    builder.addMethod("peripheral:didDiscoverServices:", @ptrCast(&cbDidDiscoverServices), "v@:@@");
    builder.addMethod("peripheral:didDiscoverCharacteristicsForService:error:", @ptrCast(&cbDidDiscoverChars), "v@:@@@");
    builder.addMethod("peripheral:didUpdateValueForCharacteristic:error:", @ptrCast(&cbDidUpdateValue), "v@:@@@");
    builder.addMethod("peripheral:didWriteValueForCharacteristic:error:", @ptrCast(&cbDidWriteValue), "v@:@@@");
    builder.addMethod("peripheral:didUpdateNotificationStateForCharacteristic:error:", @ptrCast(&cbDidUpdateNotify), "v@:@@@");

    delegate_class = builder.register();
}

fn getSelf(delegate: objc.Id) ?*CBCentral {
    const ptr = objc.getIvar(delegate, "zig_ptr") orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ---- Delegate callbacks (callconv(.C)) ----

fn cbDidUpdateState(delegate: objc.Id, _: objc.SEL, manager: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    const cb_state: objc.NSInteger = objc.msgSend(objc.NSInteger, manager, objc.sel("state"), .{});
    self.mutex.lock();
    self.powered_on = (cb_state == 5); // CBManagerStatePoweredOn
    self.state_known = true;
    self.signalDone();
    self.mutex.unlock();
}

fn cbDidDiscover(delegate: objc.Id, _: objc.SEL, _: objc.Id, peripheral: objc.Id, adv_data: objc.Id, rssi: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    var report = Central.AdvReport{
        .addr = .{0} ** 6,
        .addr_type = .random,
        .rssi = 0,
    };

    const rssi_val: objc.NSInteger = objc.msgSend(objc.NSInteger, rssi, objc.sel("integerValue"), .{});
    report.rssi = @truncate(rssi_val);

    const name_key = objc.nsString("kCBAdvDataLocalName");
    const name_obj: ?objc.Id = objc.msgSend(?objc.Id, adv_data, objc.sel("objectForKey:"), .{name_key});
    if (name_obj) |name| {
        const name_slice = objc.nsStringGetBytes(name, &report.name);
        report.name_len = @truncate(name_slice.len);
    }

    const uuid_obj: objc.Id = objc.msgSend(objc.Id, peripheral, objc.sel("identifier"), .{});
    const uuid_str: objc.Id = objc.msgSend(objc.Id, uuid_obj, objc.sel("UUIDString"), .{});
    var uuid_buf: [36]u8 = undefined;
    const uuid_slice = objc.nsStringGetBytes(uuid_str, &uuid_buf);
    if (uuid_slice.len >= 6) {
        @memcpy(&report.addr, uuid_slice[0..6]);
    }

    self.mutex.lock();
    _ = self.storePeripheral(peripheral, report.addr);
    self.mutex.unlock();

    self.fireEvent(.{ .device_found = report });
}

fn cbDidConnect(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    self.state = .connected;
    self.op_error = null;
    self.signalDone();
    self.mutex.unlock();
}

fn cbDidFailConnect(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, _: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    self.op_error = .unexpected;
    self.signalDone();
    self.mutex.unlock();
}

fn cbDidDisconnect(delegate: objc.Id, _: objc.SEL, _: objc.Id, peripheral: objc.Id, _: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    self.mutex.lock();
    var disconnected_handle: u16 = 0;
    for (self.peripherals.items, 0..) |slot, i| {
        if (slot.peripheral == peripheral) {
            disconnected_handle = slot.handle;
            _ = self.peripherals.swapRemove(i);
            break;
        }
    }
    if (self.peripherals.items.len == 0) self.state = .idle;
    self.op_error = .disconnected;
    self.signalDone();
    self.mutex.unlock();

    objc.release(peripheral);
    self.fireEvent(.{ .disconnected = disconnected_handle });
}

fn cbDidDiscoverServices(delegate: objc.Id, _: objc.SEL, peripheral: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    defer {
        self.signalDone();
        self.mutex.unlock();
    }

    if (err != null) {
        self.op_error = .att;
        return;
    }

    const out = self.svc_out orelse return;
    const services: objc.Id = objc.msgSend(objc.Id, peripheral, objc.sel("services"), .{});
    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, services, objc.sel("count"), .{});

    var handle_idx: u16 = 1;
    var written: usize = 0;
    for (0..count) |i| {
        if (written >= out.len) break;
        const svc: objc.Id = objc.msgSend(objc.Id, services, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, i)});
        const uuid_obj: objc.Id = objc.msgSend(objc.Id, svc, objc.sel("UUID"), .{});
        out[written] = .{
            .start_handle = handle_idx,
            .end_handle = handle_idx,
            .uuid = objc.cbuuidToU16(uuid_obj),
        };
        handle_idx += 1;
        written += 1;
    }
    self.svc_count = written;
}

fn cbDidDiscoverChars(delegate: objc.Id, _: objc.SEL, _: objc.Id, service: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    defer {
        self.signalDone();
        self.mutex.unlock();
    }

    if (err != null) {
        self.op_error = .att;
        return;
    }

    const out = self.char_out orelse return;
    const chars: objc.Id = objc.msgSend(objc.Id, service, objc.sel("characteristics"), .{});
    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, chars, objc.sel("count"), .{});

    var handle_idx: u16 = 1;
    var written: usize = 0;
    for (0..count) |i| {
        if (written >= out.len) break;
        const char_obj: objc.Id = objc.msgSend(objc.Id, chars, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, i)});
        const uuid_obj: objc.Id = objc.msgSend(objc.Id, char_obj, objc.sel("UUID"), .{});
        const props: objc.NSUInteger = objc.msgSend(objc.NSUInteger, char_obj, objc.sel("properties"), .{});
        out[written] = .{
            .decl_handle = handle_idx,
            .value_handle = handle_idx,
            .cccd_handle = if (props & 0x30 != 0) handle_idx else 0,
            .properties = @truncate(props),
            .uuid = objc.cbuuidToU16(uuid_obj),
        };
        handle_idx += 1;
        written += 1;
    }
    self.char_count = written;
}

fn cbDidUpdateValue(delegate: objc.Id, _: objc.SEL, _: objc.Id, characteristic: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const value: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("value"), .{});

    self.mutex.lock();
    if (err != null) {
        self.op_error = .att;
        self.signalDone();
        self.mutex.unlock();
        return;
    }

    if (self.read_buf) |buf| {
        const slice = objc.nsDataGetBytes(value, buf);
        self.read_len = slice.len;
        self.signalDone();
        self.mutex.unlock();
    } else {
        self.signalDone();
        self.mutex.unlock();
        var notif = Central.NotificationData{
            .conn_handle = 0,
            .attr_handle = 0,
        };
        const data_slice = objc.nsDataGetBytes(value, &notif.data);
        notif.len = @truncate(data_slice.len);
        self.fireEvent(.{ .notification = notif });
    }
}

fn cbDidWriteValue(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    if (err != null) self.op_error = .att;
    self.signalDone();
    self.mutex.unlock();
}

fn cbDidUpdateNotify(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    if (err != null) self.op_error = .att;
    self.signalDone();
    self.mutex.unlock();
}

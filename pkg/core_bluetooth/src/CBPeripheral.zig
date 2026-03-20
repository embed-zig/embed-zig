//! CBPeripheral — bt.Peripheral implementation via Apple CoreBluetooth.
//!
//! Bridges CBPeripheralManager to the bt.Peripheral VTable.
//! Dynamically creates a delegate class for async callbacks and uses
//! Mutex+Condition to present a blocking API.

const std = @import("std");
const bt = @import("bt");
const Peripheral = bt.Peripheral;
const objc = @import("objc.zig");
const Allocator = std.mem.Allocator;

const CBPeripheral = @This();

allocator: Allocator,
queue_label: [*:0]const u8,
manager: ?objc.Id = null,
delegate: ?objc.Id = null,
queue: ?objc.dispatch_queue_t = null,
state: Peripheral.State = .idle,
powered_on: bool = false,
state_known: bool = false,
started: bool = false,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
operation_done: bool = false,
op_error: ?OpError = null,

handlers: std.ArrayListUnmanaged(HandlerEntry) = .{},
cb_chars: std.ArrayListUnmanaged(?objc.Id) = .{},

hooks: std.ArrayListUnmanaged(EventHook) = .{},

const OpError = enum { invalid_config, already_advertising, unexpected };

const HandlerEntry = struct {
    svc_uuid: u16 = 0,
    char_uuid: u16 = 0,
    func: ?Peripheral.HandlerFn = null,
    ctx: ?*anyopaque = null,
    active: bool = false,
};

const EventHook = struct {
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Peripheral.PeripheralEvent) void,
};

// ---- lifecycle ----

pub const Config = struct {
    queue_label: [*:0]const u8 = "com.embed.bt.peripheral",
};

pub fn init(allocator: Allocator, config: Config) CBPeripheral {
    return .{ .allocator = allocator, .queue_label = config.queue_label };
}

pub const StartError = error{BluetoothUnavailable};

pub fn start(self: *CBPeripheral) StartError!void {
    if (self.started) return;

    self.queue = objc.createSerialQueue(self.queue_label);

    const delegate_cls = ensureDelegateClass();
    self.delegate = objc.msgSend(objc.Id, objc.alloc(delegate_cls), objc.sel("init"), .{});
    objc.setIvar(self.delegate.?, "zig_ptr", @ptrCast(self));

    self.manager = objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBPeripheralManager")), objc.sel("initWithDelegate:queue:"), .{
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

pub fn stop(self: *CBPeripheral) void {
    if (!self.started) return;
    if (self.state == .advertising) self.stopAdvertising();

    self.mutex.lock();
    self.started = false;
    self.powered_on = false;
    self.state_known = false;
    self.state = .idle;
    self.mutex.unlock();

    objc.msgSend(void, self.manager.?, objc.sel("removeAllServices"), .{});
    for (self.cb_chars.items) |c| {
        if (c) |char_obj| objc.release(char_obj);
    }
    self.cb_chars.shrinkRetainingCapacity(0);
    objc.release(self.manager.?);
    objc.release(self.delegate.?);
    objc.releaseQueue(self.queue.?);
    self.manager = null;
    self.delegate = null;
    self.queue = null;
}

pub fn deinit(self: *CBPeripheral) void {
    self.stop();
    self.cb_chars.deinit(self.allocator);
    self.handlers.deinit(self.allocator);
    self.hooks.deinit(self.allocator);
    const alloc = self.allocator;
    self.* = undefined;
    alloc.destroy(self);
}

// ---- handler registration ----

pub fn handle(self: *CBPeripheral, svc_uuid: u16, char_uuid: u16, func: Peripheral.HandlerFn, ctx: ?*anyopaque) void {
    if (!self.started) self.start() catch return;

    self.handlers.append(self.allocator, .{
        .svc_uuid = svc_uuid,
        .char_uuid = char_uuid,
        .func = func,
        .ctx = ctx,
        .active = true,
    }) catch return;

    const char_props: objc.NSUInteger = 0x02 | 0x08 | 0x10; // read | write | notify
    const char_perms: objc.NSUInteger = 0x01 | 0x02; // readable | writeable
    const cb_char = objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBMutableCharacteristic")), objc.sel("initWithType:properties:value:permissions:"), .{
        objc.cbuuid(char_uuid),
        char_props,
        @as(?*anyopaque, null),
        char_perms,
    });
    self.cb_chars.append(self.allocator, cb_char) catch return;

    const cb_svc = objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBMutableService")), objc.sel("initWithType:primary:"), .{
        objc.cbuuid(svc_uuid),
        @as(objc.BOOL, objc.YES),
    });

    const char_array = objc.nsArray(&[_]objc.Id{cb_char}, 1);
    objc.msgSend(void, cb_svc, objc.sel("setCharacteristics:"), .{char_array});

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;

    objc.msgSend(void, self.manager.?, objc.sel("addService:"), .{cb_svc});

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    self.mutex.unlock();

    objc.release(cb_svc);
}

// ---- advertising ----

pub fn startAdvertising(self: *CBPeripheral, config: Peripheral.AdvConfig) Peripheral.AdvError!void {
    if (!self.started) self.start() catch return error.Unexpected;
    if (self.state == .advertising) return error.AlreadyAdvertising;
    if (!self.powered_on) return error.Unexpected;

    var keys: [2]objc.Id = undefined;
    var vals: [2]objc.Id = undefined;
    var count: objc.NSUInteger = 0;

    if (config.device_name.len > 0) {
        keys[count] = objc.nsString("CBAdvertisementDataLocalNameKey");
        vals[count] = objc.nsString(config.device_name);
        count += 1;
    }

    if (config.service_uuids.len > 0) {
        const uuid_objs = self.allocator.alloc(objc.Id, config.service_uuids.len) catch return error.Unexpected;
        defer self.allocator.free(uuid_objs);
        for (config.service_uuids, 0..) |uuid, i| uuid_objs[i] = objc.cbuuid(uuid);
        keys[count] = objc.nsString("CBAdvertisementDataServiceUUIDsKey");
        vals[count] = objc.nsArray(uuid_objs, uuid_objs.len);
        count += 1;
    }

    const adv_dict = objc.nsDictionary(keys[0..count], vals[0..count], count);

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;

    objc.msgSend(void, self.manager.?, objc.sel("startAdvertising:"), .{adv_dict});

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const err = self.op_error;
    self.mutex.unlock();

    if (err) |e| return switch (e) {
        .invalid_config => error.InvalidConfig,
        .already_advertising => error.AlreadyAdvertising,
        .unexpected => error.Unexpected,
    };

    self.state = .advertising;
    self.fireEvent(.{ .advertising_started = {} });
}

pub fn stopAdvertising(self: *CBPeripheral) void {
    if (self.state != .advertising) return;
    if (self.manager) |m| {
        objc.msgSend(void, m, objc.sel("stopAdvertising"), .{});
    }
    self.state = .idle;
    self.fireEvent(.{ .advertising_stopped = {} });
}

// ---- notify / indicate ----

pub fn notify(self: *CBPeripheral, _: u16, char_uuid: u16, data: []const u8) Peripheral.GattError!void {
    const cb_char = self.findCBChar(char_uuid) orelse return error.InvalidHandle;
    const ns_data = objc.nsData(data);
    const ok: objc.BOOL = objc.msgSend(objc.BOOL, self.manager.?, objc.sel("updateValue:forCharacteristic:onSubscribedCentrals:"), .{
        ns_data,
        cb_char,
        @as(?*anyopaque, null),
    });
    if (ok != objc.YES) return error.Unexpected;
}

pub fn indicate(self: *CBPeripheral, conn_handle: u16, char_uuid: u16, data: []const u8) Peripheral.GattError!void {
    return self.notify(conn_handle, char_uuid, data);
}

// ---- connection ----

pub fn disconnect(_: *CBPeripheral, _: u16) void {}

// ---- state & info ----

pub fn getState(self: *CBPeripheral) Peripheral.State {
    return self.state;
}

pub fn getAddr(_: *CBPeripheral) ?Peripheral.BdAddr {
    return null;
}

pub fn addEventHook(self: *CBPeripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Peripheral.PeripheralEvent) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch return;
}

// ---- internal helpers ----

fn findCBChar(self: *CBPeripheral, char_uuid: u16) ?objc.Id {
    for (self.handlers.items, 0..) |h, i| {
        if (h.char_uuid == char_uuid) return self.cb_chars.items[i];
    }
    return null;
}

fn findHandler(self: *CBPeripheral, char_uuid: u16) ?*HandlerEntry {
    for (self.handlers.items) |*h| {
        if (h.char_uuid == char_uuid and h.active) return h;
    }
    return null;
}

fn fireEvent(self: *CBPeripheral, event: Peripheral.PeripheralEvent) void {
    self.mutex.lock();
    const snapshot = self.allocator.dupe(EventHook, self.hooks.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);
    for (snapshot) |hook| hook.cb(hook.ctx, event);
}

fn signalDone(self: *CBPeripheral) void {
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
    var builder = objc.allocateClassPair("NSObject", "ZigCBPeripheralDelegate");
    builder.addIvar("zig_ptr", @sizeOf(*anyopaque), @alignOf(*anyopaque));

    builder.addProtocol("CBPeripheralManagerDelegate");

    builder.addMethod("peripheralManagerDidUpdateState:", @ptrCast(&pmDidUpdateState), "v@:@");
    builder.addMethod("peripheralManager:didAddService:error:", @ptrCast(&pmDidAddService), "v@:@@@");
    builder.addMethod("peripheralManagerDidStartAdvertising:error:", @ptrCast(&pmDidStartAdvertising), "v@:@@");
    builder.addMethod("peripheralManager:didReceiveReadRequest:", @ptrCast(&pmDidReceiveRead), "v@:@@");
    builder.addMethod("peripheralManager:didReceiveWriteRequests:", @ptrCast(&pmDidReceiveWrite), "v@:@@");
    builder.addMethod("peripheralManager:central:didSubscribeToCharacteristic:", @ptrCast(&pmDidSubscribe), "v@:@@@");
    builder.addMethod("peripheralManager:central:didUnsubscribeFromCharacteristic:", @ptrCast(&pmDidUnsubscribe), "v@:@@@");

    delegate_class = builder.register();
}

fn getSelf(delegate: objc.Id) ?*CBPeripheral {
    const ptr = objc.getIvar(delegate, "zig_ptr") orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ---- Delegate callbacks ----

fn pmDidUpdateState(delegate: objc.Id, _: objc.SEL, manager: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    const cb_state: objc.NSInteger = objc.msgSend(objc.NSInteger, manager, objc.sel("state"), .{});
    self.mutex.lock();
    self.powered_on = (cb_state == 5); // CBManagerStatePoweredOn
    self.state_known = true;
    self.signalDone();
    self.mutex.unlock();
}

fn pmDidAddService(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    if (err != null) self.op_error = .unexpected;
    self.signalDone();
    self.mutex.unlock();
}

fn pmDidStartAdvertising(delegate: objc.Id, _: objc.SEL, _: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    if (err != null) self.op_error = .unexpected;
    self.signalDone();
    self.mutex.unlock();
}

fn pmDidReceiveRead(delegate: objc.Id, _: objc.SEL, manager: objc.Id, request: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const characteristic: objc.Id = objc.msgSend(objc.Id, request, objc.sel("characteristic"), .{});
    const uuid_obj: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("UUID"), .{});
    const char_uuid = objc.cbuuidToU16(uuid_obj);

    const handler = self.findHandler(char_uuid) orelse {
        objc.msgSend(void, manager, objc.sel("respondToRequest:withResult:"), .{
            request,
            @as(objc.NSInteger, 10), // CBATTErrorAttributeNotFound
        });
        return;
    };

    var rw_impl = ResponseWriterImpl{ .manager = manager, .request = request };
    var rw = Peripheral.ResponseWriter{
        ._impl = @ptrCast(&rw_impl),
        ._write_fn = @ptrCast(&ResponseWriterImpl.writeFn),
        ._ok_fn = @ptrCast(&ResponseWriterImpl.okFn),
        ._err_fn = @ptrCast(&ResponseWriterImpl.errFn),
    };

    var req = Peripheral.Request{
        .op = .read,
        .conn_handle = 0,
        .service_uuid = handler.svc_uuid,
        .char_uuid = char_uuid,
        .data = &.{},
        .user_ctx = handler.ctx,
    };

    handler.func.?(&req, &rw);
}

fn pmDidReceiveWrite(delegate: objc.Id, _: objc.SEL, manager: objc.Id, requests: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, requests, objc.sel("count"), .{});
    for (0..count) |i| {
        const request: objc.Id = objc.msgSend(objc.Id, requests, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, i)});
        const characteristic: objc.Id = objc.msgSend(objc.Id, request, objc.sel("characteristic"), .{});
        const uuid_obj: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("UUID"), .{});
        const char_uuid = objc.cbuuidToU16(uuid_obj);

        const handler = self.findHandler(char_uuid) orelse continue;

        const value: objc.Id = objc.msgSend(objc.Id, request, objc.sel("value"), .{});
        var data_buf: [512]u8 = undefined;
        const data_slice = objc.nsDataGetBytes(value, &data_buf);

        var rw_impl = ResponseWriterImpl{ .manager = manager, .request = request };
        var rw = Peripheral.ResponseWriter{
            ._impl = @ptrCast(&rw_impl),
            ._write_fn = @ptrCast(&ResponseWriterImpl.writeFn),
            ._ok_fn = @ptrCast(&ResponseWriterImpl.okFn),
            ._err_fn = @ptrCast(&ResponseWriterImpl.errFn),
        };

        var req = Peripheral.Request{
            .op = .write,
            .conn_handle = 0,
            .service_uuid = handler.svc_uuid,
            .char_uuid = char_uuid,
            .data = data_slice,
            .user_ctx = handler.ctx,
        };

        handler.func.?(&req, &rw);
    }
}

fn pmDidSubscribe(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, _: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.fireEvent(.{ .connected = .{
        .conn_handle = 0,
        .peer_addr = .{0} ** 6,
        .peer_addr_type = .random,
        .interval = 0,
        .latency = 0,
        .timeout = 0,
    } });
}

fn pmDidUnsubscribe(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, _: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.fireEvent(.{ .disconnected = 0 });
}

// ---- ResponseWriter implementation ----

const ResponseWriterImpl = struct {
    manager: objc.Id,
    request: objc.Id,

    fn writeFn(impl_ptr: *anyopaque, data: []const u8) void {
        const self: *ResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        const ns_data = objc.nsData(data);
        objc.msgSend(void, self.request, objc.sel("setValue:"), .{ns_data});
        objc.msgSend(void, self.manager, objc.sel("respondToRequest:withResult:"), .{
            self.request,
            @as(objc.NSInteger, 0),
        });
    }

    fn okFn(impl_ptr: *anyopaque) void {
        const self: *ResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        objc.msgSend(void, self.manager, objc.sel("respondToRequest:withResult:"), .{
            self.request,
            @as(objc.NSInteger, 0),
        });
    }

    fn errFn(impl_ptr: *anyopaque, code: u8) void {
        const self: *ResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        objc.msgSend(void, self.manager, objc.sel("respondToRequest:withResult:"), .{
            self.request,
            @as(objc.NSInteger, @intCast(code)),
        });
    }
};
